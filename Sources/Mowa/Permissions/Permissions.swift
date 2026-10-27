import AppKit
import AVFoundation
import ApplicationServices
import ServiceManagement

enum Permissions {
    // MARK: Microphone

    static var microphoneGranted: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static var microphoneDenied: Bool {
        let s = AVCaptureDevice.authorizationStatus(for: .audio)
        return s == .denied || s == .restricted
    }

    static func requestMicrophone() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
    }

    // MARK: Accessibility (global hotkey + pasting)

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Mowa to Privacy & Security → Accessibility.
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// One dialog, never two. The first time: only the system prompt (it adds Mowa to the
    /// Accessibility list, and its "Open System Settings" button opens the right page). Showing
    /// it together with the settings page left the prompt hanging on screen after the user had
    /// already switched Mowa on. Later clicks open the settings page directly.
    static func askForAccessibility() {
        let d = UserDefaults.standard
        if d.bool(forKey: "accessibilityPromptShown") {
            openAccessibilitySettings()
        } else {
            d.set(true, forKey: "accessibilityPromptShown")
            requestAccessibility()
        }
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    static func openKeyboardSettings() {
        open("x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
    }

    private static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }

    // MARK: Launch at login

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.error("Launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}

/// Short system sounds for start/stop feedback.
enum Feedback {
    static func start() {
        guard let name = AppSettings.shared.sound.startSound else { return }
        queue.async { playNow(name) }
    }

    /// The stop sound, never on the main thread.
    ///
    /// Normally it plays the moment the key is released, together with the line winding into the
    /// spinner (2026-10-20: played after the mic had closed and the volume had faded back, it came
    /// ~0.5 s late and felt like the spinner slowed down). The caller restores the volume instantly
    /// first; the sound waits only for that volume change to land, so it isn't played ducked.
    ///
    /// With a Bluetooth headset it has to wait until the headset is back in music mode: played
    /// during its switch out of call mode it was simply lost (2026-10-20).
    static func stop(afterBluetooth: Bool = false) {
        guard let name = AppSettings.shared.sound.stopSound else { return }
        if afterBluetooth {
            AudioRecorder.afterInputClosed {
                queue.async {
                    waitForMusicMode()
                    playNow(name)
                }
            }
        } else {
            AudioDucker.afterVolumeChanges { queue.async { playNow(name) } }
        }
    }
    /// Length of the chosen start sound (0 when sounds are off).
    static var startSoundSeconds: TimeInterval {
        guard let name = AppSettings.shared.sound.startSound,
              let url = Bundle.main.url(forResource: name, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Length of the chosen stop sound (0 when sounds are off).
    static var stopSoundSeconds: TimeInterval {
        guard let name = AppSettings.shared.sound.stopSound,
              let url = Bundle.main.url(forResource: name, withExtension: "wav"),
              let file = try? AVAudioFile(forReading: url), file.fileFormat.sampleRate > 0 else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }

    /// Mowa's own sounds play at this volume (start and stop the same, a bit below full).
    private static let ownSoundVolume: Float = 0.65

    /// Waits (on `queue`) until the default output runs at a music sample rate again, then a
    /// moment more for the headset to settle; gives up after 2.5 s.
    private static func waitForMusicMode() {
        let deadline = Date().addingTimeInterval(2.5)
        var sawCallMode = false
        while Date() < deadline {
            let rate = AudioDevices.defaultOutputSampleRate() ?? 48_000
            if rate >= 32_000 {
                if sawCallMode { Thread.sleep(forTimeInterval: 0.2) }
                return
            }
            sawCallMode = true
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    /// Settings preview: the start sound, then the stop sound, as in a short dictation.
    static func preview(_ choice: SoundChoice) {
        guard let start = choice.startSound, let stop = choice.stopSound else { return }
        queue.async { playNow(start) }
        queue.asyncAfter(deadline: .now() + 0.55) { playNow(stop) }
    }

    static func error() {
        guard AppSettings.shared.sound != .off else { return }
        queue.async { playNow("Basso") }
    }

    /// Loading and starting a sound can wait on CoreAudio; keep that off the main thread so the
    /// overlay's animation never stutters.
    private static let queue = DispatchQueue(label: "mowa.feedback-sounds", qos: .userInitiated)
    private static var sounds: [String: NSSound] = [:]   // only touched on `queue`

    private static func playNow(_ name: String) {
        if sounds[name] == nil {
            // Mowa's own sounds ship in the app (Support/Sounds);
            // macOS system sounds (the error sound) are full-scale, so they are turned down.
            if let url = Bundle.main.url(forResource: name, withExtension: "wav"),
               let own = NSSound(contentsOf: url, byReference: false) {
                own.volume = ownSoundVolume
                sounds[name] = own
            } else if let system = NSSound(named: NSSound.Name(name))?.copy() as? NSSound {
                system.volume = 0.35
                sounds[name] = system
            }
        }
        guard let sound = sounds[name] else { return }
        sound.stop()
        sound.play()
    }
}
