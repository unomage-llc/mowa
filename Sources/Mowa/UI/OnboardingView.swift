import AppKit
import MowaCore
import SwiftUI

struct OnboardingView: View {
    let controller: DictationController
    let onFinish: () -> Void

    enum Step: Int, CaseIterable { case welcome, languages, microphone, accessibility, models, tryIt }

    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var models = ModelManager.shared
    @State private var step: Step = .welcome
    @State private var mic = Permissions.microphoneGranted
    @State private var ax = Permissions.accessibilityGranted
    @State private var testText = ""
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ProgressDots(count: Step.allCases.count, current: step.rawValue)
                .padding(.top, 34)

            Group {
                switch step {
                case .welcome: welcome
                case .languages: languagesStep
                case .microphone: microphone
                case .accessibility: accessibility
                case .models: modelsStep
                case .tryIt: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 44)

            HStack {
                if step != .welcome {
                    Button(L("Back")) { step = Step(rawValue: step.rawValue - 1) ?? .welcome }
                }
                Spacer()
                if step == .tryIt {
                    Button(L("Done")) { onFinish() }.keyboardShortcut(.defaultAction)
                } else {
                    Button(nextTitle) { step = Step(rawValue: step.rawValue + 1) ?? .tryIt }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canContinue)
                }
            }
            .padding(24)
        }
        .frame(width: 620, height: 560)
        .onReceive(timer) { _ in
            mic = Permissions.microphoneGranted
            let nowAX = Permissions.accessibilityGranted
            if nowAX && !ax { controller.hotkey.start() }
            ax = nowAX
        }
        .onAppear {
            // Preselected: the Mac's preferred languages plus every keyboard layout added in
            // System Settings (Polish Pro → Polish, Russian – PC → Russian).
            if !settings.languagesChosen {
                settings.enabledLanguages = AppSettings.systemLanguages().union(KeyboardLanguage.enabled())
            }
        }
        .onChange(of: step) { newStep in
            if newStep.rawValue > Step.languages.rawValue { settings.languagesChosen = true }
        }
    }

    private var nextTitle: String {
        switch step {
        case .microphone where !mic, .accessibility where !ax: return L("Skip for now")
        default: return L("Continue")
        }
    }

    private var canContinue: Bool {
        if step == .models {
            // The speech model is required; cleanup models can finish downloading later.
            return models.state(settings.speechModelID) == .downloaded
        }
        return true
    }

    // MARK: Steps

    private var languagesStep: some View {
        StepView(symbol: "globe", title: L("Which languages do you speak?"),
                 text: "") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(DictationLanguage.allCases) { lang in
                        Toggle(lang.nativeName, isOn: Binding(
                            get: { settings.enabledLanguages.contains(lang) },
                            set: { on in
                                if on { settings.enabledLanguages.insert(lang) }
                                else if settings.enabledLanguages.count > 1 { settings.enabledLanguages.remove(lang) }
                            }))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .frame(maxWidth: 420)
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 88, height: 88)
            Text(L("Welcome to Mowa")).font(.largeTitle).fontWeight(.semibold)
            Text(L("Speak instead of typing — in any app. Mowa turns your voice into clean, punctuated text."))
                .font(.title3).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 10) {
                Bullet(symbol: "lock.fill", text: L("100% on your Mac. No cloud, no account, nothing you say leaves this computer."))
                Bullet(symbol: "globe", text: L("English, Polish, Russian, Spanish, German, French, Portuguese and Italian."))
                Bullet(symbol: "sparkles", text: L("Removes \"um\"s, fixes punctuation and applies your corrections."))
                Bullet(symbol: "heart", text: L("Free and open source."))
            }
            .padding(.top, 8)
        }
    }

    private var microphone: some View {
        StepView(symbol: "mic.fill", title: L("Microphone"),
                 text: L("Mowa listens only while you hold the dictation key. Audio is processed on this Mac and then discarded.")) {
            if mic {
                Label(L("Microphone access granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else if Permissions.microphoneDenied {
                Button(L("Open Privacy Settings")) { Permissions.openMicrophoneSettings() }
            } else {
                Button(L("Allow Microphone")) { Task { mic = await Permissions.requestMicrophone() } }
                    .controlSize(.large)
            }
        }
    }

    private var accessibility: some View {
        StepView(symbol: "keyboard", title: L("Accessibility"),
                 text: L("Mowa needs Accessibility access to notice the dictation key in other apps and to type the text where your cursor is. It also reads the text near your cursor to spell names right. Nothing leaves your Mac.")) {
            if ax {
                Label(L("Accessibility access granted"), systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                VStack(spacing: 10) {
                    Button(L("Open Accessibility Settings")) {
                        Permissions.askForAccessibility()
                    }
                    .controlSize(.large)
                    Text(L("Turn on Mowa in the list, then come back here."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var modelsStep: some View {
        let ram = SystemInfo.physicalMemoryGB
        let speech = ModelCatalog.speechModel(id: settings.speechModelID)
        let cleanupModel = ModelCatalog.cleanupModel(id: settings.cleanupModelID)
        return StepView(symbol: "arrow.down.circle", title: L("Download the models"),
                        text: LF("Picked for your Mac (%d GB memory). Downloaded once from Hugging Face, then everything works offline.", ram)) {
            VStack(alignment: .leading, spacing: 12) {
                OnboardingModelLine(title: L("Speech recognition"), name: speech?.displayName ?? settings.speechModelID,
                                    sizeMB: speech?.approxDownloadMB, state: models.state(settings.speechModelID))
                OnboardingModelLine(title: L("Cleanup model"), name: cleanupModel?.displayName ?? settings.cleanupModelID,
                                    sizeMB: cleanupModel?.approxDownloadMB, state: models.state(settings.cleanupModelID))
                HStack {
                    Spacer()
                    Button(L("Download")) { startDownloads() }
                        .controlSize(.large)
                        .disabled(allDone || models.anyDownloading)
                    Spacer()
                }
                .padding(.top, 6)
                Text(L("You can keep going while the cleanup model downloads."))
                    .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
            .frame(maxWidth: 440)
        }
    }

    private var allDone: Bool {
        [settings.speechModelID, settings.cleanupModelID]
            .filter { $0 != RemoteLLM.selectionID }
            .allSatisfy { models.state($0) == .downloaded }
    }

    private func startDownloads() {
        models.download(settings.speechModelID, kind: .speech) { ok in
            guard ok else { return }
            controller.loadModels()
            #if !MOWA_INTEL
            // Parakeet's safety net (Whisper) follows in the background; nothing waits for it.
            // (Intel builds have no Parakeet.)
            if ModelCatalog.isParakeet(settings.speechModelID), Transcriber.safetyNetModelID == nil {
                models.download(ModelCatalog.defaultSpeechModelID, kind: .speech) { ok in if ok { controller.loadModels() } }
            }
            #endif
        }
        if !settings.cleanupModelID.isEmpty, settings.cleanupModelID != RemoteLLM.selectionID {
            models.download(settings.cleanupModelID, kind: .cleanup) { ok in if ok { controller.loadModels() } }
        }
    }

    private var tryIt: some View {
        StepView(symbol: "waveform", title: L("Try it"),
                 text: LF("Click in the box, hold %@, say something, and let go.", settings.hotkey.displayName)) {
            VStack(alignment: .leading, spacing: 10) {
                TryItStatus(state: controller.state, speechID: settings.speechModelID)
                TextEditor(text: $testText)
                    .font(.body)
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                HotkeyPicker(title: L("Dictation key"))
                Text(L("Double-tap the key for hands-free mode. Select text and say what to change (\"make it shorter\")."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: 460)
        }
    }
}

// MARK: - Pieces

/// "Try it" step: says what the speech model is doing, so the first dictation isn't attempted
/// (and rejected) while the model is still downloading or loading.
private struct TryItStatus: View {
    @ObservedObject var state: AppState
    @ObservedObject private var models = ModelManager.shared
    let speechID: String

    var body: some View {
        HStack(spacing: 8) {
            switch models.state(speechID) {
            case .downloading(let p):
                ProgressView(value: p).frame(width: 120)
                Text(L("Download a speech model first (Settings → Models)."))
            case .downloaded where !state.speechModelReady:
                ProgressView().controlSize(.small)
                Text(state.loadingMessage ?? L("Loading speech model…"))
            case .downloaded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                if models.anyDownloading { Text(L("You can keep going while the cleanup model downloads.")) }
            default:
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(L("Download a speech model first (Settings → Models)."))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
    }
}

private struct StepView<Content: View>: View {
    let symbol: String
    let title: String
    var experimental = false
    let text: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(MowaColors.accent)
            HStack(spacing: 8) {
                Text(title).font(.title).fontWeight(.semibold)
                if experimental { ExperimentalBadge() }
            }
            if !text.isEmpty {
                Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 460)
            }
            content().padding(.top, 6)
        }
    }
}

private struct Bullet: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(MowaColors.accent).frame(width: 20)
            Text(text)
        }
    }
}

private struct ProgressDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? MowaColors.accent : Color.secondary.opacity(0.3))
                    .frame(width: i == current ? 22 : 8, height: 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: current)
    }
}

private struct OnboardingModelLine: View {
    let title: String
    let name: String
    let sizeMB: Int?
    let state: ModelManager.State

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(name)
                    if let sizeMB {
                        Text(sizeMB >= 1000 ? String(format: "%.1f GB", Double(sizeMB) / 1000) : "\(sizeMB) MB")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            switch state {
            case .downloaded:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .downloading(let p):
                ProgressView(value: p).frame(width: 110)
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(message)
            case .notDownloaded:
                EmptyView()
            }
        }
    }
}
