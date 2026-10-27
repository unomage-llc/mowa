import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import MowaCore

enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    case startTimedOut

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return L("No microphone found.")
        case .converterUnavailable: return L("Could not set up audio conversion.")
        case .startTimedOut: return L("The microphone didn't respond. Try again in a moment.")
        }
    }
}

/// Records the microphone into 16 kHz mono Float32 samples (what Whisper wants)
/// and reports the input level for the overlay's waveform.
final class AudioRecorder {
    /// Called on the audio thread with a 0…1 level (mapped from -60…0 dBFS).
    var onLevel: ((Float) -> Void)?

    private var engine: AVAudioEngine?
    /// Recording from a mic other than the macOS input (see CaptureInput); engine is nil then.
    private var capture: CaptureInput?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var peak: Float = 0
    private(set) var isRecording = false

    static let sampleRate: Double = 16_000

    /// How long opening the microphone may take before the recording is given up. CoreAudio can
    /// block for a long time (or forever) while a Bluetooth headset is connecting or switching
    /// profiles; that used to run on the main thread and froze the whole app (2026-10-19 20:47).
    static let startTimeout: TimeInterval = 3

    /// Records with the input selected in macOS, or — while Bluetooth headphones are connected — with the
    /// microphone picked in Settings → "Microphone with Bluetooth headphones" (default: same as macOS).
    func start() throws {
        stopEngine()
        lock.withLock {
            samples.removeAll(keepingCapacity: true)
            samples.reserveCapacity(16_000 * 60)
            peak = 0
            lastBufferAt = nil
        }
        restarts = 0
        try openInput()
        if let device = AudioDevices.currentMicrophone() {
            Log.info("Microphone: input started — \(device.name)")
        }
    }

    /// Bluetooth headsets sometimes open but deliver no audio at all (seen 2026-10-19 with Sony
    /// WH-CH720N right after another dictation: recordings of 0 s, no waveform). Called a few
    /// times a second while recording: when no audio has arrived for `stallTimeout`, the input
    /// is reopened (twice at most per recording); audio already recorded is kept.
    func restartIfStalled() {
        guard isRecording, restarts < 2 else { return }
        let silentFor = lock.withLock { Date().timeIntervalSince(lastBufferAt ?? openedAt) }
        guard silentFor > Self.stallTimeout else { return }
        restarts += 1
        Log.error(String(format: "Microphone: no audio for %.1fs — reopening the input (%d)", silentFor, restarts))
        stopEngine()
        do {
            try openInput()
        } catch {
            Log.error("Microphone: reopening failed: \(error.localizedDescription)")
        }
    }

    static let stallTimeout: TimeInterval = 0.8
    private var restarts = 0
    private var openedAt = Date()
    private var lastBufferAt: Date?

    private func openInput() throws {
        // Open the device on its own thread and wait a bounded time. If it hangs, that thread is
        // abandoned (its engine is stopped if it ever finishes) and the app stays responsive.
        let attempt = StartAttempt()
        let thread = Thread { [weak self] in
            guard let self else { attempt.finish(.failure(AudioRecorderError.noInputDevice)); return }
            let began = Date()
            // Never open a new input while the previous one is still closing on stopQueue: two
            // engines starting and stopping on the same device at once is what CoreAudio's IO
            // thread tripped over (crash 2026-10-20 01:48). Waiting here is off the main thread
            // and bounded by startTimeout.
            Self.stopQueue.sync {}
            let result = Result { try self.openEngine() }
            let took = Date().timeIntervalSince(began)
            if took > 1 { Log.info(String(format: "Microphone: opening the input took %.1fs", took)) }
            attempt.finish(result)
        }
        thread.name = "Mowa microphone start"
        thread.qualityOfService = .userInteractive
        thread.start()

        guard let result = attempt.wait(timeout: Self.startTimeout) else {
            Log.error("Microphone: opening the input didn't finish in \(Int(Self.startTimeout))s — recording cancelled")
            throw AudioRecorderError.startTimedOut
        }
        let opened = try result.get()
        engine = opened.engine
        capture = opened.capture
        converter = opened.converter
        lock.withLock { openedAt = Date() }
        isRecording = true
    }

    private struct OpenedEngine {
        var engine: AVAudioEngine?
        var capture: CaptureInput?
        var converter: AVAudioConverter?

        /// Closes an input nobody uses (a start that finished after the caller gave up).
        func close() {
            if let engine {
                engine.stop()
                engine.inputNode.removeTap(onBus: 0)
                AudioRecorder.retire(engine)
            }
            capture?.stop()
        }
    }

    /// The result of one start, handed from the opening thread to the waiting caller.
    private final class StartAttempt: @unchecked Sendable {
        private let lock = NSLock()
        private let done = DispatchSemaphore(value: 0)
        private var result: Result<OpenedEngine, Error>?
        private var abandoned = false

        /// Opening thread: deliver the result, or stop the engine if the caller already gave up.
        func finish(_ value: Result<OpenedEngine, Error>) {
            let late = lock.withLock { () -> Bool in
                if abandoned { return true }
                result = value
                return false
            }
            if late {
                if case .success(let opened) = value {
                    opened.close()
                    Log.info("Microphone: a late input start finished — stopped it")
                }
                return
            }
            done.signal()
        }

        /// Caller: the result, or nil when it didn't arrive in time (the attempt is then abandoned).
        func wait(timeout: TimeInterval) -> Result<OpenedEngine, Error>? {
            _ = done.wait(timeout: .now() + timeout)
            return lock.withLock {
                if let result { return result }
                abandoned = true
                return nil
            }
        }
    }

    /// Builds and starts an engine on the microphone (runs on the start thread, never the main one).
    private func openEngine() throws -> OpenedEngine {
        // A microphone picked for headphones (Settings) that isn't the macOS input: recorded with
        // AVCaptureSession, which opens a device by its UID, without changing the system setting.
        // AVAudioEngine only ever records the macOS input: switching its input unit to another
        // device (kAudioOutputUnitProperty_CurrentDevice) crashed Mowa in CoreAudio three times
        // on 2026-10-21 (freed listener at 01:25 and 01:52, heap corruption at 02:20 when switching
        // back) and the picked mic gave no dictation.
        if let mic = AudioDevices.currentMicrophone(), mic.id != AudioDevices.systemMicrophone()?.id {
            if let capture = CaptureInput(uid: mic.uid) {
                return openCapture(capture)
            }
            Log.error("Microphone: couldn't open \(mic.name) — using the macOS input")
        }
        let engine = AVAudioEngine()
        do {
            return try startEngine(engine)
        } catch {
            // Freeing an engine right away while CoreAudio still notifies it crashed Mowa (see `retire`).
            Self.retire(engine)
            throw error
        }
    }

    private func openCapture(_ capture: CaptureInput) -> OpenedEngine {
        let myGeneration = lock.withLock { generation }
        let target = targetFormat
        // The capture queue delivers buffers one at a time, so this needs no lock. A new converter
        // only when the device's format changes (a mic can switch sample rate).
        var current: (format: AVAudioFormat, converter: AVAudioConverter)?
        capture.onBuffer = { [weak self] buffer in
            guard let self, self.lock.withLock({ self.generation == myGeneration }) else { return }
            if current == nil || current!.format != buffer.format {
                guard let converter = AVAudioConverter(from: buffer.format, to: target) else { return }
                current = (buffer.format, converter)
            }
            self.process(buffer, inputFormat: buffer.format, converter: current!.converter)
        }
        capture.start()
        return OpenedEngine(engine: nil, capture: capture, converter: nil)
    }

    private func startEngine(_ engine: AVAudioEngine) throws -> OpenedEngine {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { throw AudioRecorderError.noInputDevice }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterUnavailable
        }

        let myGeneration = lock.withLock { generation }
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, self.lock.withLock({ self.generation == myGeneration }) else { return }
            self.process(buffer, inputFormat: inputFormat, converter: converter)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        return OpenedEngine(engine: engine, converter: converter)
    }

    /// Stops recording and returns the captured audio.
    /// `keepOpenFor`: the input stays open that long after the audio is taken (nothing more is
    /// recorded). With a Bluetooth headset's mic, the stop sound plays while the headset is still in
    /// call mode; closing the mic switches it to music mode, and a sound playing then was cut off.
    func stop(keepOpenFor: TimeInterval = 0) -> (samples: [Float], peakLevel: Float) {
        stopEngineInBackground(keepOpenFor: keepOpenFor)
        return lock.withLock { (samples, peak) }
    }

    func cancel(keepOpenFor: TimeInterval = 0) {
        stopEngineInBackground(keepOpenFor: keepOpenFor)
        lock.withLock { samples.removeAll() }
    }

    /// The audio recorded so far (for transcribing a long dictation while it is still going on).
    func snapshot() -> [Float] {
        lock.withLock { samples }
    }

    var duration: Double {
        lock.withLock { Double(samples.count) / Self.sampleRate }
    }

    private func stopEngine() {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            Self.retire(engine)
        }
        if let capture {
            lock.withLock { generation += 1 }
            Self.stopQueue.async { capture.stop() }
        }
        engine = nil
        capture = nil
        converter = nil
        isRecording = false
    }

    /// On key release: stopping a Bluetooth headset's input (call mode → music mode) can block for
    /// a few hundred ms, which froze the overlay right as the waveform rolled into the spinner.
    /// The engine is stopped on a background queue; buffers it still delivers are ignored.
    private func stopEngineInBackground(keepOpenFor: TimeInterval = 0) {
        let old = engine
        let oldCapture = capture
        lock.withLock { generation += 1 }
        engine = nil
        capture = nil
        converter = nil
        isRecording = false
        // Waiting on stopQueue (not asyncAfter) keeps the order: a new recording waits for this
        // input to close before it opens one (see openInput).
        let wait = min(max(keepOpenFor, 0), 1.5)
        if let oldCapture {
            Self.stopQueue.async {
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                oldCapture.stop()
            }
        }
        guard let old else { return }
        Self.stopQueue.async {
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let began = Date()
            // Stop first, then remove the tap: removing the tap while the input was still running
            // freed the tap's callback under CoreAudio's IO thread, which then jumped to a null
            // pointer (crash 2026-10-20 01:48, EXC_BAD_ACCESS in HALC_ProxyIOContext::IOWorkLoop).
            old.stop()
            old.inputNode.removeTap(onBus: 0)
            let took = Date().timeIntervalSince(began)
            if took > 0.2 { Log.info(String(format: "Microphone: closing the input took %.2fs", took)) }
            Self.retire(old)
        }
    }

    private static let stopQueue = DispatchQueue(label: "mowa.microphone-stop", qos: .userInitiated)

    /// Engines that were let go are kept alive for a while before they are freed. AVAudioEngine's
    /// input unit registers CoreAudio property listeners (device and format changes); when one
    /// fired after the engine was freed, Mowa crashed in AVAudioIOUnit::IOUnitPropertyListener
    /// (EXC_BAD_ACCESS, 2026-10-21 01:25 and 01:52, MacBook mic picked while AirPods were on —
    /// the headset switching modes sends those notifications seconds later).
    private static let retiredLock = NSLock()
    nonisolated(unsafe) private static var retired: [ObjectIdentifier: AVAudioEngine] = [:]
    static let retireDelay: TimeInterval = 15

    static func retire(_ engine: AVAudioEngine) {
        let key = ObjectIdentifier(engine)
        retiredLock.withLock { retired[key] = engine }
        stopQueue.asyncAfter(deadline: .now() + retireDelay) {
            retiredLock.withLock { _ = retired.removeValue(forKey: key) }
        }
    }
    /// Runs `block` once every input that is being closed has closed (off the main thread).
    /// The stop sound waits for this: starting output on the built-in speakers while the built-in
    /// mic is still shutting down made CoreAudio stall right at the waveform → spinner morph.
    static func afterInputClosed(_ block: @escaping () -> Void) { stopQueue.async(execute: block) }
    /// Bumped whenever an engine is let go, so a stopping engine's late buffers are dropped.
    private var generation = 0

    private func process(_ buffer: AVAudioPCMBuffer, inputFormat: AVAudioFormat, converter: AVAudioConverter) {
        // Level from the first channel.
        if let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 {
            let level = LevelMeter.level(rms: LevelMeter.rms(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))))
            lock.withLock {
                peak = max(peak, level)
                lastBufferAt = Date()
            }
            onLevel?(level)
        }

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, let data = out.floatChannelData?[0], out.frameLength > 0 else {
            if let error { Log.error("Audio conversion failed: \(error.localizedDescription)") }
            return
        }
        let chunk = UnsafeBufferPointer(start: data, count: Int(out.frameLength))
        lock.withLock { samples.append(contentsOf: chunk) }
    }
}

/// Records one microphone by its CoreAudio UID with AVCaptureSession (see `openEngine`).
/// Buffers arrive as Float32 mono at the device's own rate on `queue`.
final class CaptureInput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "mowa.microphone-capture", qos: .userInteractive)
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    init?(uid: String) {
        guard let device = AVCaptureDevice(uniqueID: uid), device.hasMediaType(.audio),
              let input = try? AVCaptureDeviceInput(device: device) else { return nil }
        super.init()
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(output) else { return nil }
        session.addInput(input)
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true,
            AVNumberOfChannelsKey: 1,
        ]
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)
    }

    /// Blocks until the device runs (called on the start thread, bounded by startTimeout).
    func start() { session.startRunning() }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let buffer = Self.pcmBuffer(sampleBuffer) else { return }
        onBuffer?(buffer)
    }

    private static func pcmBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames),
                                                                  into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    /// kAudioDeviceTransportType… (built-in, Bluetooth, USB, virtual…).
    var transport: UInt32 = 0

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    var isBluetooth: Bool { transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE }
    /// Software devices (Zoom, Teams, BlackHole, aggregates): not a real microphone.
    var isVirtual: Bool {
        transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate || transport == kAudioDeviceTransportTypeUnknown
    }
}

/// CoreAudio input-device enumeration.
enum AudioDevices {
    /// Sample rate of the current default output. A Bluetooth headset runs at 8–16 kHz while its
    /// microphone is open (call mode) and goes back to 44.1/48 kHz (music mode) afterwards.
    static func defaultOutputSampleRate() -> Double? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        address.mSelector = kAudioDevicePropertyNominalSampleRate
        var rate = Float64(0)
        size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id), let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name, transport: uint32Property(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    /// The input selected in macOS (System Settings → Sound → Input).
    static func systemMicrophone() -> AudioInputDevice? {
        let list = inputDevices()
        let defaultID = uint32Property(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
        return list.first { $0.id == defaultID } ?? list.first
    }

    /// Settings → "Microphone with Bluetooth headphones" (UID; empty = same as macOS).
    static let headphonesMicrophoneKey = "headphonesMicrophoneUID"

    /// The microphone dictation uses: the one picked for headphones while headphones (a Bluetooth
    /// device) are connected and the picked mic is there, otherwise the input selected in macOS.
    static func currentMicrophone() -> AudioInputDevice? {
        let list = inputDevices()
        let system = systemMicrophone()
        if let uid = UserDefaults.standard.string(forKey: headphonesMicrophoneKey), !uid.isEmpty,
           list.contains(where: \.isBluetooth) || system?.isBluetooth == true,
           let picked = list.first(where: { $0.uid == uid && !$0.isBluetooth }) {
            return picked
        }
        return system
    }

    /// Choices for Settings → "Microphone with Bluetooth headphones": the Mac's own microphone, or — on a Mac
    /// without one — the other real microphones. Never the headphones' own (Bluetooth) mic, nor
    /// Zoom/Teams/aggregate devices.
    static func microphonesBesidesHeadphones() -> [AudioInputDevice] {
        let real = inputDevices().filter { !$0.isVirtual && !$0.isBluetooth }
        let builtIn = real.filter(\.isBuiltIn)
        return builtIn.isEmpty ? real : builtIn
    }

    private static func uint32Property(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value?.takeRetainedValue() else { return nil }
        return cf as String
    }
}
