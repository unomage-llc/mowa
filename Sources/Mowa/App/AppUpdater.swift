import AppKit
@preconcurrency import Sparkle

/// Automatic updates via Sparkle (https://sparkle-project.org).
///
/// Feed: SUFeedURL in Info.plist (https://mowa.unomage.com/appcast.xml), written by
/// the release process. Every update is signed with the EdDSA key whose public half is
/// SUPublicEDKey in Info.plist; Sparkle refuses anything not signed with it, on top
/// of Apple's code signature and notarization.
///
/// With "Download and install updates automatically" on, a new version is downloaded
/// in the background and installed as soon as Mowa is idle (not listening or
/// processing). Mowa then relaunches itself. With it off, Sparkle shows its standard
/// "A new version is available" window.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    static let shared = AppUpdater()

    private var controller: SPUStandardUpdaterController?
    private var pendingInstall: (() -> Void)?
    private var idleTimer: Timer?

    /// False for builds without a valid SUPublicEDKey (e.g. a local dev build made
    /// before the signing key exists); the app then falls back to UpdateChecker.
    var isAvailable: Bool { controller != nil }

    private static var hasValidKey: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              let data = Data(base64Encoded: key) else { return false }
        return data.count == 32
    }

    func start() {
        guard controller == nil else { return }
        // A developer build (scripts/build.sh --dev) must not be replaced by the released version.
        guard !DevRecorder.isAvailable else {
            Log.info("Updater: off in developer builds")
            return
        }
        guard Self.hasValidKey else {
            Log.info("Updater: Sparkle disabled (no SUPublicEDKey in this build)")
            return
        }
        let c = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        controller = c
        applySettings()
        c.startUpdater()
        Log.info("Updater: Sparkle started (auto check \(c.updater.automaticallyChecksForUpdates), auto install \(c.updater.automaticallyDownloadsUpdates))")
    }

    /// Mirrors the two Settings toggles into Sparkle.
    func applySettings() {
        guard let updater = controller?.updater else { return }
        let s = AppSettings.shared
        updater.automaticallyChecksForUpdates = s.checkForUpdates
        updater.automaticallyDownloadsUpdates = s.checkForUpdates && s.autoInstallUpdates
    }

    /// Set while a "Check for Updates…" from the menu is waiting for Sparkle's answer.
    private var manualCheckPending = false

    /// "Check for Updates…" in the menu.
    ///
    /// Sparkle's own manual check shows "You're up to date!" with NSAlert.runModal(), run from
    /// inside a main-queue block: while that alert stays open no other main-queue work runs, so
    /// every dictation sat on the spinner until it was closed. Instead Mowa asks Sparkle for the
    /// update information only (no UI) and shows the same alert itself, but as a normal window
    /// that can stay open while the user keeps dictating. A real update still opens Sparkle's
    /// update window (not modal).
    func checkNow() {
        if let controller {
            guard !manualCheckPending else { return }
            manualCheckPending = true
            Log.info("Updater: manual check")
            controller.updater.checkForUpdateInformation()
        } else {
            UpdateChecker.shared.check(silently: false)
        }
    }

    private func finishManualCheck(found: Bool, error: Error?) {
        guard manualCheckPending else { return }
        manualCheckPending = false
        Log.info("Updater: manual check → \(found ? "update found" : (error == nil ? "up to date" : "failed"))")
        if found {
            // didFindValidUpdate arrives while the information check is still running, and
            // Sparkle silently ignores checkForUpdates() during a session — that was the
            // "nothing happens" after 1.0.20 came out. Wait for the session to end first.
            Task { @MainActor in
                for _ in 0..<50 {
                    guard let updater = self.controller?.updater, updater.sessionInProgress else { break }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
                NSApp.activate(ignoringOtherApps: true)
                self.controller?.checkForUpdates(nil)
            }
        } else if let error, (error as NSError).code != 1001 {
            Log.error("Updater: manual check failed: \(error.localizedDescription)")
            showResult(title: L("Couldn't check for updates."), text: L("Please try again later."))
        } else {
            showResult(title: L("You're up to date!"),
                       text: LF("Mowa %@ is currently the newest version available.", SystemInfo.appVersion))
        }
    }

    private func showResult(title: String, text: String) {
        NonModalAlert.closeAll()
        NonModalAlert.show(title: title, text: text)
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in self.finishManualCheck(found: true, error: nil) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        Task { @MainActor in self.finishManualCheck(found: false, error: nil) }
    }

    // MARK: SPUUpdaterDelegate

    /// An update was downloaded in the background. Instead of waiting for the user to
    /// quit Mowa (a menu bar app is rarely quit), install it as soon as Mowa is idle.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            Log.info("Updater: Mowa \(version) downloaded — installing when idle")
            self.pendingInstall = immediateInstallationBlock
            self.installWhenIdle()
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let ns = error as NSError
        // SUNoUpdateError (1001): "You're up to date" is not a failure.
        if ns.domain == SUSparkleErrorDomain, ns.code == 1001 { return }
        let message = error.localizedDescription
        Task { @MainActor in
            Log.error("Updater: \(message)")
            self.finishManualCheck(found: false, error: error)
        }
    }

    // MARK: SPUStandardUserDriverDelegate

    /// Mowa has no Dock icon; let Sparkle remind gently instead of stealing focus.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    // MARK: Idle install

    private func installWhenIdle() {
        idleTimer?.invalidate()
        idleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tryInstall() }
        }
    }

    private func tryInstall() {
        guard let install = pendingInstall else { idleTimer?.invalidate(); return }
        let phase = AppDelegate.shared.controller.state.phase
        guard case .idle = phase else { return }
        // Not while onboarding or Settings is open (a fresh install updated itself between
        // "Allow Microphone" and the next step and started onboarding over).
        if AppDelegate.shared.hasOpenWindows { return }
        // Don't cut in right after a dictation; the user may be about to speak again.
        if let last = AppDelegate.shared.controller.state.lastActivity, Date().timeIntervalSince(last) < 20 { return }
        idleTimer?.invalidate()
        idleTimer = nil
        pendingInstall = nil
        AppSettings.shared.updatedFromVersion = SystemInfo.appVersion
        Log.info("Updater: installing now and relaunching")
        install()
    }
}
