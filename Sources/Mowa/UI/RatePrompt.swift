import AppKit
import SwiftUI

/// "Enjoying Mowa?" card. Asks for a review once the user has dictated enough to
/// have an opinion, never while they are dictating, and at most twice ever
/// ("Later" asks one more time much later; "Write a review" / "Don't ask again" stop it).
@MainActor
final class RatePrompt {
    static let shared = RatePrompt()

    /// Review feature is switched off for now (no public review page yet).
    /// Flip to true to bring back the "Enjoying Mowa?" card and the menu item.
    static let isEnabled = false

    /// Successful dictations before the first ask, and extra ones after "Later".
    static let firstAskAfter = 60
    static let laterAskAfter = 150
    /// The review link goes through the website so the target can change without an app update.
    static let reviewURL = URL(string: "https://mowa.unomage.com/review?utm_source=app&utm_medium=rate_prompt")!

    private enum State: String { case waiting, later, done }
    private let d = UserDefaults.standard
    private var panel: NSPanel?

    private var count: Int {
        get { d.integer(forKey: "ratePromptCount") }
        set { d.set(newValue, forKey: "ratePromptCount") }
    }
    private var state: State {
        get { State(rawValue: d.string(forKey: "ratePromptState") ?? "") ?? .waiting }
        set { d.set(newValue.rawValue, forKey: "ratePromptState") }
    }
    private var nextAskAt: Int {
        get { d.object(forKey: "ratePromptNextAt") as? Int ?? Self.firstAskAfter }
        set { d.set(newValue, forKey: "ratePromptNextAt") }
    }

    /// Call after every successful dictation. `isBusy` is re-checked just before
    /// showing so the card never appears while the user is recording.
    func recordDictation(words: Int, isBusy: @escaping @MainActor () -> Bool) {
        guard Self.isEnabled, words >= 3, state != .done else { return }
        count += 1
        guard count >= nextAskAt else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, !isBusy(), self.panel == nil else { return }
            self.show()
        }
    }

    /// Menu bar "Rate Mowa…" item: always opens the review page.
    func openReviewPage() {
        state = .done
        close()
        NSWorkspace.shared.open(Self.reviewURL)
        Log.info("Rate prompt: review page opened")
    }

    private func later() {
        if state == .later { state = .done } else {
            state = .later
            nextAskAt = count + Self.laterAskAfter
        }
        close()
        Log.info("Rate prompt: later")
    }

    private func never() {
        state = .done
        close()
        Log.info("Rate prompt: don't ask again")
    }

    private func show() {
        let view = RatePromptView(
            onReview: { [weak self] in self?.openReviewPage() },
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
        Log.info("Rate prompt shown after \(count) dictations")
    }

    private func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct RatePromptView: View {
    let onReview: () -> Void
    let onLater: () -> Void
    let onNever: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Enjoying Mowa?"))
                        .font(.headline)
                    Text(L("Mowa is free. A short review helps other Mac users find it."))
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
                Button(L("Write a review"), action: onReview)
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
