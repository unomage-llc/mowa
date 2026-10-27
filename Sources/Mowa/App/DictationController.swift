import AppKit
import CoreAudio
import MowaCore

/// Observable state for the menu bar icon and the overlay.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording(handsFree: Bool)
        case processing(String)
    }

    @Published var phase: Phase = .idle {
        didSet {
            lastActivity = Date()
            // Set when processing starts; kept through idle so the spinner stays a spinner while
            // the pill shrinks away; cleared when the next recording starts.
            switch phase {
            case .processing: if processingSince == nil { processingSince = Date() }
            case .recording: processingSince = nil
            case .idle: break
            }
            if case .recording(let handsFree) = phase { lastRecordingHandsFree = handsFree }
        }
    }
    /// The pill is shown (grown in) — false makes it shrink into a point and fade (see OverlayPill).
    @Published var pillShown = false
    /// When the key was released (processing began) — the overlay morphs the waveform into the
    /// spinner from this moment.
    private(set) var processingSince: Date?
    /// Whether the last recording was hands-free (its waveform is narrower).
    private(set) var lastRecordingHandsFree = false
    /// When Mowa last started or finished a dictation (used to time background updates).
    private(set) var lastActivity: Date?
    @Published var level: Float = 0
    @Published var levels: [Float] = Array(repeating: 0, count: 24)
    @Published var speechModelReady = false
    @Published var loadingMessage: String?
    @Published var lastError: String?
    @Published var lastResult: HistoryItem?

    /// The overlay waveform: one bar per `sampleInterval`, oldest first, each with an evenly spaced
    /// timestamp. The overlay places bars by time on every display frame, so they glide right → left
    /// at a constant speed.
    @Published private(set) var levelSamples: [LevelSample] = []
    private var nextSampleID = 0
    private var pendingPeak: Float = 0
    private var lastSampleAt = Date.distantPast
    nonisolated static let sampleInterval: TimeInterval = 0.07
    private static let maxSamples = 40

    /// How loud this mic's speech usually is (dB, learnt per mic) — the overlay draws every mic alike.
    @Published private(set) var micSpeechDB: Float?
    private var recordingLevels: [Float] = []
    private var recordingMic: String?

    func pushLevel(_ value: Float) {
        if recordingLevels.count < 4000 { recordingLevels.append(value) }
        level = value
        levels.removeFirst()
        levels.append(value)
        // Audio buffers arrive ~45×/s; one bar per 70 ms (the loudest level in it) keeps the
        // flow calm enough to read.
        pendingPeak = max(pendingPeak, value)
        let now = Date()
        guard now.timeIntervalSince(lastSampleAt) >= Self.sampleInterval else { return }
        // Bars are stamped on an exact 70 ms grid so the spacing never changes. Buffers arrive
        // with jitter, and now and then late (main thread busy): then every missed grid slot
        // still gets a bar (same level), so the flow never shows a gap or a jump.
        if now.timeIntervalSince(lastSampleAt) > 1 { lastSampleAt = now.addingTimeInterval(-Self.sampleInterval) }
        while now.timeIntervalSince(lastSampleAt) >= Self.sampleInterval {
            lastSampleAt = lastSampleAt.addingTimeInterval(Self.sampleInterval)
            levelSamples.append(LevelSample(id: nextSampleID, value: pendingPeak, time: lastSampleAt))
            nextSampleID += 1
        }
        pendingPeak = 0
        if levelSamples.count > Self.maxSamples { levelSamples.removeFirst(levelSamples.count - Self.maxSamples) }
    }

    /// Learns the last recording's speech loudness for its mic, then loads the current mic's.
    private func calibrateMic() {
        var known = (UserDefaults.standard.dictionary(forKey: "micSpeechDB") as? [String: Double]) ?? [:]
        if let mic = recordingMic,
           let updated = LevelMeter.updatedSpeechLevel(old: known[mic].map(Float.init),
                                                       recording: LevelMeter.speechLevelDB(recordingLevels)) {
            known[mic] = Double(updated)
            UserDefaults.standard.set(known, forKey: "micSpeechDB")
        }
        recordingLevels = []
        recordingMic = AudioDevices.currentMicrophone()?.name
        micSpeechDB = recordingMic.flatMap { known[$0] }.map(Float.init)
    }

    func resetLevels() {
        calibrateMic()
        levels = Array(repeating: 0, count: levels.count)
        // Start with a flat line of quiet bars so the pill isn't empty for the first moment.
        let now = Date()
        levelSamples = (0..<Self.maxSamples).map {
            LevelSample(id: nextSampleID + $0, value: 0,
                        time: now.addingTimeInterval(-Double(Self.maxSamples - $0) * Self.sampleInterval))
        }
        nextSampleID += Self.maxSamples
        pendingPeak = 0
        lastSampleAt = now.addingTimeInterval(-Self.sampleInterval)
    }
}

struct LevelSample: Identifiable, Equatable {
    let id: Int
    let value: Float
    let time: Date
}

/// The dictation pipeline: hotkey → record → transcribe → clean up → paste.
@MainActor
final class DictationController {
    let state = AppState()
    let settings = AppSettings.shared
    let recorder = AudioRecorder()
    let transcriber = Transcriber()
    let cleanup = CleanupService()
    private(set) var hotkey: HotkeyMonitor!
    private var overlay: OverlayController!

    private var recordingStartedAt = Date()
    private var mode: DictationMode = .dictation
    private var startContext: FocusContext?
    private var pendingTapWork: DispatchWorkItem?
    private var awaitingSecondTap = false
    private var processingTask: Task<Void, Never>?
    /// While push-to-talk records: checks the key is really still held (see HotkeyMonitor.reconcile).
    private var keyWatchTimer: Timer?
    /// Gives up on a dictation whose processing never finishes, so Mowa can't stay stuck.
    private var processingWatchdog: DispatchWorkItem?
    private let processingTimeout: TimeInterval = 60
    private var speechLoadTask: Task<Void, Never>?
    /// Names/terms read from the screen while the user talks (spelling hints).
    private var screenTermsTask: Task<[String], Never>?

    /// Short press shorter than this is a "tap" (part of a double tap) rather than push-to-talk.
    private let tapThreshold: TimeInterval = 0.3
    /// Recording continues this long after the key is released (the end of the last word).
    private let releaseTail: TimeInterval = 0.15
    /// Loudest 100 ms level (0…1 over −60…0 dBFS) a short recording needs to count as someone speaking
    /// into the mic: 0.25 ≈ −45 dBFS.
    static let nearVoicePeak: Float = 0.25
    /// Seconds at the start of the recording where Mowa's start sound plays (0 on Bluetooth: none).
    private var startSoundMute: TimeInterval = 0
    /// The current/last recording used a Bluetooth headset microphone (sounds wait for its mode switch).
    private var recordingOnBluetooth = false
    private var tailWork: DispatchWorkItem?
    private var tailToken: UUID?
    /// Long dictations: Whisper works on finished pieces while the user is still talking.
    private var streaming: StreamingTranscription?
    private var streamTimer: Timer?
    private let doubleTapWindow: TimeInterval = 0.45

    init() {
        overlay = OverlayController(state: state, onStop: { [weak self] in self?.finishRecording() },
                                    onCancel: { [weak self] in self?.cancel() })
        hotkey = HotkeyMonitor(choice: settings.hotkey, shortcut: settings.customShortcut)
        hotkey.onPress = { [weak self] press in self?.keyPressed(press) }
        hotkey.onRelease = { [weak self] held in self?.keyReleased(held: held) }
        hotkey.onOtherKey = { [weak self] in self?.otherKeyWhileHeld() }
        hotkey.onEscape = { [weak self] in self?.escapePressed() }

        recorder.onLevel = { [weak self] level in
            Task { @MainActor in self?.state.pushLevel(level) }
        }
    }

    func start() {
        FnKeyUsage.apply(fnIsDictationKey: settings.hotkey == .fn)
        hotkey.start()
        loadModels()
        if settings.voiceFilter { Task.detached(priority: .utility) { SpeakerEmbedder.shared.prewarm() } }
    }

    // MARK: Models

    /// A download finished: load it if it's one of the models in use *now* (the user may have
    /// selected it while it was still downloading, or switched away meanwhile).
    func modelDownloaded(_ id: String) {
        if [settings.speechModelID, settings.cleanupModelID].contains(id) { loadModels() }
        // A Whisper model downloaded while Parakeet is in use becomes its safety net.
        else if ModelCatalog.isParakeet(settings.speechModelID), !ModelCatalog.isParakeet(id),
                ModelCatalog.speechModel(id: id) != nil { loadModels() }
    }

    func loadModels() {
        // Loads run one at a time: WhisperKit/Core ML loading can't be cancelled, and two
        // loads compiling the same model at once fail ("Error in reading the MIL network").
        // A newer call cancels the older one, waits for it to finish, then takes over.
        let previous = speechLoadTask
        previous?.cancel()
        let speechID = settings.speechModelID
        speechLoadTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            if Transcriber.isDownloaded(speechID) {
                self.state.speechModelReady = self.transcriber.loadedModelID == speechID && self.transcriber.isLoaded
                self.state.loadingMessage = L("Loading speech model…")
                // A model's first load on this Mac compiles it for the Neural Engine
                // (full precision: 1–2 minutes). Say so instead of looking stuck.
                let slowHint = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard !Task.isCancelled, let self, self.state.loadingMessage != nil else { return }
                    self.state.loadingMessage = L("Preparing the speech model for this Mac — the first time can take a minute or two…")
                }
                do {
                    try await self.transcriber.load(modelID: speechID)
                    self.state.speechModelReady = true
                } catch {
                    self.state.speechModelReady = false
                    self.state.lastError = LF("Could not load the speech model: %@", error.localizedDescription)
                    Log.error("Speech model load failed: \(error)")
                }
                slowHint.cancel()
                self.state.loadingMessage = nil
            } else {
                self.state.speechModelReady = false
            }
            guard !Task.isCancelled else { return }
            await self.cleanup.reloadForSettingsChange()
            await self.cleanup.prepareModel()
        }
    }

    // MARK: Hotkey handling

    private var isRecording: Bool {
        if case .recording = state.phase { return true }
        return false
    }

    private var isHandsFree: Bool {
        if case .recording(let handsFree) = state.phase { return handsFree }
        return false
    }

    private func keyPressed(_ press: HotkeyMonitor.Press) {
        if awaitingSecondTap {
            // Second tap of a double tap: keep recording, hands-free.
            awaitingSecondTap = false
            pendingTapWork?.cancel()
            if case .recording = state.phase {
                state.phase = .recording(handsFree: true)
                overlay.update()
            }
            return
        }
        switch state.phase {
        case .idle:
            beginRecording(handsFree: false)
        case .recording(let handsFree):
            if handsFree { finishRecording() }
        case .processing:
            break
        }
    }

    private func keyReleased(held: TimeInterval) {
        guard case .recording(let handsFree) = state.phase, !handsFree else { return }
        if held < tapThreshold {
            guard settings.doubleTapHandsFree else { cancel(); return }
            // Possibly the first half of a double tap: wait briefly for the second.
            awaitingSecondTap = true
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.awaitingSecondTap else { return }
                self.awaitingSecondTap = false
                self.cancel(silently: true) // a lone short tap: ignore
            }
            pendingTapWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleTapWindow, execute: work)
        } else {
            finishRecording()
        }
    }

    private func otherKeyWhileHeld() {
        // The modifier is being used for a shortcut (e.g. ⌥+letter), not dictation.
        if isRecording && !isHandsFree && Date().timeIntervalSince(recordingStartedAt) < 1.5 {
            cancel(silently: true)
        }
    }

    private func escapePressed() {
        switch state.phase {
        case .recording, .processing: cancel()
        case .idle: break
        }
    }

    // MARK: Recording

    /// Menu bar "Start dictation" / overlay toggles.
    func toggleHandsFree() {
        switch state.phase {
        case .idle: beginRecording(handsFree: true)
        case .recording: finishRecording()
        case .processing: break
        }
    }

    private func beginRecording(handsFree: Bool) {
        state.lastError = nil
        guard Permissions.microphoneGranted else {
            fail(L("Mowa needs microphone access. Open Settings → Permissions."))
            return
        }
        guard state.speechModelReady else {
            fail(Transcriber.isDownloaded(settings.speechModelID)
                 ? (state.loadingMessage ?? L("The speech model is still loading — try again in a moment."))
                 : L("Download a speech model first (Settings → Models)."))
            return
        }
        // Start sound: never while a Bluetooth headset is the input. Played after the mic opened,
        // the headset's echo suppression muted the mic for ~1 s after the first words; played
        // right before opening it, the input often delivered no audio at all (0 s recordings,
        // 2026-10-19). The headset's own switch to call mode is audible anyway. With other mics
        // the sound plays before the mic opens, so it isn't recorded.
        let micIsBluetooth = AudioDevices.currentMicrophone().map {
            $0.transport == kAudioDeviceTransportTypeBluetooth || $0.transport == kAudioDeviceTransportTypeBluetoothLE
        } ?? false
        recordingOnBluetooth = micIsBluetooth
        // Muted out of the recording afterwards (completeRecording): the built-in mic still caught
        // its tail and Whisper typed it as "Thank you." / "- Yeah." (Drew 2026-10-21).
        // Also covers the moment before other audio is turned down (it drops right after the sound).
        startSoundMute = micIsBluetooth ? 0 : max(Feedback.startSoundSeconds, 0.15) + 0.05   // sound / 0.15 s fade
        if !micIsBluetooth { Feedback.start() }
        do {
            try recorder.start()
        } catch {
            fail(LF("Could not start recording: %@", error.localizedDescription))
            return
        }
        mode = .dictation   // commands are recognised from what is said over selected text
        startContext = TextInserter.focusContext()
        recordingStartedAt = Date()
        screenTermsTask?.cancel()
        if settings.useScreenContext {
            let known = VocabularyStore.shared.words
            // Read the screen off the main thread while the user is still talking.
            screenTermsTask = Task.detached(priority: .utility) {
                guard let text = TextInserter.screenText() else { return [] }
                return ScreenTerms.extract(from: text, limit: 30, excluding: known)
            }
        } else {
            screenTermsTask = nil
        }
        state.resetLevels()
        state.phase = .recording(handsFree: handsFree)
        // Other audio starts going down the moment the key is pressed, in a 0.15 s fade — Mowa's start
        // sound fades out with it (Drew 2026-10-21) — so the recording doesn't get loud music at the start.
        AudioDucker.shared.duck(after: 0, fadeTime: 0.15)
        overlay.show()
        Log.info("Recording started (\(handsFree ? "hands-free" : "push-to-talk"))")
        cleanup.rewarmIfNeeded()
        startKeyWatch()
        startStreaming()
    }

    private func startKeyWatch() {
        keyWatchTimer?.invalidate()
        keyWatchTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.recorder.restartIfStalled()
                guard !self.isHandsFree, !self.awaitingSecondTap else { return }
                self.hotkey.reconcile()
            }
        }
    }

    private func startStreaming() {
        stopStreaming()
        guard StreamingTranscription.isEnabled else { return }
        streaming = StreamingTranscription(
            transcriber: transcriber, candidates: settings.candidateLanguages,
            acceptOther: settings.acceptOtherLanguages && settings.fixedLanguage == nil,
            usualLanguage: LearningStore.shared.usualLanguage(bundleID: startContext?.bundleID,
                                                              among: settings.candidateLanguages),
            vocabulary: VocabularyStore.shared.words, denoise: settings.noiseReduction,
            voice: settings.voiceFilter ? VoicePrint.load() : nil)
        streamTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording, let streaming = self.streaming else { return }
                // Nothing to do (and no copy) until a piece's worth of audio exists.
                guard self.recorder.duration >= StreamingTranscription.pieceSeconds + StreamingTranscription.searchSeconds else { return }
                streaming.feed(self.recorder.snapshot())
            }
        }
    }

    private func stopStreaming() {
        streamTimer?.invalidate()
        streamTimer = nil
        streaming = nil
    }

    private func stopKeyWatch() {
        keyWatchTimer?.invalidate()
        keyWatchTimer = nil
    }

    func finishRecording() {
        guard isRecording else { return }
        awaitingSecondTap = false
        pendingTapWork?.cancel()
        stopKeyWatch()
        let releasedAt = Date()
        // People let go of the key while still finishing the last word: keep recording a moment
        // longer (the overlay already shows processing, so nothing else can start meanwhile).
        state.phase = .processing("")
        overlay.update()
        // The stop sound goes with the spinner, right now. The volume comes back at once (not
        // faded) so the sound isn't played turned down. With a Bluetooth headset's mic it plays in
        // the headset's call mode: waiting for music mode made it ~1–2 s late (Drew 2026-10-21),
        // so completeRecording keeps the mic open until the sound has finished instead.
        AudioDucker.shared.restore(animated: false)
        // The stop sound plays right now, with the spinner; whatever the built-in mic records from
        // here on is muted in completeRecording, so the sound never reaches recognition (Drew 2026-10-21).
        Feedback.stop()
        tailWork?.cancel()
        let token = UUID()
        tailToken = token
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                // Still this recording's tail (not cancelled, nothing newer started).
                guard let self, self.tailToken == token, case .processing = self.state.phase else { return }
                self.tailWork = nil
                self.tailToken = nil
                self.completeRecording(releasedAt: releasedAt)
            }
        }
        tailWork = work
        // Built-in mic: everything after the release is muted anyway, so only a moment to flush the
        // last buffer. Bluetooth headset (no sound in the recording): the tail keeps the last word.
        DispatchQueue.main.asyncAfter(deadline: .now() + (recordingOnBluetooth ? releaseTail : 0.03), execute: work)
    }

    /// The recording is over (after the short tail): stop the microphone and process it.
    private func completeRecording(releasedAt: Date) {
        var (samples, peak) = recorder.stop(keepOpenFor: stopSoundHold)
        // Mowa's own sounds are silenced out of the recording: the start sound at the beginning (it
        // plays as the mic opens) and, on the built-in mic, everything after the key release (the stop
        // sound plays then) plus 50 ms for the input's delay.
        let sr = AudioRecorder.sampleRate
        let head = min(samples.count, Int(startSoundMute * sr))
        let tail = recordingOnBluetooth ? 0
            : min(samples.count - head, Int((Date().timeIntervalSince(releasedAt) + 0.05) * sr))
        if head > 0 || tail > 0 {
            for i in 0..<head { samples[i] = 0 }
            for i in (samples.count - tail)..<samples.count { samples[i] = 0 }
            peak = EvalRunner.peakLevel(samples)   // same mapping as AudioRecorder
        }
        let streamed = streaming
        stopStreaming()
        AudioDucker.shared.restore()   // no-op if finishRecording already restored it
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        // Developer build: keep the recording (also the discarded ones) for the eval.
        let dev = DevRecorder.begin(samples: samples, peak: peak, mode: mode, startContext: startContext)

        // Too short or silent: nothing to transcribe.
        // No voice in it (only Mowa's own sound, a key click, a knock): Whisper would invent words.
        // A short press with only room hum after the start sound (SpeechSegments.isSteadyNoise).
        // A short recording whose loudest moment is under −45 dBFS: nobody spoke into the mic — it is
        // people talking in another room or a video playing, which the quiet-speech lift would make
        // clear enough for Whisper. In Drew's 354 typed Mac-mic recordings every one like that was such
        // noise ("Gracias por ver el video", «Покажи мне его пальцы», "Mowa,"); real speech peaks at
        // 0.27+ (2026-10-21).
        if seconds < 0.3 || peak < AudioPreprocessor.silencePeak || !SpeechSegments.hasSpeech(samples)
            || (seconds < 3 && SpeechSegments.isSteadyNoise(samples))
            || (seconds < 3 && peak < Self.nearVoicePeak) {
            let v = SpeechSegments.voiced(samples)
            Log.info("Recording discarded (\(String(format: "%.2f", seconds))s, peak \(String(format: "%.2f", peak)), voiced \(v.totalMs) ms / longest \(v.longestMs) ms)")
            dev?.set(["status": "discarded"])
            reset()
            return
        }

        state.phase = .processing("")
        overlay.update()
        let mode = self.mode
        let context = startContext
        Log.info("Recording stopped (\(String(format: "%.1f", seconds))s), processing")
        processingTask = Task { [weak self] in
            await self?.process(samples: samples, seconds: seconds, peak: peak, mode: mode, context: context,
                                releasedAt: releasedAt, dev: dev, streamed: streamed)
        }
        let task = processingTask
        processingWatchdog?.cancel()
        let watchdog = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, case .processing = self.state.phase, self.processingTask == task else { return }
                Log.error("Processing took longer than \(Int(self.processingTimeout))s, gave up")
                self.cancel(silently: true)
                self.fail(L("That took too long, so Mowa stopped. Please try again."))
            }
        }
        processingWatchdog = watchdog
        DispatchQueue.main.asyncAfter(deadline: .now() + processingTimeout, execute: watchdog)
    }

    func cancel(silently: Bool = false) {
        awaitingSecondTap = false
        pendingTapWork?.cancel()
        tailWork?.cancel()
        tailWork = nil
        tailToken = nil
        let playStop = !silently && state.phase != .idle
        // A recording still open (cancelled while talking): keep it open while the stop sound plays.
        recorder.cancel(keepOpenFor: playStop && recorder.isRecording ? stopSoundHold : 0)
        stopStreaming()
        // Same as finishing: volume back at once, sound right away.
        AudioDucker.shared.restore(animated: !playStop)
        processingTask?.cancel()
        processingTask = nil
        if playStop { Feedback.stop() }
        reset()
    }

    /// How long the mic stays open after a recording so the stop sound isn't cut off by a Bluetooth
    /// headset switching back to music mode (see finishRecording); 0 with any other mic.
    private var stopSoundHold: TimeInterval {
        recordingOnBluetooth ? Feedback.stopSoundSeconds + 0.1 : 0
    }

    private func reset() {
        stopKeyWatch()
        processingWatchdog?.cancel()
        processingWatchdog = nil
        AudioDucker.shared.restore()
        state.phase = .idle
        state.level = 0
        overlay.hide()
    }

    /// Seen: Sparkle's update window came up during a dictation started in Claude, Mowa became the
    /// active app and the text was pasted into Mowa ("Insert: … into Mowa"). If the dictation
    /// started in another app and Mowa is frontmost now, reactivate that app before inserting.
    /// Dictating into Mowa's own fields (started in Mowa) is left alone.
    private static func returnFocusIfMowaStoleIt(from start: FocusContext?) async {
        let me = Bundle.main.bundleIdentifier
        guard let start, let pid = start.pid, start.bundleID != me,
              NSWorkspace.shared.frontmostApplication?.bundleIdentifier == me,
              let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        Log.info("Focus: Mowa became active during the dictation, returning to \(start.appName ?? "?")")
        app.activate()
        // Wait (up to 1 s) for the app to be frontmost again before reading its field and pasting.
        for _ in 0..<20 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(80))
    }

    private func fail(_ message: String) {
        state.lastError = message
        Feedback.error()
        overlay.flashError(message)
        Log.error(message)
    }

    // MARK: Processing

    private func process(samples: [Float], seconds: Double, peak: Float, mode: DictationMode, context: FocusContext?,
                         releasedAt: Date, dev: DevRecord?, streamed: StreamingTranscription? = nil) async {
        do {
            let screenTerms = await screenTermsTask?.value ?? []
            screenTermsTask = nil
            let environment = DictationPipeline.Environment(
                resolveContext: {
                    // Mowa's own windows (e.g. the "Check for Updates" window that opened while the user was
                    // talking) must not swallow text meant for another app: give focus back to that app.
                    await Self.returnFocusIfMowaStoleIt(from: context)
                    // Where the text goes now (the user may have switched apps while talking).
                    return TextInserter.focusContext()
                },
                copySelection: { await TextInserter.selectedText(axContext: $0) },
                keyboardLanguage: { KeyboardLanguage.current() },
                usualLanguage: LearningStore.shared.usualLanguage(bundleID: context?.bundleID,
                                                                  among: settings.candidateLanguages),
                onRecognised: { [weak self] in
                    guard let self else { return }
                    self.state.phase = .processing("")
                    self.overlay.update()
                })
            let outcome = try await DictationPipeline.run(samples: samples, peak: peak, mode: mode, screenTerms: screenTerms,
                                                          transcriber: transcriber, cleanup: cleanup, environment: environment,
                                                          streamed: streamed)
            let out: DictationPipeline.Output
            switch outcome {
            case .cancelled:
                dev?.set(["status": "cancelled"])
                return
            case .noSpeech(let transcription, let prepSeconds, let notes):
                Log.info("No speech recognised")
                dev?.set(["status": "no_speech", "whisper_text": transcription.text,
                          "whisper_language": transcription.language?.rawValue ?? "",
                          "asr_seconds": transcription.seconds, "prep_seconds": prepSeconds, "audio_notes": notes])
                reset()
                return
            case .typed(let o):
                out = o
            }
            let endContext = out.endContext
            let transcription = out.transcription
            let result = out.result
            let text = out.text

            TextInserter.insert(text, restoreClipboard: settings.restoreClipboard)
            let releaseToText = Date().timeIntervalSince(releasedAt)
            LearningStore.shared.recordLanguage(transcription.language, bundleID: endContext.bundleID)
            if let dev {
                dev.set([
                    "status": "typed",
                    "whisper_text": transcription.text,
                    "whisper_language": transcription.language?.rawValue ?? "",
                    "heard": out.heard,
                    "final_mode": out.mode.rawValue,
                    "directive_target": out.directive?.target.rawValue ?? "",
                    "command_selection": out.commandSelection ?? "",
                    "end_app": endContext.appName ?? "",
                    "end_bundle": endContext.bundleID ?? "",
                    "window_title": endContext.windowTitle ?? "",
                    "field_role": endContext.role ?? "",
                    "text_before": endContext.textBefore ?? "",
                    "text_after": endContext.textAfter ?? "",
                    "app_style": out.style.rawValue,
                    "writing_style": out.writingStyle.rawValue,
                    "screen_terms": screenTerms,
                    "cleanup_output": result.text,
                    "processed_by": result.processedBy,
                    "typed": text,
                    "prep_seconds": out.prepSeconds,
                    "asr_seconds": transcription.seconds,
                    "cleanup_seconds": result.seconds,
                    "release_to_text_seconds": releaseToText,
                    "audio_notes": out.audioNotes,
                ])
            }
            if out.mode == .dictation || dev != nil { watchForCorrections(of: text, learn: out.mode == .dictation, dev: dev) }

            let item = HistoryItem(date: Date(), appName: endContext.appName ?? context?.appName, mode: out.mode,
                                   language: transcription.language?.rawValue, raw: transcription.text,
                                   final: result.text, processedBy: result.processedBy, audioSeconds: seconds,
                                   transcribeSeconds: transcription.seconds, cleanupSeconds: result.seconds)
            HistoryStore.shared.add(item)
            LearningStore.shared.refreshSuggestions()
            state.lastResult = item
            if out.mode == .dictation {
                RatePrompt.shared.recordDictation(words: TextMetrics.wordCount(result.text)) { [weak self] in
                    self?.state.phase != .idle
                }
                SponsorPrompt.shared.recordDictation(words: TextMetrics.wordCount(result.text)) { [weak self] in
                    self?.state.phase != .idle
                }
            }
            Log.info("Dictation: \(String(format: "%.1f", seconds))s audio, lang \(transcription.language?.rawValue ?? "?"), "
                     + "asr \(String(format: "%.2f", transcription.seconds))s, cleanup \(result.processedBy) "
                     + "\(String(format: "%.2f", result.seconds))s, \(TextMetrics.wordCount(result.text)) words, "
                     + "release→text \(String(format: "%.2f", releaseToText))s")
            reset()
        } catch is CancellationError {
            dev?.set(["status": "cancelled"])
            reset()
        } catch {
            dev?.set(["status": "failed", "error": error.localizedDescription])
            reset()
            fail(LF("Dictation failed: %@", error.localizedDescription))
        }
    }

    // MARK: Learning from corrections

    /// Re-reads the text field a while after typing; words the user fixed are
    /// remembered and, after the same fix twice, added to the vocabulary.
    private func watchForCorrections(of inserted: String, learn: Bool = true, dev: DevRecord? = nil) {
        let learning = learn && settings.learnCorrections
        guard learning || dev != nil else { return }
        // Let the paste land before grabbing the field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let element = TextInserter.focusedTextElement() else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) {
                guard let self, let now = TextInserter.stringValue(element) else { return }
                let fixes = CorrectionDetector.corrections(inserted: inserted, fieldNow: now)
                // Developer build: what the field holds 25 s later (the user's own fixes), for the eval.
                dev?.set(["field_after_25s": String(now.suffix(4000)),
                          "corrections": fixes.map { ["typed": $0.typed, "corrected": $0.corrected] }])
                guard learning else { return }
                let learned = LearningStore.shared.observe(fixes)
                if let first = learned.first {
                    self.overlay.flashInfo(LF("Learned: %@ → %@", first.typed, first.corrected))
                }
            }
        }
    }

    // MARK: Menu actions

    func pasteLast() {
        guard let last = state.lastResult else { return }
        TextInserter.insert(last.final, restoreClipboard: settings.restoreClipboard)
    }

    func copyLast() {
        guard let last = state.lastResult else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(last.final, forType: .string)
    }

    func applyHotkeyChange() {
        FnKeyUsage.apply(fnIsDictationKey: settings.hotkey == .fn)
        hotkey.choice = settings.hotkey
        hotkey.shortcut = settings.customShortcut
        hotkey.start()
    }
}
