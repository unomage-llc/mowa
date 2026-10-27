import Foundation
import MowaCore

/// Localized UI string. Strings live in Support/Localization/<lang>.lproj and are
/// copied into Mowa.app/Contents/Resources by scripts/build.sh.
func L(_ key: String) -> String {
    NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
}

/// Localized format string, e.g. `LF("%d words", 12)`.
func LF(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), locale: Locale.current, arguments: args)
}

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Mowa", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    static var speechModels: URL { subdir("Models/Speech") }
    static var cleanupModels: URL { subdir("Models/Cleanup") }
    static var history: URL { support.appendingPathComponent("history.json") }
    static var vocabulary: URL { support.appendingPathComponent("vocabulary.json") }
    static var snippets: URL { support.appendingPathComponent("snippets.json") }
    static var log: URL { subdir("Logs").appendingPathComponent("mowa.log") }

    private static func subdir(_ path: String) -> URL {
        let dir = support.appendingPathComponent(path, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// The key that starts dictation. All are modifier keys, so holding them never
/// types anything into the focused app.
/// The sounds played when a dictation starts (key pressed) and stops (key released).
/// Five calm, quiet sounds (Drew 2026-10-21; the old bubble/chime/click/glass/soft drop set
/// was replaced). Made by Mowa itself (soft sine tones, ~10 dB quieter than the old set): the
/// start sound rises, the stop sound falls.
enum SoundChoice: String, CaseIterable, Identifiable {
    /// The default (Drew 2026-10-22; the spoken "Mo/Wa" sound was removed the same day).
    case breath
    case felt
    case kalimba
    case droplet
    case bell
    case off

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .felt: return L("Felt piano")
        case .kalimba: return L("Kalimba")
        case .droplet: return L("Droplet")
        case .bell: return L("Small bell")
        case .breath: return L("Breath")
        case .off: return L("Off")
        }
    }

    /// Mowa's own sound files (Support/Sounds/<name>.wav in the app's Resources); nil when off.
    var startSound: String? { self == .off ? nil : "\(rawValue)-start" }
    var stopSound: String? { self == .off ? nil : "\(rawValue)-stop" }
}

/// The dictation key: fn (default) or a key / combination the user records (Shortcut).
/// Drew 2026-10-21: only these two; the old Right ⌥/⌘/⌃ choices became recorded shortcuts.
enum HotkeyChoice: String, CaseIterable, Identifiable, Codable {
    case fn
    case custom

    var id: String { rawValue }

    /// The key as named in sentences ("Hold %@ to dictate").
    var displayName: String {
        switch self {
        case .fn: return "fn"
        case .custom: return AppSettings.shared.customShortcut?.name ?? L("Custom shortcut")
        }
    }

    /// Picker row.
    var title: String {
        switch self {
        case .fn: return "fn"
        case .custom: return L("Custom shortcut")
        }
    }
}

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    @Published var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }
    @Published var hotkey: HotkeyChoice { didSet { d.set(hotkey.rawValue, forKey: "hotkey") } }
    /// The recorded dictation key when `hotkey` is .custom.
    @Published var customShortcut: Shortcut? { didSet { Shortcut.save(customShortcut) } }
    @Published var doubleTapHandsFree: Bool { didSet { d.set(doubleTapHandsFree, forKey: "doubleTapHandsFree") } }

    /// Spoken language: always detected automatically among the languages the user ticked
    /// (onboarding / Settings → Languages) — no single-language setting.
    let fixedLanguage: DictationLanguage? = nil
    @Published var enabledLanguages: Set<DictationLanguage> {
        didSet { d.set(enabledLanguages.map(\.rawValue).sorted(), forKey: "enabledLanguages") }
    }

    @Published var speechModelID: String { didSet { d.set(speechModelID, forKey: "speechModelID") } }
    /// The one cleanup model. Stored under the old "fastModelID" key so existing users keep their choice.
    @Published var cleanupModelID: String {
        didSet {
            d.set(cleanupModelID, forKey: "fastModelID")
            if cleanupModelID != RemoteLLM.selectionID { d.set(cleanupModelID, forKey: "lastLocalCleanupModelID") }
        }
    }
    /// The on-Mac cleanup model to go back to when "Use the model on this server" is turned off.
    var lastLocalCleanupModelID: String {
        let id = d.string(forKey: "lastLocalCleanupModelID") ?? ""
        return id.isEmpty || id == RemoteLLM.selectionID ? Hardware.defaultCleanupModelID : id
    }
    /// "Use the model on this server" is ticked. Cleanup actually switches to the server
    /// (cleanupModelID == RemoteLLM.selectionID) once the address and model name are filled in.
    @Published var serverEnabled: Bool { didSet { d.set(serverEnabled, forKey: "serverEnabled") } }
    /// Cleanup on the user's own server (cleanupModelID == RemoteLLM.selectionID). API key lives in the Keychain.
    @Published var serverURL: String { didSet { d.set(serverURL, forKey: "serverURL") } }
    @Published var serverModel: String { didSet { d.set(serverModel, forKey: "serverModel") } }

    @Published var cleanupLevel: CleanupLevel { didSet { d.set(cleanupLevel.rawValue, forKey: "cleanupLevel") } }
    /// Writing style follows the app being typed in. Always on (Drew 2026-10-21: no setting).
    let contextAwareStyle = true
    /// Writing style per kind of app (Settings → Writing style).
    @Published var writingStyles: [AppCategory: WritingStyle] {
        didSet { for (k, v) in writingStyles { d.set(v.rawValue, forKey: "writingStyle.\(k.rawValue)") } }
    }
    /// Read names/terms around the cursor to spell them right (stays on the Mac).
    @Published var useScreenContext: Bool { didSet { d.set(useScreenContext, forKey: "useScreenContext") } }
    @Published var customInstructions: String { didSet { d.set(customInstructions, forKey: "customInstructions") } }

    // Always on — no settings for these (turning other audio down, the floating indicator,
    // restoring the clipboard, a space between consecutive dictations, history, learning).
    @Published var sound: SoundChoice { didSet { d.set(sound.rawValue, forKey: "sound") } }
    let duckAudio = true
    let showOverlay = true
    @Published var showLaunchNotice: Bool { didSet { d.set(showLaunchNotice, forKey: "showLaunchNotice") } }
    let restoreClipboard = true
    /// Adds a space when a dictation is typed right after a word or a full stop ("…today.Next" → "…today. Next").
    let smartSpacing = true
    let keepHistory = true
    /// Reduce background noise in noisy recordings before recognition (NoiseReducer) — always on.
    let noiseReduction = true
    /// "Ignore other people's voices": leave out speech that doesn't match the voiceprint.
    @Published var voiceFilter: Bool { didSet { d.set(voiceFilter, forKey: "voiceFilter") } }
    /// A voiceprint is saved on this Mac (VoicePrint); not stored in UserDefaults.
    @Published var hasVoiceprint: Bool
    @Published var checkForUpdates: Bool { didSet { d.set(checkForUpdates, forKey: "checkForUpdates") } }
    @Published var autoInstallUpdates: Bool { didSet { d.set(autoInstallUpdates, forKey: "autoInstallUpdates") } }
    /// Set just before Sparkle installs an update, so the relaunched app can say "Mowa updated".
    var updatedFromVersion: String? {
        get { d.string(forKey: "updatedFromVersion") }
        set { d.set(newValue, forKey: "updatedFromVersion") }
    }
    /// Only the languages the user ticked are recognised (no "also recognise the others" setting).
    let acceptOtherLanguages = false
    /// Type in the language of the current keyboard layout, whatever language was spoken.
    /// Typing in the keyboard's language translates with the cleanup model, so cleanup can't be off
    /// while it's on (Drew 2026-10-21): turning it on moves "Off" to "Smart".
    @Published var writeInKeyboardLanguage: Bool {
        didSet {
            d.set(writeInKeyboardLanguage, forKey: "writeInKeyboardLanguage")
            if writeInKeyboardLanguage, cleanupLevel == .off { cleanupLevel = .smart }
        }
    }
    /// Microphone to record with while Bluetooth headphones are connected (UID); empty = same as macOS.
    @Published var headphonesMicrophoneUID: String { didSet { d.set(headphonesMicrophoneUID, forKey: AudioDevices.headphonesMicrophoneKey) } }
    let learnLanguages = true
    let learnCorrections = true
    /// Developer builds only (DevRecorder): save every dictation's audio + results for the eval.
    @Published var devSaveRecordings: Bool { didSet { d.set(devSaveRecordings, forKey: "devSaveRecordings") } }
    let suggestWords = true
    /// The user has picked their languages (onboarding or Settings).
    @Published var languagesChosen: Bool { didSet { d.set(languagesChosen, forKey: "languagesChosen") } }

    private init() {
        // Parakeet became the default on Apple silicon (2026-10-24). People who set Mowa up before that
        // never stored a speech model (they used the registered default, Whisper): keep them on it
        // rather than switching them to a model they haven't downloaded.
        if d.bool(forKey: "onboardingDone"),
           d.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["speechModelID"] == nil,
           Transcriber.isDownloaded(ModelCatalog.defaultSpeechModelID) {
            d.set(ModelCatalog.defaultSpeechModelID, forKey: "speechModelID")
        }
        d.register(defaults: [
            "onboardingDone": false,
            "hotkey": HotkeyChoice.fn.rawValue,
            "doubleTapHandsFree": true,
            "fixedLanguage": "",
            "enabledLanguages": DictationLanguage.allCases.map(\.rawValue),
            "speechModelID": Hardware.defaultSpeechModelID,
            "fastModelID": Hardware.defaultCleanupModelID,
            "serverURL": "",
            "serverModel": "",
            "cleanupLevel": CleanupLevel.smart.rawValue,
            "useScreenContext": true,
            "customInstructions": "",
            "sound": SoundChoice.breath.rawValue,
            "duckAudio": true,
            "showOverlay": true,
            "showLaunchNotice": true,
            "restoreClipboard": true,
            "smartSpacing": true,
            "keepHistory": true,
            "noiseReduction": true,
            "voiceFilter": false,
            "checkForUpdates": true,
            "autoInstallUpdates": true,
            "acceptOtherLanguages": true,
            "writeInKeyboardLanguage": false,
            "languagesChosen": false,
            "learnLanguages": true,
            "learnCorrections": true,
            "devSaveRecordings": true,
            "suggestWords": true,
        ])

        onboardingDone = d.bool(forKey: "onboardingDone")
        // The old Right ⌥ / ⌘ / ⌃ choices: kept as the same key, recorded as a custom shortcut.
        // (Locals first: self's properties can't be read before all of them are set.)
        var shortcut = Shortcut.load()
        var key: HotkeyChoice
        let savedKey = d.string(forKey: "hotkey") ?? ""
        let oldKeys: [String: UInt16] = ["rightOption": 61, "rightCommand": 54, "rightControl": 62]
        if let code = oldKeys[savedKey] {
            if shortcut == nil {
                shortcut = Shortcut(modifierKey: code)
                Shortcut.save(shortcut)   // didSet doesn't run in init
            }
            key = .custom
            d.set(HotkeyChoice.custom.rawValue, forKey: "hotkey")
        } else {
            key = HotkeyChoice(rawValue: savedKey) ?? .fn
        }
        // Custom without a recorded key (can't happen through Settings): back to fn.
        if key == .custom, shortcut == nil { key = .fn }
        customShortcut = shortcut
        hotkey = key
        sound = SoundChoice(rawValue: d.string(forKey: "sound") ?? "") ?? .breath   // old names (mowa, bubble, chime…) → default
        doubleTapHandsFree = d.bool(forKey: "doubleTapHandsFree")
        let langs = (d.stringArray(forKey: "enabledLanguages") ?? []).compactMap(DictationLanguage.init(rawValue:))
        enabledLanguages = langs.isEmpty ? Set(DictationLanguage.allCases) : Set(langs)
        speechModelID = d.string(forKey: "speechModelID") ?? Hardware.defaultSpeechModelID
        cleanupModelID = d.string(forKey: "fastModelID") ?? Hardware.defaultCleanupModelID
        serverURL = d.string(forKey: "serverURL") ?? ""
        serverModel = d.string(forKey: "serverModel") ?? ""
        serverEnabled = d.object(forKey: "serverEnabled") as? Bool ?? (d.string(forKey: "fastModelID") == RemoteLLM.selectionID)
        cleanupLevel = CleanupLevel(rawValue: d.string(forKey: "cleanupLevel") ?? "") ?? .smart
        d.removeObject(forKey: "contextAwareStyle")   // the setting is gone; always on
        var styles: [AppCategory: WritingStyle] = [:]
        for cat in AppCategory.allCases {
            styles[cat] = WritingStyle(rawValue: d.string(forKey: "writingStyle.\(cat.rawValue)") ?? "") ?? WritingStyle.defaultStyle(for: cat)
        }
        writingStyles = styles
        useScreenContext = d.bool(forKey: "useScreenContext")
        customInstructions = d.string(forKey: "customInstructions") ?? ""
        showLaunchNotice = d.bool(forKey: "showLaunchNotice")
        // The old always-on microphone picker is gone (the headphones one replaced it).
        d.removeObject(forKey: "microphoneUID")
        hasVoiceprint = VoicePrint.exists
        voiceFilter = d.bool(forKey: "voiceFilter") && VoicePrint.exists
        checkForUpdates = d.bool(forKey: "checkForUpdates")
        autoInstallUpdates = d.bool(forKey: "autoInstallUpdates")
        writeInKeyboardLanguage = d.bool(forKey: "writeInKeyboardLanguage")
        // Not chosen yet: the Mac's own microphone (Drew 2026-10-21), so Bluetooth headphones never
        // switch to call mode (lower sound quality, a late stop sound, recordings with no audio).
        // Saved at once, so a later Mac or a missing mic doesn't change it behind the user's back.
        if let saved = d.string(forKey: AudioDevices.headphonesMicrophoneKey) {
            headphonesMicrophoneUID = saved
        } else {
            let builtIn = AudioDevices.inputDevices().first { $0.isBuiltIn }?.uid ?? ""
            headphonesMicrophoneUID = builtIn
            d.set(builtIn, forKey: AudioDevices.headphonesMicrophoneKey)
        }
        devSaveRecordings = d.bool(forKey: "devSaveRecordings")
        languagesChosen = d.bool(forKey: "languagesChosen")
        // Typing in the keyboard's language needs the cleanup model: "Off" isn't allowed with it.
        if writeInKeyboardLanguage, cleanupLevel == .off {
            cleanupLevel = .smart
            d.set(CleanupLevel.smart.rawValue, forKey: "cleanupLevel")
        }
    }

    /// Main languages guessed from the Mac's preferred languages (onboarding default).
    static func systemLanguages() -> Set<DictationLanguage> {
        let found = Locale.preferredLanguages.compactMap { DictationLanguage(whisperCode: $0) }
        return found.isEmpty ? [.english] : Set(found)
    }

    /// Languages auto-detection may choose from, in a stable order.
    var candidateLanguages: [DictationLanguage] {
        if let fixedLanguage { return [fixedLanguage] }
        let list = DictationLanguage.allCases.filter { enabledLanguages.contains($0) }
        return list.isEmpty ? DictationLanguage.allCases : list
    }
}

enum SystemInfo {
    static var physicalMemoryGB: Int {
        Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}
