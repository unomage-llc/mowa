import AudioToolbox
import CoreAudio
import Foundation

/// Turns the Mac's output volume almost all the way down while the user is
/// dictating (music, videos, calls), then fades it back. Works on the default
/// output device's master volume, so it affects every app. Devices without a
/// settable volume (some HDMI/USB outputs) are left alone.
@MainActor
final class AudioDucker {
    static let shared = AudioDucker()

    /// Ducked volume as a fraction of the user's volume ("almost muted").
    private let duckFactor: Float = 0.1
    private let fadeDuration: Double = 0.25
    private let fadeSteps = 10

    private var device: AudioDeviceID?
    private var originalVolume: Float?
    private var duckedVolume: Float?
    private var fadeTask: Task<Void, Never>?
    private var pendingDuck: Task<Void, Never>?
    /// Re-checks after a restore (see `settle`).
    private var settleTask: Task<Void, Never>?
    /// The volume the last restore put back, per output device (see `performDuck`).
    private var lastRestore: (uid: String, volume: Float, at: Date)?

    private let savedKey = "duckedOriginalVolume"
    private let savedDeviceKey = "duckedDeviceUID"

    private init() {}

    /// Starts ducking shortly after recording begins, so the start chime is still heard.
    /// `fadeTime`: how long the fade down takes (dictation uses a short one, so little music reaches the mic).
    func duck(after delay: Double = 0.15, fadeTime: Double? = nil) {
        guard AppSettings.shared.duckAudio, originalVolume == nil else { return }
        settleTask?.cancel()
        settleTask = nil
        pendingDuck?.cancel()
        pendingDuck = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.performDuck(fadeTime: fadeTime)
        }
    }

    /// Fades the volume back to where it was. Safe to call when not ducked.
    func restore(animated: Bool = true) {
        pendingDuck?.cancel()
        pendingDuck = nil
        guard let device, let original = originalVolume else { return }
        // Stop a fade-down that may still be running (short dictations).
        fadeTask?.cancel()
        let uid = Self.uid(of: device)
        if let uid { lastRestore = (uid, original, Date()) }
        let current = Self.volume(of: device) ?? 0
        originalVolume = nil
        duckedVolume = nil
        self.device = nil
        clearSaved()
        Log.info(String(format: "Volume: restore %.2f → %.2f", current, original))
        // Only skip if the user turned the volume up above their original level themselves.
        if current < original {
            if animated {
                fade(device, from: current, to: original)
            } else {
                Self.setVolume(original, of: device)
            }
        }
        if animated { settle(uid: uid, original: original) }
    }

    /// Bluetooth headphones switch profile while their microphone is in use (music ↔ call mode)
    /// and keep a separate volume per profile. The switch can land in the middle of a fade, so the
    /// music profile is left partly turned down — and the next dictation took that as the user's
    /// volume, so music got quieter after every dictation (2026-10-19). For a few seconds after a
    /// restore, if the same output is below the user's volume, set it back.
    private func settle(uid: String?, original: Float) {
        settleTask?.cancel()
        guard let uid else { return }
        settleTask = Task { @MainActor in
            for delay in [0.4, 0.8, 1.5, 3.0] {   // seconds after the previous check
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let dev = Self.defaultOutputDevice(), Self.uid(of: dev) == uid,
                      let now = Self.volume(of: dev) else { continue }
                if now < original - 0.01 {
                    Self.setVolume(original, of: dev)
                    Log.info(String(format: "Volume: %.2f after restore — set back to %.2f", now, original))
                }
            }
        }
    }

    /// Called at launch: if Mowa quit or crashed while ducked, put the volume back.
    func recoverAfterCrash() {
        let d = UserDefaults.standard
        guard d.object(forKey: savedKey) != nil else { return }
        let original = d.float(forKey: savedKey)
        if let uid = d.string(forKey: savedDeviceKey), let dev = Self.defaultOutputDevice(),
           Self.uid(of: dev) == uid, let current = Self.volume(of: dev), current < original {
            Self.setVolume(original, of: dev)
            Log.info("Restored output volume after an unclean exit")
        }
        clearSaved()
    }

    private func performDuck(fadeTime: Double? = nil) {
        pendingDuck = nil
        guard originalVolume == nil, let dev = Self.defaultOutputDevice(), Self.isVolumeSettable(dev),
              !Self.isMuted(dev), var current = Self.volume(of: dev), current > 0.01 else { return }
        // Right after a dictation the volume can still be partly turned down (Bluetooth profile
        // switch, see `settle`); never take that as the user's volume, or each dictation would
        // leave the music quieter than the one before.
        if let last = lastRestore, last.uid == Self.uid(of: dev), Date().timeIntervalSince(last.at) < 20,
           current < last.volume - 0.01 {
            Log.info(String(format: "Volume: %.2f is below the restored %.2f — using %.2f as the user's volume", current, last.volume, last.volume))
            current = last.volume
        }
        let target = current * duckFactor
        Log.info(String(format: "Volume: duck %.2f → %.2f", current, target))
        device = dev
        originalVolume = current
        duckedVolume = target
        let d = UserDefaults.standard
        d.set(current, forKey: savedKey)
        d.set(Self.uid(of: dev), forKey: savedDeviceKey)
        fade(dev, from: current, to: target, duration: fadeTime ?? fadeDuration)
    }

    private func clearSaved() {
        UserDefaults.standard.removeObject(forKey: savedKey)
        UserDefaults.standard.removeObject(forKey: savedDeviceKey)
    }

    private func fade(_ dev: AudioDeviceID, from: Float, to: Float, duration: Double? = nil) {
        fadeTask?.cancel()
        let steps = fadeSteps
        let interval = UInt64((duration ?? fadeDuration) / Double(steps) * 1_000_000_000)
        fadeTask = Task { @MainActor in
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                Self.setVolume(from + (to - from) * Float(step) / Float(steps), of: dev)
            }
        }
    }

    // MARK: CoreAudio

    nonisolated private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    nonisolated private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    nonisolated private static func isVolumeSettable(_ dev: AudioDeviceID) -> Bool {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr && settable.boolValue
    }

    nonisolated private static func volume(of dev: AudioDeviceID) -> Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &value) == noErr ? value : nil
    }

    /// Volume changes go to a serial background queue: on a Bluetooth headset switching back from
    /// call mode a CoreAudio volume write can block, and the fade ran on the main thread exactly
    /// while the overlay animated into the spinner (it looked frozen).
    nonisolated private static let volumeQueue = DispatchQueue(label: "mowa.volume", qos: .userInitiated)
    /// Runs `block` (off the main thread) after every volume change asked for so far has been applied.
    nonisolated static func afterVolumeChanges(_ block: @escaping () -> Void) { volumeQueue.async(execute: block) }

    nonisolated private static func setVolume(_ value: Float, of dev: AudioDeviceID) {
        volumeQueue.async { setVolumeNow(value, of: dev) }
    }

    nonisolated private static func setVolumeNow(_ value: Float, of dev: AudioDeviceID) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        var v = Float32(min(1, max(0, value)))
        let status = AudioObjectSetPropertyData(dev, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        if status != noErr { Log.error("Setting output volume failed: \(status)") }
    }

    nonisolated private static func isMuted(_ dev: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(dev, &addr) else { return false }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &muted) == noErr && muted != 0
    }

    nonisolated private static func uid(of dev: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
