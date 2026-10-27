import AppKit
import SwiftUI

/// "Like Mowa? Support it!" card. Shown once the user has really used the app
/// (300 dictations of 3+ words), never while they are dictating, and at most twice
/// ever: "Later" asks once more after another 300; "Support Mowa", "Don't ask again"
/// or opening the sponsor page from the menu stop it for good.
@MainActor
final class SponsorPrompt {
    static let shared = SponsorPrompt()

    /// Successful dictations before the first ask, and extra ones after "Later".
    static let firstAskAfter = 300
    static let laterAskAfter = 300

    /// mowa.unomage.com/<lang>/sponsor in the app's UI language.
    static var sponsorURL: URL {
        let paths = ["pl": "/pl", "ru": "/ru", "es": "/es", "de": "/de", "fr": "/fr", "pt-BR": "/pt-br", "pt": "/pt-br", "it": "/it"]
        let lang = Bundle.main.preferredLocalizations.first ?? "en"
        let prefix = paths[lang] ?? paths[String(lang.prefix(2))] ?? ""
        return UpdateChecker.website.appendingPathComponent(prefix + "/sponsor")
    }

    private enum State: String { case waiting, later, done }
    private let d = UserDefaults.standard
    private var panel: NSPanel?

    private var count: Int {
        get { d.integer(forKey: "sponsorPromptCount") }
        set { d.set(newValue, forKey: "sponsorPromptCount") }
    }
    private var state: State {
        get { State(rawValue: d.string(forKey: "sponsorPromptState") ?? "") ?? .waiting }
        set { d.set(newValue.rawValue, forKey: "sponsorPromptState") }
    }
    private var nextAskAt: Int {
        get { d.object(forKey: "sponsorPromptNextAt") as? Int ?? Self.firstAskAfter }
        set { d.set(newValue, forKey: "sponsorPromptNextAt") }
    }

    /// Call after every successful dictation. `isBusy` is re-checked just before
    /// showing so the card never appears while the user is recording.
    func recordDictation(words: Int, isBusy: @escaping @MainActor () -> Bool) {
        guard words >= 3, state != .done else { return }
        count += 1
        guard count >= nextAskAt else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !isBusy(), self.panel == nil else { return }
            self.show()
        }
    }

    /// The card's button and the menu bar "Sponsor Mowa…" item.
    func openSponsorPage() {
        state = .done
        close()
        NSWorkspace.shared.open(Self.sponsorURL)
        Log.info("Sponsor page opened")
    }

    private func later() {
        if state == .later { state = .done } else {
            state = .later
            nextAskAt = count + Self.laterAskAfter
        }
        close()
        Log.info("Sponsor prompt: later")
    }

    private func never() {
        state = .done
        close()
        Log.info("Sponsor prompt: don't ask again")
    }

    private func show() {
        let view = SponsorPromptView(
            onSupport: { [weak self] in self?.openSponsorPage() },
            onLater: { [weak self] in self?.later() },
            onNever: { [weak self] in self?.never() })
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let host = NSHostingView(rootView: view)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let v = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: v.maxX - panel.frame.width - 16, y: v.maxY - panel.frame.height - 12))
        panel.orderFrontRegardless()
        self.panel = panel
        Log.info("Sponsor prompt shown after \(count) dictations")
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct SponsorPromptView: View {
    let onSupport: () -> Void
    let onLater: () -> Void
    let onNever: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Like Mowa? Support it!"))
                        .font(.headline)
                    Text(L("Mowa is free, with no ads or subscriptions. If it saves you time, you can support its development."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Button(L("Don't ask again"), action: onNever)
                    .buttonStyle(.link)
                    .font(.caption)
                Spacer()
                Button(L("Later"), action: onLater)
                    .controlSize(.small)
                Button(L("Support Mowa"), action: onSupport)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}
