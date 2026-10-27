import AppKit
import Foundation
import MowaCore

/// Chat apps clear the message box when Return sends the message, but Chromium/Electron apps
/// (Claude, Slack…) keep reporting the sent text through Accessibility. Dev recordings
/// 2026-10-19/20: 62 Claude dictations started with a space (or lost their capital and full stop)
/// because Mowa "saw" the previous message before the caret of an empty box.
/// A plain Return in a chat app marks its box as just sent; any other key or a Mowa insertion
/// in that app clears the mark.
enum SentMessageTracker {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sent: Set<String> = []

    /// Every key press seen by the global key monitor (HotkeyMonitor).
    static func keyDown(_ event: NSEvent) {
        guard let bundle = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return }
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        let isSend = (event.keyCode == 36 || event.keyCode == 76) && mods.isEmpty
        lock.lock(); defer { lock.unlock() }
        if isSend, AppContextStyle.classify(bundleID: bundle) == .chat {
            sent.insert(bundle)
        } else {
            sent.remove(bundle)
        }
    }

    /// Mowa typed into this app: its box isn't empty any more.
    static func typed(in bundle: String?) {
        guard let bundle else { return }
        lock.lock(); sent.remove(bundle); lock.unlock()
    }

    /// The last thing done in this app's message box was sending it with Return.
    static func justSent(_ bundle: String?) -> Bool {
        guard let bundle else { return false }
        lock.lock(); defer { lock.unlock() }
        return sent.contains(bundle)
    }
}
