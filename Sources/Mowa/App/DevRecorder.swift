import Foundation
import MowaCore

/// Developer builds only (`scripts/build.sh --dev`): saves every dictation — the audio exactly as
/// recorded plus what Mowa made of it — so it can be replayed by the eval (`REAL=1 scripts/eval.sh`).
///
/// A build is a developer build when its Info.plist has `MowaDevRecordingsDir` (the folder to save
/// into, written by build.sh --dev). Release builds don't have the key, so they never show the
/// toggle and never save anything; release builds never include it.
enum DevRecorder {
    /// Where recordings go; nil in release builds.
    static let directory: URL? = {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "MowaDevRecordingsDir") as? String,
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }()

    /// This is a developer build.
    static var isAvailable: Bool { directory != nil }

    /// Saving is on (developer build + Settings → General → Save recordings for testing).
    @MainActor static var isOn: Bool { isAvailable && AppSettings.shared.devSaveRecordings }

    /// Starts the record of one finished recording (writes audio.wav in the background).
    /// nil when saving is off.
    @MainActor static func begin(samples: [Float], peak: Float, mode: DictationMode, startContext: FocusContext?) -> DevRecord? {
        guard isOn, let directory else { return nil }
        let date = Date()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let folder = directory.appendingPathComponent("\(stamp.string(from: date))_\(id)", isDirectory: true)
        let settings = AppSettings.shared
        // Log lines from the key press on (the recording itself plus a second before it).
        let record = DevRecord(folder: folder,
                               logSince: date.addingTimeInterval(-Double(samples.count) / AudioRecorder.sampleRate - 1))
        let iso = ISO8601DateFormatter()
        record.set([
            "id": id,
            "date": iso.string(from: date),
            "app_version": SystemInfo.appVersion,
            "hardware": Hardware.summary,
            "mode": mode.rawValue,
            "audio_seconds": Double(samples.count) / AudioRecorder.sampleRate,
            "peak": Double(peak),
            "start_app": startContext?.appName ?? "",
            "start_bundle": startContext?.bundleID ?? "",
            "settings": [
                "languages": settings.candidateLanguages.map(\.rawValue),
                "accept_other_languages": settings.acceptOtherLanguages,
                "speech_model": settings.speechModelID,
                "cleanup_model": settings.cleanupModelID,
                "cleanup_level": settings.cleanupLevel.rawValue,
                "noise_reduction": settings.noiseReduction,
                "voice_filter": settings.voiceFilter,
                "context_aware_style": settings.contextAwareStyle,
                "screen_context": settings.useScreenContext,
                "keyboard_language": settings.writeInKeyboardLanguage,
                "microphone": AudioDevices.currentMicrophone()?.name ?? "",
            ] as [String: Any],
        ])
        record.writeAudio(samples)
        return record
    }
}

/// One saved dictation: `<folder>/audio.wav` + `<folder>/meta.json` (rewritten on every update).
final class DevRecord: @unchecked Sendable {
    let folder: URL
    private var meta: [String: Any] = [:]
    private static let queue = DispatchQueue(label: "mowa.dev-recordings", qos: .utility)

    private let logSince: Date

    init(folder: URL, logSince: Date) {
        self.folder = folder
        self.logSince = logSince
    }

    /// Adds/replaces fields and rewrites meta.json. Every update also refreshes "log": Mowa's log
    /// lines for this dictation (why it was translated, retried, discarded…).
    func set(_ fields: [String: Any]) {
        let since = logSince
        Self.queue.async { [self] in
            for (k, v) in fields { meta[k] = v }
            meta["log"] = Log.lines(since: since)
            write()
        }
    }

    func writeAudio(_ samples: [Float]) {
        Self.queue.async { [folder] in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try WAV.pcm16(samples, sampleRate: Int(AudioRecorder.sampleRate))
                    .write(to: folder.appendingPathComponent("audio.wav"), options: .atomic)
            } catch {
                Log.error("Dev recording: saving audio failed: \(error.localizedDescription)")
            }
        }
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: folder.appendingPathComponent("meta.json"), options: .atomic)
        } catch {
            Log.error("Dev recording: saving meta.json failed: \(error.localizedDescription)")
        }
    }
}

/// 16-bit PCM mono WAV encoder (the eval and Whisper read it back with AudioProcessor).
enum WAV {
    static func pcm16(_ samples: [Float], sampleRate: Int) -> Data {
        var data = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(bytes)
        data.reserveCapacity(data.count + Int(bytes))
        for s in samples {
            let v = Int16(max(-1, min(1, s)) * 32767)
            u16(UInt16(bitPattern: v))
        }
        return data
    }
}
