import AppKit

/// Watches the dictation key system-wide: fn, or the shortcut the user recorded (1–5 keys held
/// together). Reports presses and releases; DictationController turns them into push-to-talk,
/// double-tap hands-free, and cancel.
final class HotkeyMonitor {
    struct Press {}

    var onPress: ((Press) -> Void)?
    var onRelease: ((TimeInterval) -> Void)?
    /// Another key was typed while the dictation key was held (the user is
    /// using the modifier for a shortcut, not for dictation).
    var onOtherKey: (() -> Void)?
    var onEscape: (() -> Void)?

    var choice: HotkeyChoice {
        didSet { if oldValue != choice { resetState() } }
    }
    var shortcut: Shortcut? {
        didSet { if oldValue != shortcut { resetState() } }
    }
    /// Settings is recording a new shortcut: the keys pressed must reach it, not start dictation.
    var paused = false {
        didSet { if paused { resetState() } }
    }

    private var monitors: [Any] = []
    private var isDown = false
    private var downAt = Date()
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    /// Custom shortcut: which of its keys are down, and the keys whose key-down was kept from the app
    /// (their key-up is kept back too).
    private var held: Set<UInt16> = []
    private var swallowed: Set<UInt16> = []

    private static let fnKeyCode: UInt16 = 63
    private static let fnMask: UInt = 0x800000   // NX_SECONDARYFNMASK

    init(choice: HotkeyChoice, shortcut: Shortcut?) {
        self.choice = choice
        self.shortcut = shortcut
    }

    func start() {
        stop()
        // Global monitors see events going to other apps (needs Accessibility);
        // local monitors cover the case where Mowa's own window is key.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in
            self?.handle(e)
        }) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] e in
            self?.handle(e)
            return e
        }) { monitors.append(l) }
        if choice == .custom, shortcut != nil { startTap() }
    }

    private func resetState() {
        isDown = false
        held.removeAll()
        swallowed.removeAll()
    }

    /// The dictation key is physically held right now (asks the system, not our event stream).
    var isPhysicallyDown: Bool {
        if choice == .fn {
            return (CGEventSource.flagsState(.combinedSessionState).rawValue & UInt64(Self.fnMask)) != 0
        }
        guard let shortcut else { return false }
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        return shortcut.keys.allSatisfy { key in
            if let mask = Shortcut.modifierMasks[key] { return flags & mask != 0 }
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key))
        }
    }

    /// macOS sometimes drops a key event (busy system, app switch, secure input). If we still
    /// think the key is down but it isn't, report the missed release so the recording stops and
    /// the next press works again. Called on a timer while push-to-talk records.
    func reconcile() {
        guard isDown, !isPhysicallyDown else { return }
        isDown = false
        held.removeAll()
        let heldFor = Date().timeIntervalSince(downAt)
        Log.info("Hotkey: release event was missed after \(String(format: "%.1f", heldFor))s, stopping the recording")
        onRelease?(heldFor)
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        stopTap()
        resetState()
    }

    // MARK: fn (NSEvent monitors) + Esc

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            guard !paused, choice == .fn, event.keyCode == Self.fnKeyCode else { return }
            let down = event.modifierFlags.contains(.function)
            if down && isDown {
                // A press while we think the key is still down: its release was missed.
                Log.info("Hotkey: release event was missed, recovering")
                isDown = false
                onRelease?(Date().timeIntervalSince(downAt))
            }
            if down && !isDown {
                isDown = true
                downAt = Date()
                onPress?(Press())
            } else if !down && isDown {
                isDown = false
                onRelease?(Date().timeIntervalSince(downAt))
            }
        case .keyDown:
            SentMessageTracker.keyDown(event)
            guard !paused else { return }
            let isMember = choice == .custom && (shortcut?.keys.contains(event.keyCode) ?? false)
            if event.keyCode == 53, !isMember { // Escape
                onEscape?()
            } else if isDown, choice == .fn {
                onOtherKey?()
            }
        default:
            break
        }
    }

    // MARK: Custom shortcut (event tap)

    /// The shortcut's keys must not also type or trigger something in the app in front, so they
    /// are taken out of the event stream while they form the shortcut (an NSEvent monitor can only
    /// watch). Needs Accessibility, which Mowa already has for typing the text.
    private func startTap() {
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << CGEventMask($1.rawValue)) }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            return Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue().handleTap(type, event)
        }, userInfo: refcon) else {
            Log.error("Hotkey: couldn't watch the shortcut (Accessibility not granted yet?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        tapSource = source
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        tap = nil
        tapSource = nil
    }

    private func handleTap(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS switches a slow tap off; switch it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        // Only the physical keyboard: Mowa's own ⌘V / ⌘C (pasting the text) must never count.
        guard event.getIntegerValueField(.eventSourceStateID) == Int64(CGEventSourceStateID.hidSystemState.rawValue)
        else { return pass }
        guard !paused, choice == .custom, let shortcut else { return pass }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isMember = shortcut.keys.contains(keyCode)

        switch type {
        case .flagsChanged:
            guard let mask = Shortcut.modifierMasks[keyCode] else { return pass }
            let down = event.flags.rawValue & mask != 0
            if isMember {
                if down { held.insert(keyCode) } else { held.remove(keyCode) }
            } else if down, isDown {
                onOtherKey?()
            }
            update(shortcut, event.flags)
            return pass   // modifier changes always reach the system
        case .keyDown:
            guard isMember else {
                if isDown, keyCode != 53 { onOtherKey?() }
                return pass
            }
            if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 {
                return swallowed.contains(keyCode) ? nil : pass
            }
            held.insert(keyCode)
            update(shortcut, event.flags)
            // The key that completes the shortcut (and any member pressed while it is held) is
            // kept from the app. Keys pressed before the shortcut was complete went through.
            if isDown {
                swallowed.insert(keyCode)
                return nil
            }
            return pass
        case .keyUp:
            guard isMember else { return pass }
            held.remove(keyCode)
            update(shortcut, event.flags)
            return swallowed.remove(keyCode) != nil ? nil : pass
        default:
            return pass
        }
    }

    /// Down = every key of the shortcut is held and no other modifier is.
    private func update(_ shortcut: Shortcut, _ flags: CGEventFlags) {
        let wanted = shortcut.keys.compactMap(Shortcut.flag(of:))
            .reduce(CGEventFlags()) { $0.union($1) }
        let extra = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).subtracting(wanted)
        let complete = held == Set(shortcut.keys) && extra.isEmpty
        if complete && !isDown {
            isDown = true
            downAt = Date()
            onPress?(Press())
        } else if !complete && isDown {
            isDown = false
            onRelease?(Date().timeIntervalSince(downAt))
        }
    }
}
