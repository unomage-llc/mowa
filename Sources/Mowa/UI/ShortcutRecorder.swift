import AppKit
import SwiftUI

/// Settings → Key and onboarding: fn, or a key / combination the user records.
/// Choosing "Custom shortcut" starts recording right away; cancelling a first recording goes back to fn.
struct HotkeyPicker: View {
    let title: String
    @EnvironmentObject var settings: AppSettings
    @StateObject private var recorder = ShortcutRecorderModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: Binding(
                get: { settings.hotkey },
                set: { choose($0) })) {
                ForEach(HotkeyChoice.allCases) { choice in
                    if choice == .fn {
                        // "fn" with the outline globe after it (the symbol takes the text colour).
                        Text("fn \(Image(systemName: "globe"))").tag(choice)
                    } else {
                        Text(choice.title).tag(choice)
                    }
                }
            }
            if settings.hotkey == .custom || recorder.isRecording {
                HStack(spacing: 10) {
                    Spacer()
                    if recorder.isRecording {
                        Text(L("Press the keys, then let go…"))
                            .foregroundStyle(.secondary)
                        Button(L("Cancel")) { recorder.cancel() }
                    } else {
                        Text(settings.customShortcut?.name ?? "")
                            .font(.body.monospaced())
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15)))
                        Button(L("Change…")) { record() }
                    }
                }
                Text(recorder.message ?? L("Up to 5 keys pressed together. Hold them to talk."))
                    .font(.caption)
                    .foregroundStyle(recorder.message == nil ? Color.secondary : Color.orange)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .onDisappear { recorder.cancel() }
    }

    private func choose(_ choice: HotkeyChoice) {
        if choice == .custom, settings.customShortcut == nil {
            record()   // fn stays the key until a shortcut is recorded
        } else if choice != settings.hotkey {
            recorder.cancel()
            settings.hotkey = choice
            AppDelegate.shared.controller.applyHotkeyChange()
        }
    }

    private func record() {
        recorder.start { shortcut in
            guard let shortcut else { return }
            settings.customShortcut = shortcut
            settings.hotkey = .custom
            AppDelegate.shared.controller.applyHotkeyChange()
        }
    }
}

/// Records one shortcut from the keyboard while Settings is in front: every key held at the same
/// time (up to Shortcut.maxKeys) becomes the shortcut when they are all let go. Dictation is paused
/// meanwhile, so pressing the current key doesn't start a recording. Esc alone cancels.
@MainActor
final class ShortcutRecorderModel: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var message: String?
    private var monitor: Any?
    private var down: Set<UInt16> = []
    private var pressed: [UInt16] = []          // every key pressed in this chord, in order
    private var names: [UInt16: String] = [:]
    private var done: ((Shortcut?) -> Void)?

    func start(_ completion: @escaping (Shortcut?) -> Void) {
        cancel()
        done = completion
        isRecording = true
        message = nil
        down.removeAll(); pressed.removeAll(); names.removeAll()
        AppDelegate.shared.controller.hotkey.paused = true
        // Local monitors run on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return event }
                self.handle(event)
                return nil   // nothing typed or triggered while recording
            }
        }
    }

    func cancel() {
        guard isRecording else { return }
        finish(nil)
        message = nil
    }

    private func finish(_ shortcut: Shortcut?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        AppDelegate.shared.controller.hotkey.paused = false
        let completion = done
        done = nil
        completion?(shortcut)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            if event.isARepeat { return }
            if event.keyCode == 53, pressed.isEmpty {   // Esc on its own: stop recording
                cancel()
                return
            }
            names[event.keyCode] = Shortcut.keyName(event)
            keyWentDown(event.keyCode)
        case .keyUp:
            keyWentUp(event.keyCode)
        case .flagsChanged:
            guard let mask = Shortcut.modifierMasks[event.keyCode] else { return }   // Caps Lock
            if UInt64(event.modifierFlags.rawValue) & mask != 0 {
                keyWentDown(event.keyCode)
            } else {
                keyWentUp(event.keyCode)
            }
        default:
            break
        }
    }

    private func keyWentDown(_ key: UInt16) {
        down.insert(key)
        guard !pressed.contains(key) else { return }
        if pressed.count >= Shortcut.maxKeys {
            message = LF("Up to %d keys.", Shortcut.maxKeys)
            return
        }
        pressed.append(key)
    }

    private func keyWentUp(_ key: UInt16) {
        down.remove(key)
        // All let go: the keys held together are the shortcut.
        guard down.isEmpty, !pressed.isEmpty else { return }
        message = nil
        finish(Shortcut(keys: pressed, name: Shortcut.name(keys: pressed, keyNames: names)))
    }
}
