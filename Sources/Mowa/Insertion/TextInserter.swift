import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MowaCore

/// What is focused when dictation starts or ends.
struct FocusContext {
    var appName: String?
    var bundleID: String?
    var windowTitle: String?
    var selectedText: String?
    /// Character just before the caret, when the app exposes it.
    var precedingCharacter: Character?
    /// Up to ~150 characters before the caret / selection, and after it. Used to fit
    /// dictated words into an existing sentence instead of pasting a new sentence.
    var textBefore: String?
    var textAfter: String?
    /// AX role/subrole of the focused element (e.g. AXTextArea, AXTextField, AXSearchField).
    var role: String?
    var subrole: String?
    var pid: pid_t?
}

/// Reads the focused text field via Accessibility and types text by pasting
/// (the only method that works in every app, Electron and browsers included).
enum TextInserter {

    // MARK: Focus

    static func focusContext() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication
        var ctx = FocusContext(appName: app?.localizedName, bundleID: app?.bundleIdentifier, pid: app?.processIdentifier)
        guard AXIsProcessTrusted() else { return ctx }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)

        if let pid = app?.processIdentifier {
            let appElement = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(appElement, 0.25)
            enableFullAccessibility(appElement, pid: pid, name: app?.localizedName, bundleID: app?.bundleIdentifier)
            if let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) {
                ctx.windowTitle = attribute(window, kAXTitleAttribute)
            }
        }

        var focusedRef: CFTypeRef?
        let axErr = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focusedRef)
        guard axErr == .success, let focusedRef, CFGetTypeID(focusedRef) == AXUIElementGetTypeID() else {
            // apiDisabled (-25211) here while AXIsProcessTrusted() is true = stale Accessibility
            // grant after an update: macOS silently drops our ⌘V too.
            Log.info("Focus: no focused element in \(ctx.appName ?? "?") (AX error \(axErr.rawValue))")
            return ctx
        }
        let focused = focusedRef as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, 0.25)

        ctx.role = attribute(focused, kAXRoleAttribute)
        ctx.subrole = attribute(focused, kAXSubroleAttribute)

        if let selected: String = attribute(focused, kAXSelectedTextAttribute), !selected.isEmpty {
            ctx.selectedText = selected
        }

        // Character before the caret: selected range → string for (location-1, 1).
        var rangeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
           let rangeValue = rangeRef, CFGetTypeID(rangeValue) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) {
                // Text around the caret, cut from the field's own value (not AXStringForRange,
                // which some apps answer with the wrong text). Skipped when the value is the
                // placeholder ("Message…") or doesn't match the caret position.
                if range.location >= 0, let value: String = attribute(focused, kAXValueAttribute) {
                    let ns = value as NSString
                    let placeholder: String? = attribute(focused, kAXPlaceholderValueAttribute)
                    let isPlaceholder = !value.isEmpty && value == placeholder
                    let location = caretInValue(ns, location: range.location, element: focused)
                    if location != range.location {
                        Log.info("Caret context: caret \(range.location) is \(location) in the field's text (line breaks not counted)")
                    }
                    let end = location + max(0, range.length)
                    if isPlaceholder || ns.length == 0 {
                        ctx.textBefore = ""; ctx.textAfter = ""
                    } else if end <= ns.length {
                        let start = max(0, location - 150)
                        ctx.textBefore = ns.substring(with: NSRange(location: start, length: location - start))
                        ctx.textAfter = ns.substring(with: NSRange(location: end, length: min(150, ns.length - end)))
                    }
                    Log.info("Caret context: field \(ns.length) chars, caret \(range.location)+\(range.length), "
                             + "placeholder \(isPlaceholder), before \(ctx.textBefore.map { InlineFit.describeEnd($0) } ?? "nil"), "
                             + "after \(ctx.textAfter.map { InlineFit.describeStart($0) } ?? "nil")")
                }
                if range.location == 0 {
                    ctx.precedingCharacter = "\n" // start of field: behaves like a line start
                } else if range.location > 0 {
                    var prev = CFRange(location: range.location - 1, length: 1)
                    if let prevValue = AXValueCreate(.cfRange, &prev) {
                        var strRef: CFTypeRef?
                        if AXUIElementCopyParameterizedAttributeValue(focused, kAXStringForRangeParameterizedAttribute as CFString,
                                                                       prevValue, &strRef) == .success,
                           let str = strRef as? String, let ch = str.last {
                            ctx.precedingCharacter = ch
                        }
                    }
                }
            }
        }
        // The box was just sent with Return: Chromium/Electron apps still report the old message.
        if ctx.selectedText == nil, SentMessageTracker.justSent(ctx.bundleID),
           !(ctx.textBefore ?? "").isEmpty || !(ctx.textAfter ?? "").isEmpty {
            Log.info("Caret context: message just sent with Return — \(ctx.appName ?? "?") still reports the old text, field treated as empty")
            ctx.textBefore = ""; ctx.textAfter = ""; ctx.precedingCharacter = "\n"
        }
        return ctx
    }

    /// Chromium counts the caret offset without some of the line breaks its field value has
    /// (dev recordings: "…or no" | "t? " with the caret really at the end, "backgroun" | "d.").
    /// The text the app reports just before its own offset is looked up in the value; the
    /// nearest place it ends is the real caret. Unchanged when it matches or isn't found.
    static func caretInValue(_ ns: NSString, location: Int, element: AXUIElement) -> Int {
        guard location > 0, ns.range(of: "\n").location != NSNotFound else { return location }
        var r = CFRange(location: max(0, location - 16), length: min(location, 16))
        guard let value = AXValueCreate(.cfRange, &r) else { return location }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         value, &ref) == .success,
              let before = ref as? String, (before as NSString).length >= 4 else { return location }
        return CaretText.location(in: ns, reported: location, before: before)
    }

    // MARK: Full accessibility in Chromium / Electron apps

    private static var fullAccessibilityPIDs = Set<pid_t>()

    private static let chromiumBrowsers: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
        "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac", "company.thebrowser.Browser",
        "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
    ]

    /// Chrome, Edge, Brave, Arc and Electron apps keep the text of web pages out of the
    /// Accessibility tree until an assistive app asks for it (they don't know Mowa is one).
    /// AXManualAccessibility is the standard switch Chromium provides for that — the same thing
    /// VoiceOver and other assistive apps turn on. Afterwards the focused web field reports its
    /// text, caret and selection like a native field. Other apps ignore the attribute. Asked once
    /// per process; it takes effect within a moment, so it's done when recording starts.
    private static func enableFullAccessibility(_ appElement: AXUIElement, pid: pid_t, name: String?, bundleID: String?) {
        guard !fullAccessibilityPIDs.contains(pid) else { return }
        fullAccessibilityPIDs.insert(pid)
        // Electron apps answer AXManualAccessibility; Chrome itself only AXEnhancedUserInterface
        // (seen: Chrome refused the first and kept reporting no focused field, AX error -25212).
        let manual = AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        if manual == .success {
            Log.info("Accessibility: full text access on in \(name ?? "pid \(pid)") (manual)")
            return
        }
        // AXEnhancedUserInterface only for Chromium browsers: in other apps it can slow down or
        // break window animations.
        guard let bundleID, chromiumBrowsers.contains(bundleID) else { return }
        let enhanced = AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Log.info("Accessibility: full text access in \(name ?? "pid \(pid)"): "
                 + (enhanced == .success ? "on (enhanced)" : "unavailable (\(manual.rawValue)/\(enhanced.rawValue))"))
    }

    // MARK: Screen context (spelling hints)

    /// Text visible around the cursor: the focused field near the caret, the window
    /// title and nearby labels/messages in the focused window. Used only to pick
    /// out names for spelling; never stored. nil for password fields and password
    /// managers. Safe to call off the main thread; bounded to ~0.3 s.
    static func screenText(maxChars: Int = 6000) -> String? {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let bundle = (app.bundleIdentifier ?? "").lowercased()
        if ["1password", "bitwarden", "lastpass", "dashlane", "keychainaccess", "keepass", "enpass", "proton.pass"]
            .contains(where: { bundle.contains($0) }) { return nil }

        let deadline = Date().addingTimeInterval(0.3)
        var parts: [String] = []
        var total = 0
        func add(_ t: String?) {
            guard let t, !t.isEmpty, total < maxChars else { return }
            let piece = String(t.prefix(maxChars - total))
            parts.append(piece)
            total += piece.count
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        if let focused: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) {
            AXUIElementSetMessagingTimeout(focused, 0.1)
            if let subrole: String = attribute(focused, kAXSubroleAttribute), subrole == (kAXSecureTextFieldSubrole as String) { return nil }
            if let value: String = attribute(focused, kAXValueAttribute), value.count <= 200_000 {
                // Up to 2,000 characters before the caret (what the user is replying to / writing).
                var caret = value.count
                var rangeRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
                   let rv = rangeRef, CFGetTypeID(rv) == AXValueGetTypeID() {
                    var range = CFRange()
                    if AXValueGetValue(rv as! AXValue, .cfRange, &range), range.location >= 0 { caret = min(value.count, range.location) }
                }
                let chars = Array(value)
                add(String(chars[max(0, caret - 2000)..<caret]))
                add(String(chars[caret..<min(chars.count, caret + 500)]))
            }
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.1)
        guard let window: AXUIElement = attribute(appElement, kAXFocusedWindowAttribute) else {
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        add(attribute(window, kAXTitleAttribute))

        // Breadth-first walk of the window for static text (chat messages, email
        // headers, labels). Bounded by element count, characters and time.
        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty, visited < 600, total < maxChars, Date() < deadline {
            let el = queue.removeFirst()
            visited += 1
            AXUIElementSetMessagingTimeout(el, 0.05)
            let role: String? = attribute(el, kAXRoleAttribute)
            if role == (kAXStaticTextRole as String) || role == "AXHeading" {
                add(attribute(el, kAXValueAttribute))
            }
            if let children: [AXUIElement] = attribute(el, kAXChildrenAttribute) {
                queue.append(contentsOf: children.prefix(60))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    // MARK: Watching the field after insertion (learning from corrections)

    /// The focused text element, unless it's a password field or exposes no text.
    static func focusedTextElement() -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard let el: AXUIElement = attribute(system, kAXFocusedUIElementAttribute) else { return nil }
        if let subrole: String = attribute(el, kAXSubroleAttribute), subrole == (kAXSecureTextFieldSubrole as String) { return nil }
        return stringValue(el) == nil ? nil : el
    }

    /// Full text of a field (nil when unavailable or unreasonably large).
    static func stringValue(_ el: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(el, 0.25)
        guard let v: String = attribute(el, kAXValueAttribute), v.count <= 50_000 else { return nil }
        return v
    }

    /// Text of a field for a character range (nil when the app doesn't support it).
    private static func string(_ element: AXUIElement, _ range: CFRange) -> String? {
        var r = range
        guard let value = AXValueCreate(.cfRange, &r) else { return nil }
        var strRef: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                          value, &strRef) == .success else { return nil }
        return strRef as? String
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return (value as! T)
        }
        return value as? T
    }

    // MARK: Pasteboard

    private struct SavedPasteboard {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private static func savePasteboard() -> SavedPasteboard {
        let pb = NSPasteboard.general
        let items = (pb.pasteboardItems ?? []).map { item -> [NSPasteboard.PasteboardType: Data] in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
        return SavedPasteboard(items: items)
    }

    private static func restorePasteboard(_ saved: SavedPasteboard) {
        let pb = NSPasteboard.general
        pb.clearContents()
        guard !saved.items.isEmpty else { return }
        let items = saved.items.map { dict -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(items)
    }

    /// Marks our temporary clipboard content so clipboard managers skip it
    /// (nspasteboard.org conventions).
    private static let transientTypes = [
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    // MARK: Insert

    /// Pastes `text` into the focused app, restoring the user's clipboard afterwards.
    static func insert(_ text: String, restoreClipboard: Bool) {
        guard !text.isEmpty else { return }
        SentMessageTracker.typed(in: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let saved = restoreClipboard ? savePasteboard() : nil

        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if restoreClipboard {
            for t in transientTypes { item.setData(Data(), forType: t) }
        }
        pb.writeObjects([item])
        let ourChange = pb.changeCount

        // A short pause so the target app sees the new clipboard before ⌘V arrives; Chrome
        // occasionally pasted nothing when the shortcut landed in the same instant (seen: two
        // Polish dictations into Chrome transcribed fine, nothing typed).
        usleep(30_000)
        postShortcut(key: "v")
        let app = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        Log.info("Insert: \(text.count) chars via ⌘V into \(app) (accessibility \(AXIsProcessTrusted() ? "on" : "OFF"))")

        if let saved {
            // Give the target app time to read the clipboard before restoring it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                // Only restore if nothing else touched the clipboard meanwhile.
                if NSPasteboard.general.changeCount == ourChange {
                    restorePasteboard(saved)
                }
            }
        }
    }

    /// Selected text via Accessibility, falling back to ⌘C for apps without AX text support.
    static func selectedText(axContext: FocusContext?) async -> String? {
        if let s = axContext?.selectedText, !s.isEmpty { return s }
        let saved = savePasteboard()
        let pb = NSPasteboard.general
        let before = pb.changeCount
        postShortcut(key: "c")
        var copied: String?
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 25_000_000)
            if pb.changeCount != before {
                copied = pb.string(forType: .string)
                break
            }
        }
        if pb.changeCount != before { restorePasteboard(saved) }
        return (copied?.isEmpty ?? true) ? nil : copied
    }

    // MARK: Keyboard events

    /// Posts ⌘+<key>, using the key code that produces `key` in the current
    /// layout (so it works on Dvorak, AZERTY, etc.).
    static func postShortcut(key: Character) {
        // Text Input Sources (TIS) must be read on the main thread: macOS traps (SIGILL in
        // dispatch_assert_queue) otherwise. The ⌘C fallback in selectedText runs off main.
        let found = Thread.isMainThread ? keyCode(for: key) : DispatchQueue.main.sync { keyCode(for: key) }
        let code = found ?? (key == "v" ? CGKeyCode(kVK_ANSI_V) : CGKeyCode(kVK_ANSI_C))
        // Private state: modifiers the user may still be holding (e.g. the dictation
        // key) don't leak into the synthetic shortcut; flags are set explicitly below.
        let source = CGEventSource(stateID: .privateState)
        // Real ⌘ press around the letter (not just a flag on the letter): Chromium-based apps
        // track modifier state from key events and sometimes ignore a bare flagged "v".
        let cmd = CGKeyCode(kVK_Command)
        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: true)
        let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmd, keyDown: false)
        cmdDown?.flags = .maskCommand
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        cmdUp?.flags = []
        for event in [cmdDown, down, up, cmdUp] {
            event?.post(tap: .cghidEventTap)
            usleep(8_000)
        }
    }

    private static var keyCodeCache: [String: [Character: CGKeyCode]] = [:]

    private static func keyCode(for character: Character) -> CGKeyCode? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return nil }
        let layoutID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
        if let cached = keyCodeCache[layoutID]?[character] { return cached }

        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue() as Data
        let target = String(character).utf16.first

        let found: CGKeyCode? = layoutData.withUnsafeBytes { raw -> CGKeyCode? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var deadKeyState: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState, chars.count, &length, &chars)
                if status == noErr, length == 1, chars[0] == target {
                    return CGKeyCode(code)
                }
            }
            return nil
        }
        if let found { keyCodeCache[layoutID, default: [:]][character] = found }
        return found
    }
}
