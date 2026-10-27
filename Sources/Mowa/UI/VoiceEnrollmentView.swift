import Combine
import MowaCore
import SwiftUI

/// "Learn my voice": the user reads a short text aloud, Mowa saves a voiceprint and turns on
/// "Ignore other people's voices". Up to two recordings per language, made with two different
/// microphones (for example the Mac's and headphones; the user switches between them): a
/// different microphone changes how a voice sounds to the model. Onboarding (`compact`) records one; Settings → My voice manages them all.
struct VoiceEnrollmentView: View {
    @EnvironmentObject var settings: AppSettings
    @StateObject private var session = VoiceEnrollmentSession()
    @State private var readingLanguage: DictationLanguage?
    @State private var profile = VoicePrint.load() ?? VoiceProfile()
    /// The microphone recordings are made with: the input selected in macOS (what dictation uses).
    @State private var microphone: AudioInputDevice?
    var textHeight: CGFloat = 150
    /// Onboarding: one recording; the rest is in Settings.
    var compact = false
    /// Notices microphones being connected or disconnected while the view is open.
    private let devicePoll = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    static let readingKey = "Mowa is learning how my voice sounds, so I'm reading this at my usual pace. On Saturday morning it's nice to walk along the river, buy fresh bread and a jar of honey, and then call an old friend. We're meeting at half past four by the green bridge next to the market. If it rains, there's always the little café, a cup of hot tea and a long talk about books, travel and work."

    /// Varied, everyday sentences, ~30 s at a normal pace, in the chosen language (read from that
    /// language's .lproj, whatever the UI language). Gender-neutral wording (Polish and Russian
    /// past tenses would otherwise assume the reader's gender).
    static func readingText(_ language: DictationLanguage) -> String {
        let folder = language == .portuguese ? "pt-BR" : language.rawValue
        guard let path = Bundle.main.path(forResource: folder, ofType: "lproj"), let bundle = Bundle(path: path) else {
            return L(readingKey)
        }
        return bundle.localizedString(forKey: readingKey, value: readingKey, table: nil)
    }

    /// The user's main languages first, the one they're most likely to speak natively first (the
    /// Mac's preferred-language order); in Settings also Mowa's other languages after them.
    private var languages: [DictationLanguage] {
        let main = settings.enabledLanguages
        var ordered: [DictationLanguage] = []
        for code in Locale.preferredLanguages {
            if let lang = DictationLanguage(whisperCode: code), main.contains(lang), !ordered.contains(lang) { ordered.append(lang) }
        }
        ordered += DictationLanguage.allCases.filter { main.contains($0) && !ordered.contains($0) }
        if ordered.isEmpty { ordered = [.english] }
        if !compact { ordered += DictationLanguage.allCases.filter { !ordered.contains($0) } }
        return ordered
    }

    private var busy: Bool { session.phase == .recording || session.phase == .processing }

    private func refreshDevices() {
        microphone = AudioDevices.currentMicrophone()
    }

    private func pickerLabel(_ lang: DictationLanguage) -> String {
        let done = VoiceSlot.allCases.filter { profile.sample(language: lang, slot: $0) != nil }.count
        return done == 0 ? lang.nativeName : "\(lang.nativeName)  (\(done)/\(VoiceSlot.allCases.count))"
    }

    private func record(_ slot: VoiceSlot, _ language: DictationLanguage) {
        guard let microphone else { return }
        session.start(device: microphone, language: language, slot: slot)
    }

    var body: some View {
        let language = readingLanguage ?? languages[0]
        VStack(alignment: .leading, spacing: 12) {
            if !compact {
                Text(L("You can record each language twice. For the best result, use two different microphones (for example, the Mac's and your headphones)."))
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if languages.count > 1 {
                HStack(spacing: 8) {
                    Text(L("Read in"))
                    Picker(L("Read in"), selection: Binding(get: { language }, set: { readingLanguage = $0 })) {
                        ForEach(languages) { Text(pickerLabel($0)).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(busy)
                    Spacer(minLength: 0)
                }
                if compact {
                    Text(L("Pick the language you speak most naturally — your voiceprint works in all your languages."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ScrollView {
                Text(Self.readingText(language))
                    .font(.title3)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: textHeight)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            if !compact {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(VoiceSlot.allCases) { slot in slotRow(slot, language) }
                }
            }

            statusRow(language)

            Group {
                if case .failed(let message) = session.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else if !Permissions.microphoneGranted {
                    Text(L("Allow the microphone first."))
                } else if microphone == nil {
                    Text(L("No microphone found."))
                } else if session.phase == .recording {
                    Text(L("Read at your normal pace and volume, then click Done reading."))
                } else if session.phase == .done, compact {
                    Text(L("You can add a second microphone and other languages later in Settings → My voice."))
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if !compact, profile.sample(language: nil, slot: .first) != nil {
                HStack {
                    Text(L("Earlier recording, made before recordings had a language"))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    deleteButton(nil, .first)
                }
            }
        }
        .onAppear(perform: refreshDevices)
        .onReceive(devicePoll) { _ in if !busy { refreshDevices() } }
        .onChange(of: session.phase) { phase in
            if phase == .done { profile = VoicePrint.load() ?? VoiceProfile() }
        }
        .onDisappear { session.cancel() }
    }

    @ViewBuilder
    private func slotRow(_ slot: VoiceSlot, _ language: DictationLanguage) -> some View {
        let sample = profile.sample(language: language, slot: slot)
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: sample != nil ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(sample != nil ? Color.green : Color.secondary)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text(slot == .first ? L("Recording 1") : L("Recording 2")).fontWeight(.medium)
                if let sample, let name = sample.micName {
                    Text(LF("Recorded with: %@", name)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if sample != nil { deleteButton(language, slot) }
            Button(sample != nil ? L("Record again") : L("Record")) { record(slot, language) }
                .disabled(busy || microphone == nil || !Permissions.microphoneGranted)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private func deleteButton(_ language: DictationLanguage?, _ slot: VoiceSlot) -> some View {
        Button {
            let left = VoicePrint.remove(language: language, slot: slot)
            profile = VoicePrint.load() ?? VoiceProfile()
            if !left {
                settings.voiceFilter = false
                settings.hasVoiceprint = false
            }
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help(L("Delete this recording"))
        .disabled(busy)
    }

    @ViewBuilder
    private func statusRow(_ language: DictationLanguage) -> some View {
        HStack(spacing: 12) {
            switch session.phase {
            case .idle, .failed:
                if compact {
                    Button(profile.sample(language: language, slot: .first) != nil ? L("Record again") : L("Start reading")) {
                        record(.first, language)
                    }
                    .controlSize(.large)
                    .disabled(!Permissions.microphoneGranted || microphone == nil)
                }
            case .recording:
                Button(L("Done reading")) { session.finish() }
                    .controlSize(.large)
                LevelBar(level: session.level)
                Text(String(format: "0:%02d", min(session.seconds, 99)))
                    .monospacedDigit().foregroundStyle(.secondary)
                if let name = session.deviceName {
                    Text(LF("Recording with: %@", name)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            case .processing:
                ProgressView().controlSize(.small)
                Text(L("Learning your voice…")).foregroundStyle(.secondary)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(L("Done — Mowa knows your voice now."))
                if compact {
                    Button(L("Record again")) { record(.first, language) }
                        .disabled(microphone == nil)
                }
            }
            Spacer()
        }
        .frame(minHeight: 28)
    }
}

/// Records the enrollment reading and turns it into a voiceprint.
@MainActor
final class VoiceEnrollmentSession: ObservableObject {
    enum Phase: Equatable { case idle, recording, processing, done, failed(String) }

    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    @Published var seconds = 0
    /// The microphone being recorded (shown while reading).
    @Published var deviceName: String?
    private var language: DictationLanguage?
    private var slot: VoiceSlot = .first
    private var device: AudioInputDevice?
    private let recorder = AudioRecorder()
    private var timer: Timer?
    private var started = Date()
    /// Stops by itself after this long, in case the user forgets to click Done.
    private let maxSeconds = 90

    func start(device: AudioInputDevice, language: DictationLanguage, slot: VoiceSlot) {
        self.language = language
        self.slot = slot
        self.device = device
        deviceName = device.name
        recorder.onLevel = { [weak self] value in
            Task { @MainActor in self?.level = value }
        }
        do {
            try recorder.start()
        } catch {
            phase = .failed(LF("Could not start recording: %@", error.localizedDescription))
            return
        }
        started = Date()
        seconds = 0
        phase = .recording
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.phase == .recording else { return }
                self.seconds = Int(Date().timeIntervalSince(self.started))
                if self.seconds >= self.maxSeconds { self.finish() }
            }
        }
    }

    func finish() {
        guard phase == .recording else { return }
        timer?.invalidate()
        timer = nil
        let (samples, _) = recorder.stop()
        level = 0
        phase = .processing
        let language = language
        let slot = slot
        let micName = device?.name
        let micUID = device?.uid
        Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<VoiceSample, Error> in
                do { return .success(try VoicePrint.enroll(samples: samples, language: language, slot: slot, micName: micName, micUID: micUID).sample) } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let sample):
                do {
                    try VoicePrint.add(sample)
                    let settings = AppSettings.shared
                    settings.hasVoiceprint = true
                    settings.voiceFilter = true
                    phase = .done
                } catch {
                    phase = .failed(error.localizedDescription)
                }
            case .failure(let error):
                Log.info("Voice: enrollment failed: \(error.localizedDescription)")
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        if phase == .recording {
            recorder.cancel()
            phase = .idle
        }
    }
}

/// Small "Experimental" tag shown next to the voice filter's titles.
struct ExperimentalBadge: View {
    var body: some View {
        Text(L("Experimental"))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(.orange)
            .background(Capsule().fill(Color.orange.opacity(0.15)))
    }
}

/// Simple input-level meter for the enrollment recording.
private struct LevelBar: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule().fill(MowaColors.accent)
                    .frame(width: geo.size.width * CGFloat(max(0.03, min(1, (level - 0.2) / 0.7))))
            }
        }
        .frame(width: 120, height: 6)
        .animation(.linear(duration: 0.08), value: level)
    }
}
