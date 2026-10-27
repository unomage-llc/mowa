import AppKit

/// An NSAlert shown as an ordinary window instead of with `runModal()`.
///
/// Never use `NSAlert.runModal()`, `NSOpenPanel.runModal()` or `NSApp.runModal(for:)` in Mowa:
/// while an app-modal session runs (especially one started from a main-queue block, as Sparkle
/// does), no other main-queue work runs either, so dictations sit on the spinner until the
/// window is closed. These alerts can stay open while the user keeps dictating into other apps.
/// scripts/selftest.sh fails the build check if `runModal` appears in Sources.
@MainActor
final class NonModalAlert: NSObject {
    /// Alerts on screen (kept alive until closed).
    private static var open: [NonModalAlert] = []

    private let alert = NSAlert()
    private var actions: [(() -> Void)?] = []

    /// `buttons`: titles with optional actions, first one is the default (Return),
    /// the last of two or more is the cancel button (Esc).
    static func show(title: String, text: String,
                     buttons: [(title: String, action: (() -> Void)?)] = [(L("OK"), nil)]) {
        let a = NonModalAlert()
        a.alert.messageText = title
        a.alert.informativeText = text
        a.alert.icon = NSApp.applicationIconImage
        for (i, b) in buttons.enumerated() {
            let button = a.alert.addButton(withTitle: b.title)
            button.tag = i
            button.target = a
            button.action = #selector(pressed(_:))
            button.keyEquivalent = i == 0 ? "\r" : (i == buttons.count - 1 ? "\u{1b}" : "")
            a.actions.append(b.action)
        }
        a.alert.layout()
        open.append(a)
        NSApp.activate(ignoringOtherApps: true)
        a.alert.window.center()
        a.alert.window.makeKeyAndOrderFront(nil)
    }

    /// Closes every open alert (e.g. before showing a newer result of the same check).
    static func closeAll() {
        for a in open { a.alert.window.close() }
        open.removeAll()
    }

    @objc private func pressed(_ sender: NSButton) {
        alert.window.close()
        Self.open.removeAll { $0 === self }
        if sender.tag < actions.count { actions[sender.tag]?() }
    }
}
