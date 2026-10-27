import AppKit
import MowaCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, models, vocabulary, snippets, history, permissions, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("General")
        case .models: return L("Models")
        case .vocabulary: return L("Vocabulary")
        case .snippets: return L("Snippets")
        case .history: return L("History")
        case .permissions: return L("Permissions")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .models: return "cpu"
        case .vocabulary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .permissions: return "lock.shield"
        case .about: return "info.circle"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    let controller: DictationController
    @ObservedObject private var nav = SettingsNavigation.shared

    var body: some View {
        // Plain sidebar + detail instead of NavigationSplitView: no toolbar, so no sidebar
        // toggle button, no header hidden under the toolbar's blur, and one background
        // colour from the top of the window to the bottom.
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: Binding(get: { nav.tab }, set: { if let t = $0 { nav.tab = t } })) { tab in
                Label(tab.title, systemImage: tab.symbol).tag(tab)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 200)
            .background(SidebarMaterial().ignoresSafeArea())

            Divider().ignoresSafeArea()

            Group {
                switch nav.tab {
                case .general: GeneralSettings(controller: controller)
                case .models: ModelsSettings(controller: controller)
                case .vocabulary: VocabularySettings()
                case .snippets: SnippetSettings()
                case .history: HistoryView(controller: controller)
                case .permissions: PermissionsSettings(controller: controller)
                case .about: AboutView()
                }
            }
            .scrollContentBackground(.hidden)
            .frame(minWidth: 520, maxWidth: .infinity, minHeight: 460, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor).ignoresSafeArea())
        }
    }
}

/// The translucent sidebar material System Settings uses.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - General

struct GeneralSettings: View {
    let controller: DictationController
    @EnvironmentObject var settings: AppSettings
    @State private var launchAtLogin = Permissions.launchAtLogin
    @State private var showVoiceEnrollment = false
    @State private var voiceSummary = ""

    /// "Русский (MacBook Pro Microphone, AirPods); English (MacBook Pro Microphone)".
    private static func recordedVoices() -> String {
        guard let profile = VoicePrint.load() else { return "" }
        var parts = profile.languages.map { lang in
            let mics = VoiceSlot.allCases.compactMap { profile.sample(language: lang, slot: $0) }
                .map { $0.micName ?? L("Microphone") }
            return "\(lang.nativeName) (\(mics.joined(separator: ", ")))"
        }
        if profile.sample(language: nil, slot: .first) != nil { parts.append(L("earlier recording")) }
        return parts.joined(separator: "; ")
    }

    @State private var microphones: [AudioInputDevice] = []

    var body: some View {
        Form {
            Section(L("General")) {
                HotkeyPicker(title: L("Key"))

                Toggle(L("Double-tap the key for hands-free dictation"), isOn: $settings.doubleTapHandsFree)

                HStack {
                    Picker(L("Sound"), selection: $settings.sound) {
                        ForEach(SoundChoice.allCases) { Text($0.displayName).tag($0) }
                    }
                    Button {
                        Feedback.preview(settings.sound)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help(L("Play the start and stop sounds"))
                    .disabled(settings.sound == .off)
                }


                // Notes sit under the setting's own label, in the same row (Drew 2026-10-21).
                Picker(selection: $settings.headphonesMicrophoneUID) {
                    Text(L("Same as macOS")).tag("")
                    ForEach(microphones, id: \.uid) { Text($0.name).tag($0.uid) }
                    // A picked mic that isn't connected right now stays selectable.
                    if !settings.headphonesMicrophoneUID.isEmpty,
                       !microphones.contains(where: { $0.uid == settings.headphonesMicrophoneUID }) {
                        Text(L("Not connected")).tag(settings.headphonesMicrophoneUID)
                    }
                } label: {
                    SettingLabel(title: L("Microphone with Bluetooth headphones"),
                                 note: L("With the Mac's mic, your headphones keep their sound quality."))
                }
                .onAppear { microphones = AudioDevices.microphonesBesidesHeadphones() }

                Toggle(isOn: $settings.writeInKeyboardLanguage) {
                    SettingLabel(title: L("Write in my keyboard's language"),
                                 note: L("Speak any language, and the text is typed in the language of your keyboard layout."))
                }

                // Cleanup lives in General (Drew 2026-10-21), no section of its own.
                // No "Off" while typing in the keyboard's language: translating needs the model.
                Picker(L("Cleanup"), selection: $settings.cleanupLevel) {
                    ForEach(CleanupLevel.allCases.filter { !settings.writeInKeyboardLanguage || $0 != .off }) {
                        Text($0.displayName).tag($0)
                    }
                }
                VStack(alignment: .leading) {
                    Text(L("Extra instructions for the cleanup model"))
                    TextEditor(text: $settings.customInstructions)
                        .font(.body)
                        .frame(height: 56)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.secondary.opacity(0.3)))
                    Text(L("For example: \"Use British spelling\" or \"Never use exclamation marks\"."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section(L("Languages")) {
                ForEach(DictationLanguage.allCases) { lang in
                    Toggle(lang.nativeName, isOn: Binding(
                        get: { settings.enabledLanguages.contains(lang) },
                        set: { on in
                            if on { settings.enabledLanguages.insert(lang) }
                            else if settings.enabledLanguages.count > 1 { settings.enabledLanguages.remove(lang) }
                            settings.languagesChosen = true
                        }))
                }
            }

            Section {
                Toggle(isOn: $settings.voiceFilter) {
                    HStack(spacing: 6) { Text(L("Ignore other people's voices")); ExperimentalBadge() }
                }
                    .disabled(!settings.hasVoiceprint)
                    .onChange(of: settings.voiceFilter) { on in
                        if on { Task.detached(priority: .utility) { SpeakerEmbedder.shared.prewarm() } }
                    }
                HStack {
                    Button(settings.hasVoiceprint ? L("Manage my voice…") : L("Learn my voice…")) { showVoiceEnrollment = true }
                    if settings.hasVoiceprint {
                        Button(L("Forget my voice"), role: .destructive) {
                            VoicePrint.delete()
                            settings.voiceFilter = false
                            settings.hasVoiceprint = false
                            voiceSummary = ""
                        }
                    }
                }
                if settings.hasVoiceprint, !voiceSummary.isEmpty {
                    Text(LF("Recorded: %@", voiceSummary))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                HStack(spacing: 6) { Text(L("My voice")); ExperimentalBadge() }
            } footer: {
                Text(L("Mowa learns your voice from a short text you read aloud. When this is on, speech that doesn't sound like you — a colleague, a TV — is left out. Works best when people take turns: voices talking over each other can't be separated. Your voiceprint stays on this Mac."))
            }

            Section {
                ForEach(AppCategory.allCases) { category in
                    Picker(category.displayName, selection: Binding(
                        get: { settings.writingStyles[category] ?? WritingStyle.defaultStyle(for: category) },
                        set: { settings.writingStyles[category] = $0 })) {
                        ForEach(WritingStyle.allCases) { style in
                            Text(style.displayName).tag(style)
                        }
                    }
                    .help((settings.writingStyles[category] ?? WritingStyle.defaultStyle(for: category)).example)
                }
                Toggle(L("Use names on screen to spell words right"), isOn: $settings.useScreenContext)
            } header: {
                Text(L("Writing style"))
            } footer: {
                Text(L("Mowa recognises the kind of app you're typing in. Casual uses lighter punctuation, Very casual also skips capital letters and the final period, Excited adds exclamation marks. Names on screen are read only around the cursor and never leave this Mac."))
            }


            Section(L("Behaviour")) {
                Toggle(L("Show a notice when Mowa starts"), isOn: $settings.showLaunchNotice)
                if DevRecorder.isAvailable {
                    // Developer builds only (scripts/build.sh --dev); release builds never show this.
                    Toggle(L("Save recordings for testing (developer build)"), isOn: $settings.devSaveRecordings)
                }
                Toggle(L("Launch Mowa at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { Permissions.launchAtLogin = $0 }
                Toggle(L("Check for updates automatically"), isOn: $settings.checkForUpdates)
                    .onChange(of: settings.checkForUpdates) { _ in AppUpdater.shared.applySettings() }
                Toggle(L("Download and install updates automatically"), isOn: $settings.autoInstallUpdates)
                    .onChange(of: settings.autoInstallUpdates) { _ in AppUpdater.shared.applySettings() }
                    .disabled(!settings.checkForUpdates)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            voiceSummary = Self.recordedVoices()
        }
        .onChange(of: showVoiceEnrollment) { open in
            if !open { voiceSummary = Self.recordedVoices() }
        }
        .sheet(isPresented: $showVoiceEnrollment) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) { Text(L("Learn my voice")).font(.title2).fontWeight(.semibold); ExperimentalBadge() }
                Text(L("Read the text below aloud at your normal pace."))
                    .foregroundStyle(.secondary)
                VoiceEnrollmentView()
                HStack {
                    Spacer()
                    Button(L("Close")) { showVoiceEnrollment = false }.keyboardShortcut(.cancelAction)
                }
            }
            .padding(24)
            .frame(width: 560)
            .environmentObject(settings)
        }
    }
}

/// A setting's title with its short note under it, in the same row as the control.
struct SettingLabel: View {
    let title: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(note).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Models

struct ModelsSettings: View {
    let controller: DictationController
    @EnvironmentObject var settings: AppSettings
    @ObservedObject private var models = ModelManager.shared
    @State private var customModel = ""
    @State private var browser: HFBrowserKind?
    @State private var serverKey = ServerKey.read()
    @State private var serverTest: (ok: Bool, message: String)?
    @State private var testingServer = false
    @State private var diskUsage: Int64 = 0

    private var ram: Int { SystemInfo.physicalMemoryGB }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LF("This Mac has %d GB of memory.", ram)).font(.headline)
                    Text(settings.cleanupModelID == RemoteLLM.selectionID
                         ? L("Speech recognition runs on your Mac. Cleanup runs on your server.")
                         : L("Everything runs on your Mac. Nothing you say is sent anywhere."))
                        .foregroundStyle(.secondary)
                    Text(LF("Models use %@ on disk.", ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file)))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Section(L("Speech recognition")) {
                ForEach(ModelCatalog.speechModels.filter { Hardware.isAppleSilicon || !$0.appleSiliconOnly }) { spec in
                    ModelRow(title: spec.displayName, note: spec.note, sizeMB: spec.approxDownloadMB,
                             id: spec.id, kind: .speech,
                             selected: settings.speechModelID == spec.id,
                             tooBig: false,
                             onSelect: { settings.speechModelID = spec.id; controller.loadModels() })
                }
                addedModelRows(.speech)
                browseButton(.speech)
                addModelButton(.speech)
            }

            Section {
                // Only models this Mac has the memory for (plus the selected one, so it never vanishes).
                ForEach(ModelCatalog.cleanupModels.filter { ram >= $0.minRAMGB || settings.cleanupModelID == $0.id }) { spec in
                    ModelRow(title: spec.displayName, note: L(spec.note), sizeMB: spec.approxDownloadMB,
                             id: spec.id, kind: .cleanup,
                             selected: settings.cleanupModelID == spec.id,
                             tooBig: ram < spec.minRAMGB,
                             onSelect: { settings.cleanupModelID = spec.id; controller.loadModels() })
                }
                customModelField(text: $customModel, current: settings.cleanupModelID)
            } header: {
                Text(L("Cleanup model"))
            } footer: {
                Text(L("One model does all the cleanup: dictation, voice commands on selected text and translation. Faster models are less accurate, more accurate ones are slower. Only models this Mac has enough memory for are listed."))
            }

            Section {
                Toggle(L("Use the model on this server"), isOn: Binding(
                    get: { settings.serverEnabled },
                    set: { setServer($0) }))
                Group {
                    TextField(L("Server address"), text: $settings.serverURL, prompt: Text(verbatim: "http://localhost:11434/v1"))
                    TextField(L("Model name"), text: $settings.serverModel, prompt: Text(verbatim: "qwen3:4b"))
                    SecureField(L("API key (optional)"), text: $serverKey)
                        .onChange(of: serverKey) { ServerKey.write($0) }
                    HStack(spacing: 10) {
                        Button(L("Test connection")) { testServer() }
                            .disabled(testingServer || !RemoteLLM.isConfigured(settings))
                        if testingServer { ProgressView().controlSize(.small) }
                        if let serverTest {
                            Text(serverTest.message).font(.caption)
                                .foregroundStyle(serverTest.ok ? Color.green : Color.red)
                                .lineLimit(3)
                        } else if settings.serverEnabled, !RemoteLLM.isConfigured(settings) {
                            Text(L("Enter the server address and model name first.")).font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(!settings.serverEnabled)
            } header: {
                Text(L("Model on a server"))
            } footer: {
                Text(L("Any server with an OpenAI-compatible API (Ollama, LM Studio, llama.cpp, vLLM). Your dictated text is sent to this server, so it no longer stays on this Mac. Use https:// for servers outside your local network."))
            }
        }
        .formStyle(.grouped)
        .sheet(item: $browser) { kind in
            HuggingFaceBrowser(kind: kind, ram: ram) { id in
                if kind.modelKind == .speech { useHuggingFaceSpeechModel(id) } else { useHuggingFaceModel(id) }
            }
        }
        // Ticked + address and model name filled in → cleanup switches to the server.
        .onChange(of: settings.serverURL) { _ in switchToServerIfReady() }
        .onChange(of: settings.serverModel) { _ in switchToServerIfReady() }
        // Picking a model on this Mac turns the server off.
        .onChange(of: settings.cleanupModelID) { id in
            if id != RemoteLLM.selectionID, settings.serverEnabled { settings.serverEnabled = false }
        }
        .onAppear {
            models.refresh()
            DispatchQueue.global(qos: .utility).async {
                let usage = ModelManager.diskUsage()
                DispatchQueue.main.async { diskUsage = usage }
            }
        }
    }

    /// "Use the model on this server": on → cleanup goes to the server as soon as the address
    /// and model name are set; off → back to the model on this Mac used before.
    private func setServer(_ on: Bool) {
        settings.serverEnabled = on
        serverTest = nil
        if on {
            switchToServerIfReady()
        } else if settings.cleanupModelID == RemoteLLM.selectionID {
            let last = settings.lastLocalCleanupModelID
            let downloaded = ModelCatalog.cleanupModels.map(\.id).first { LLMEngine.isDownloaded($0) }
            settings.cleanupModelID = LLMEngine.isDownloaded(last) ? last : (downloaded ?? last)
            controller.loadModels()
        }
    }

    private func switchToServerIfReady() {
        guard settings.serverEnabled, RemoteLLM.isConfigured(settings),
              settings.cleanupModelID != RemoteLLM.selectionID else { return }
        settings.cleanupModelID = RemoteLLM.selectionID
        controller.loadModels()
    }

    private func testServer() {
        guard let config = RemoteLLM.config(settings) else { return }
        testingServer = true
        serverTest = nil
        Task { @MainActor in
            let error = await RemoteLLM.test(config)
            if let error {
                serverTest = (ok: false, message: error)
            } else {
                serverTest = (ok: true, message: L("Connected."))
            }
            testingServer = false
        }
    }

    @ViewBuilder
    private func customModelField(text: Binding<String>, current: String) -> some View {
        addedModelRows(.cleanup)
        // Intel Macs run GGUF files with llama.cpp; MLX models from Hugging Face don't apply.
        if Hardware.isAppleSilicon { mlxModelField(text: text) }
        browseButton(.cleanup)
        addModelButton(.cleanup)
    }

    /// Models the user added (ModelManager.added), plus the selected model if it is a custom one
    /// that isn't in that list, so the selection is always visible.
    private func addedIDs(_ kind: ModelManager.Kind) -> [String] {
        var ids = models.added(kind)
        let current = kind == .speech ? settings.speechModelID : settings.cleanupModelID
        let isCustom = kind == .speech
            ? !ModelCatalog.speechModels.contains(where: { $0.id == current })
            : current != RemoteLLM.selectionID && ModelCatalog.cleanupModel(id: current) == nil
        if !current.isEmpty, isCustom, !ids.contains(current) { ids.insert(current, at: 0) }
        return ids
    }

    @ViewBuilder
    private func addedModelRows(_ kind: ModelManager.Kind) -> some View {
        ForEach(addedIDs(kind), id: \.self) { id in
            let selected = (kind == .speech ? settings.speechModelID : settings.cleanupModelID) == id
            ModelRow(title: LocalModels.displayName(id),
                     note: LocalModels.isOnThisMac(id) ? L("Model on this Mac") : L("Custom model"),
                     sizeMB: nil, id: id, kind: kind, selected: selected, tooBig: false, removable: true,
                     onSelect: {
                         if kind == .speech { settings.speechModelID = id } else { settings.cleanupModelID = id }
                         controller.loadModels()
                     })
        }
    }

    /// "Add existing Model": a model folder (Apple silicon) or model file (Intel) already on this
    /// Mac joins the list; it is not selected, and stays until its delete button is pressed.
    @ViewBuilder
    private func addModelButton(_ kind: ModelManager.Kind) -> some View {
        let full = !models.canAdd(kind)
        VStack(alignment: .trailing, spacing: 4) {
            Button(L("Add existing Model")) {
                if Hardware.isAppleSilicon { useLocalFolder(cleanup: kind == .cleanup) } else { useLocalModelFile(speech: kind == .speech) }
            }
            .disabled(full)
            if full {
                Text(LF("You can add up to %d models. Delete one to add another.", ModelManager.maxAdded))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func mlxModelField(text: Binding<String>) -> some View {
        // LabeledContent, not a titled TextField inside an HStack: in a grouped Form the
        // field's title becomes a row label, and with the button beside it the label wrapped
        // and the field and button sat at different heights.
        LabeledContent {
            HStack(spacing: 8) {
                TextField("", text: text, prompt: Text(verbatim: "mlx-community/…"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 180, maxWidth: 260)
                useCustomModelButton(text: text)
            }
        } label: {
            Text(L("Other MLX model from Hugging Face (e.g. mlx-community/…)"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Intel Macs: a .gguf file as the cleanup model, or a whisper.cpp ggml .bin file for speech.
    private func useLocalModelFile(speech: Bool) {
        let settings = settings, models = models, controller = controller
        LocalModels.chooseModelFile(extension: speech ? "bin" : "gguf") { url in
            guard let url else { return }
            switch LocalModels.register(url) {
            case .speech(let id) where speech:
                models.add(id, kind: .speech)
            case .cleanup(let id) where !speech:
                models.add(id, kind: .cleanup)
            default:
                LocalModels.showNotUsable()
            }
        }
    }

    private func useCustomModelButton(text: Binding<String>) -> some View {
            Button(L("Use")) {
                let id = text.wrappedValue.trimmingCharacters(in: .whitespaces)
                guard id.contains("/") else { return }
                if useHuggingFaceModel(id) { text.wrappedValue = "" }
            }
            .disabled(!text.wrappedValue.contains("/") || !models.canAdd(.cleanup))
    }

    /// A Hugging Face model id (typed in or picked in the browser): joins the list, is selected
    /// and downloaded; loaded once the download finishes. false when the list is full.
    @discardableResult
    private func useHuggingFaceModel(_ id: String) -> Bool {
        if ModelCatalog.cleanupModel(id: id) == nil {
            guard models.add(id, kind: .cleanup) else { return false }
        }
        settings.cleanupModelID = id
        models.refresh()
        models.download(id, kind: .cleanup) { _ in controller.loadModels() }
        return true
    }

    /// "Browse Hugging Face…": models in the format this Mac runs (HFBrowserKind).
    private func browseButton(_ kind: ModelManager.Kind) -> some View {
        Button(L("Browse Hugging Face…")) { browser = kind == .speech ? .speech : .cleanup }
            .disabled(!models.canAdd(kind))
    }

    /// A speech model picked on Hugging Face: joins the list (unless it's a catalog model), is
    /// selected and downloaded; loaded once the download finishes.
    private func useHuggingFaceSpeechModel(_ id: String) {
        if !ModelCatalog.speechModels.contains(where: { $0.id == id }) {
            guard models.add(id, kind: .speech) else { return }
        }
        settings.speechModelID = id
        models.refresh()
        models.download(id, kind: .speech) { _ in controller.loadModels() }
    }

    /// cleanup false = speech model.
    private func useLocalFolder(cleanup: Bool) {
        let settings = settings, models = models, controller = controller
        LocalModels.chooseFolder { url in
            guard let url else { return }
            switch LocalModels.register(url) {
            case .speech(let id) where !cleanup:
                models.add(id, kind: .speech)
            case .cleanup(let id) where cleanup:
                models.add(id, kind: .cleanup)
            default:
                LocalModels.showNotUsable()
            }
        }
    }
}

struct ModelRow: View {
    let title: String
    let note: String
    let sizeMB: Int?
    let id: String
    let kind: ModelManager.Kind
    let selected: Bool
    let tooBig: Bool
    /// Added by the user: has a delete button whatever its state, and leaves the list when deleted.
    var removable: Bool = false
    let onSelect: () -> Void
    @ObservedObject private var models = ModelManager.shared

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // A model can only be chosen once it is fully on disk — picking a missing or
            // half-downloaded one left Mowa stuck on "Preparing the speech model…".
            Button(action: onSelect) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
            .disabled(!selected && !isDownloaded)
            .opacity(!selected && !isDownloaded ? 0.4 : 1)
            .help(!selected && !isDownloaded ? L("Download this model first") : "")

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(selected ? .semibold : .regular)
                    if let sizeMB {
                        Text(sizeMB >= 1000 ? String(format: "%.1f GB", Double(sizeMB) / 1000) : "\(sizeMB) MB")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if tooBig {
                        Text(L("needs more memory")).font(.caption).foregroundStyle(.orange)
                    }
                }
                Text(note).font(.caption).foregroundStyle(.secondary)
                if case .failed(let message) = models.state(id) {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2)
                }
            }
            Spacer()
            stateControl
        }
        .padding(.vertical, 2)
    }

    private var isDownloaded: Bool { models.state(id) == .downloaded }

    @ViewBuilder
    private var stateControl: some View {
        switch models.state(id) {
        case .downloaded:
            HStack(spacing: 8) {
                Label(L("Downloaded"), systemImage: "checkmark.circle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.green)
                    .help(L("Downloaded"))
                deleteButton
            }
        case .downloading(let p):
            HStack(spacing: 6) {
                ProgressView(value: p).frame(width: 90)
                Text("\(Int(p * 100))%").font(.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
                Button { models.cancel(id) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .help(L("Cancel download"))
            }
        case .notDownloaded, .failed:
            HStack(spacing: 8) {
                Button(L("Download")) {
                    models.download(id, kind: kind) { ok in
                        if ok { AppDelegate.shared.controller.modelDownloaded(id) }
                    }
                }
                if removable { deleteButton }
            }
        }
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            if selected { return }
            models.delete(id, kind: kind)
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .disabled(selected)
        .help(selected ? L("In use — select another model first")
              : LocalModels.isOnThisMac(id) ? L("Remove from the list. The model stays on your Mac.")
              : L("Delete from disk"))
    }
}

// MARK: - Vocabulary

struct VocabularySettings: View {
    @ObservedObject private var store = VocabularyStore.shared
    @ObservedObject private var learning = LearningStore.shared
    @State private var newWord = ""
    @State private var newHeard = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Names, brands and jargon Mowa should spell your way. Optionally add how it gets misheard."))
                .foregroundStyle(.secondary)
            HStack {
                TextField(L("Word (e.g. Unomage)"), text: $newWord).textFieldStyle(.roundedBorder)
                TextField(L("Misheard as (optional, comma-separated)"), text: $newHeard).textFieldStyle(.roundedBorder)
                Button(L("Add")) {
                    let w = newWord.trimmingCharacters(in: .whitespaces)
                    guard !w.isEmpty else { return }
                    store.entries.append(VocabularyEntry(word: w, heardAs: newHeard))
                    newWord = ""; newHeard = ""
                }
                .keyboardShortcut(.defaultAction)
                .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach($store.entries) { $entry in
                    HStack {
                        TextField(L("Word"), text: $entry.word).textFieldStyle(.plain).fontWeight(.medium)
                        TextField(L("Misheard as"), text: $entry.heardAs).textFieldStyle(.plain).foregroundStyle(.secondary)
                        if entry.learned == true {
                            Text(L("learned")).font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(MowaColors.accent.opacity(0.2)))
                        }
                        Button { store.entries.removeAll { $0.id == entry.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if store.entries.isEmpty {
                    Text(L("No words yet.")).foregroundStyle(.secondary)
                }
            }
            if !learning.suggestions.isEmpty {
                Text(L("Suggestions from your dictations")).font(.headline)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(learning.suggestions, id: \.self) { word in
                            HStack(spacing: 4) {
                                Text(word)
                                Button { learning.acceptSuggestion(word) } label: { Image(systemName: "plus.circle.fill") }
                                    .buttonStyle(.borderless).help(L("Add"))
                                Button { learning.dismissSuggestion(word) } label: { Image(systemName: "xmark.circle") }
                                    .buttonStyle(.borderless).help(L("Dismiss"))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Capsule().fill(Color.secondary.opacity(0.12)))
                        }
                    }
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Snippets

struct SnippetSettings: View {
    @ObservedObject private var store = VocabularyStore.shared
    @State private var trigger = ""
    @State private var expansion = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Say a short cue and Mowa types the full text — e.g. \"my address\" → your postal address."))
                .foregroundStyle(.secondary)
            HStack(alignment: .top) {
                TextField(L("Cue (what you say)"), text: $trigger).textFieldStyle(.roundedBorder).frame(width: 180)
                TextField(L("Text to type"), text: $expansion, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                Button(L("Add")) {
                    let t = trigger.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty, !expansion.isEmpty else { return }
                    store.snippets.append(Snippet(trigger: t, expansion: expansion))
                    trigger = ""; expansion = ""
                }
                .disabled(trigger.trimmingCharacters(in: .whitespaces).isEmpty || expansion.isEmpty)
            }
            List {
                ForEach($store.snippets) { $snippet in
                    HStack(alignment: .top) {
                        TextField(L("Cue"), text: $snippet.trigger).textFieldStyle(.plain).fontWeight(.medium).frame(width: 160)
                        TextField(L("Text"), text: $snippet.expansion, axis: .vertical).textFieldStyle(.plain)
                            .foregroundStyle(.secondary).lineLimit(1...6)
                        Button { store.snippets.removeAll { $0.id == snippet.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                }
            }
            .overlay {
                if store.snippets.isEmpty {
                    Text(L("No snippets yet.")).foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }
}

// MARK: - Permissions

struct PermissionsSettings: View {
    let controller: DictationController
    @State private var mic = Permissions.microphoneGranted
    @State private var ax = Permissions.accessibilityGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                PermissionRow(title: L("Microphone"), detail: L("To hear you. Audio never leaves your Mac."),
                              granted: mic) {
                    if Permissions.microphoneDenied { Permissions.openMicrophoneSettings() }
                    else { Task { mic = await Permissions.requestMicrophone() } }
                }
                PermissionRow(title: L("Accessibility"),
                              detail: L("To notice the dictation key in any app and type the text where your cursor is."),
                              granted: ax) {
                    Permissions.askForAccessibility()
                }
            } footer: {
                Text(L("After rebuilding or updating Mowa, macOS may ask again — remove the old Mowa entry in Accessibility and add it back."))
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in
            mic = Permissions.microphoneGranted
            let nowAX = Permissions.accessibilityGranted
            if nowAX && !ax { controller.hotkey.start() }
            ax = nowAX
        }
    }
}

struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)
            VStack(alignment: .leading) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button(L("Grant…"), action: action)
            }
        }
    }
}

// MARK: - About

struct AboutView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
            Text("Mowa").font(.largeTitle).fontWeight(.semibold)
            // Brand line, same in every language: "Mowa by Unomage" + the Unomage mark, links to unomage.com.
            // The mark is a working QR code (→ https://www.unomage.com/), the same visible size as
            // the Mowa icon above (96 pt frame, ~80 pt of artwork inside macOS's icon padding) and
            // scannable by a phone camera off the screen (decodes from ~66 px; 80 pt = 160 px on Retina).
            Button {
                NSWorkspace.shared.open(URL(string: "https://unomage.com")!)
            } label: {
                VStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Text(verbatim: "by").foregroundStyle(.secondary)
                        Text(verbatim: "Unomage").fontWeight(.semibold)
                    }
                    .font(.title3)
                    UnomageLogo()
                        .frame(width: 80, height: 80)
                }
            }
            .buttonStyle(.plain)
            .onHover { inside in if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
            .help(Text(verbatim: "unomage.com"))
            .accessibilityLabel(Text(verbatim: "Mowa by Unomage"))
            Text(LF("Version %@", SystemInfo.appVersion)).foregroundStyle(.secondary)
            Text(L("Free, open-source voice dictation that runs entirely on your Mac."))
                .multilineTextAlignment(.center)
            Text(Hardware.isAppleSilicon
                 ? L("Speech recognition: NVIDIA Parakeet and OpenAI Whisper. Cleanup: Qwen models via MLX. No account, no cloud, no tracking.")
                 : L("Speech recognition: OpenAI Whisper via whisper.cpp. Cleanup: Qwen models via llama.cpp. No account, no cloud, no tracking."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            HStack(spacing: 12) {
                Button(L("Website")) { NSWorkspace.shared.open(UpdateChecker.website) }
                Button(L("Source code")) {
                    NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repo)")!)
                }
                Button(L("Show log")) { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.log]) }
                Button(L("Show models folder")) { NSWorkspace.shared.open(AppPaths.support) }
            }
            Text(verbatim: "© 2026 Unomage Sp. z o.o. · ") + Text(L("MIT License"))
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
