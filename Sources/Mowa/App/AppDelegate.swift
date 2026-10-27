import AppKit
import Combine
import MowaCore
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private(set) var controller: DictationController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var accessibilityPoll: Timer?
    private let settings = AppSettings.shared

    static var shared: AppDelegate { NSApp.delegate as! AppDelegate }

    /// Onboarding or Settings is open: the user is in the middle of something, so an
    /// automatic update must not restart Mowa now (it restarted onboarding on a fresh install).
    var hasOpenWindows: Bool {
        (onboardingWindow?.isVisible ?? false) || (settingsWindow?.isVisible ?? false)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AudioDucker.shared.recoverAfterCrash()
        MainThreadWatchdog.start()
        Log.info("Mowa \(SystemInfo.appVersion) starting — \(SystemInfo.physicalMemoryGB) GB RAM, \(Hardware.summary)")
        controller = DictationController()
        setupMainMenu()
        setupStatusItem()

        controller.state.$phase
            .combineLatest(controller.state.$speechModelReady, controller.state.$loadingMessage)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)

        controller.start()
        watchAccessibility()

        if !settings.onboardingDone || !Permissions.microphoneGranted || !Permissions.accessibilityGranted
            || !Transcriber.isDownloaded(settings.speechModelID) {
            showOnboarding()
        }
        else {
            // Give the menu bar a moment to place the status item before measuring it.
            // Right after an automatic update, say so instead of the usual "running" card.
            let updatedFrom = settings.updatedFromVersion
            settings.updatedFromVersion = nil
            let justUpdated = updatedFrom != nil && updatedFrom != SystemInfo.appVersion
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                LaunchNotice.shared.show(statusItem: self?.statusItem,
                                         title: justUpdated ? LF("Mowa updated to %@", SystemInfo.appVersion) : nil)
            }
        }
        // Automatic updates (Sparkle). Builds without an update signing key fall back
        // to the simple "a new version is on the website" check.
        AppUpdater.shared.start()
        if !AppUpdater.shared.isAvailable && settings.checkForUpdates && !DevRecorder.isAvailable {
            UpdateChecker.shared.check(silently: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AudioDucker.shared.restore(animated: false)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    /// Global key monitors only work once Accessibility is granted; re-arm them then.
    private func watchAccessibility() {
        guard !Permissions.accessibilityGranted else { return }
        accessibilityPoll = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self, Permissions.accessibilityGranted else { return }
                timer.invalidate()
                self.accessibilityPoll = nil
                self.controller.hotkey.start()
                Log.info("Accessibility granted — hotkey armed")
            }
        }
    }

    // MARK: Main menu

    /// Menu bar apps have no main menu by default, so ⌘V/⌘C/⌘A do nothing in
    /// Mowa's own windows — including the paste Mowa sends on the "Try it" screen.
    /// An (invisible) Edit menu gives text fields the standard key equivalents.
    private func setupMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("Quit Mowa"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        switch controller.state.phase {
        case .idle:
            symbol = controller.state.speechModelReady ? "waveform" : "waveform.slash"
        case .recording:
            symbol = "waveform.circle.fill"
        case .processing:
            symbol = "ellipsis.circle"
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mowa")
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Mowa"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = controller.state

        let status: String
        switch state.phase {
        case .idle:
            if let loading = state.loadingMessage { status = loading }
            else if !state.speechModelReady { status = L("Speech model not ready") }
            else { status = LF("Hold %@ to dictate", settings.hotkey.displayName) }
        case .recording: status = L("Listening…")
        case .processing(let message): status = message
        }
        let statusItem = NSMenuItem(title: status, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        if let error = state.lastError {
            let e = NSMenuItem(title: "⚠︎ " + error, action: nil, keyEquivalent: "")
            e.isEnabled = false
            menu.addItem(e)
        }
        menu.addItem(.separator())

        let toggleTitle: String
        if case .recording = state.phase { toggleTitle = L("Stop Dictation") } else { toggleTitle = L("Start Hands-Free Dictation") }
        menu.addItem(item(toggleTitle, #selector(toggleDictation)))

        let paste = item(L("Paste Last Dictation"), #selector(pasteLast))
        paste.isEnabled = state.lastResult != nil
        menu.addItem(paste)
        let copy = item(L("Copy Last Dictation"), #selector(copyLast))
        copy.isEnabled = state.lastResult != nil
        menu.addItem(copy)
        menu.addItem(.separator())

        // Cleanup level submenu
        let levelItem = NSMenuItem(title: L("Cleanup"), action: nil, keyEquivalent: "")
        let levelMenu = NSMenu()
        for level in CleanupLevel.allCases {
            let li = item(level.displayName, #selector(selectCleanupLevel(_:)))
            li.representedObject = level.rawValue
            li.state = settings.cleanupLevel == level ? .on : .off
            levelMenu.addItem(li)
        }
        levelItem.submenu = levelMenu
        menu.addItem(levelItem)

        menu.addItem(.separator())
        menu.addItem(item(L("Settings…"), #selector(showSettingsAction), key: ","))
        menu.addItem(item(L("Check for Updates…"), #selector(checkUpdates)))
        if RatePrompt.isEnabled { menu.addItem(item(L("Rate Mowa…"), #selector(rateMowa))) }
        menu.addItem(item(L("Sponsor Mowa…"), #selector(sponsorMowa)))
        menu.addItem(item(L("About Mowa"), #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(item(L("Quit Mowa"), #selector(quit), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func toggleDictation() { controller.toggleHandsFree() }
    @objc private func pasteLast() {
        // Let the menu close and focus return to the previous app first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.controller.pasteLast() }
    }
    @objc private func copyLast() { controller.copyLast() }
    @objc private func selectCleanupLevel(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let level = CleanupLevel(rawValue: raw) {
            settings.cleanupLevel = level
        }
    }
    @objc private func showHistory() { showSettings(tab: .history) }
    @objc private func showAbout() { showSettings(tab: .about) }
    @objc private func showSettingsAction() { showSettings() }
    @objc private func rateMowa() { RatePrompt.shared.openReviewPage() }
    @objc private func sponsorMowa() { SponsorPrompt.shared.openSponsorPage() }

    @objc private func checkUpdates() { AppUpdater.shared.checkNow() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Windows

    func showSettings(tab: SettingsTab = .general) {
        SettingsNavigation.shared.tab = tab
        if settingsWindow == nil {
            let view = SettingsView(controller: controller)
                .environmentObject(settings)
                .environmentObject(controller.state)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                                  styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = "Mowa"
            // Sidebar runs up behind the traffic lights, like System Settings.
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            // Fixed size, not resizable (Drew 2026-10-21). Only the position is remembered; a size
            // saved by an older (resizable) version is put back to 760 × 560.
            let size = NSSize(width: 760, height: 560)
            window.setFrameAutosaveName("MowaSettings")
            window.contentMinSize = size
            window.contentMaxSize = size
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(size)
            window.setFrameTopLeftPoint(topLeft)
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(controller: controller, onFinish: { [weak self] in
                self?.settings.onboardingDone = true
                self?.onboardingWindow?.close()
                // Point new users at the menu bar icon, regardless of the setting.
                LaunchNotice.shared.show(statusItem: self?.statusItem, force: true)
            })
            .environmentObject(settings)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                                  styleMask: [.titled, .closable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.title = L("Welcome to Mowa")
            window.titlebarAppearsTransparent = true
            window.contentView = NSHostingView(rootView: view)
            window.isReleasedWhenClosed = false
            window.center()
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }
}

extension CleanupLevel {
    var displayName: String {
        switch self {
        case .off: return L("Off — exactly as heard")
        case .light: return L("Light — fillers and punctuation (instant)")
        case .smart: return L("Smart — AI cleanup (recommended)")
        }
    }
}

extension AppCategory {
    var displayName: String {
        switch self {
        case .personal: return L("Personal messages")
        case .work: return L("Work chat")
        case .email: return L("Email")
        case .other: return L("Everything else")
        }
    }
}

extension WritingStyle {
    var displayName: String {
        switch self {
        case .formal: return L("Formal")
        case .casual: return L("Casual")
        case .veryCasual: return L("Very casual")
        case .excited: return L("Excited!")
        }
    }

    /// One-line preview shown under the picker.
    var example: String {
        switch self {
        case .formal: return L("Hey, are you free tomorrow? Let's meet at 6.")
        case .casual: return L("Hey are you free tomorrow? Let's meet at 6.")
        case .veryCasual: return L("hey are you free tomorrow? let's meet at 6.")
        case .excited: return L("Hey, are you free tomorrow? Let's meet at 6!")
        }
    }
}
