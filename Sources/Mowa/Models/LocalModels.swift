import AppKit
import Foundation
import MowaCore
import UniformTypeIdentifiers

/// Models the user already has on disk (e.g. downloaded for another app). Mowa uses
/// them in place — nothing is copied, and "delete" only forgets the folder.
enum LocalModels {
    enum Found { case speech(id: String), cleanup(id: String) }

    private static let speechKey = "localSpeechModelPaths"

    static func speechPath(_ id: String) -> URL? {
        guard let path = (UserDefaults.standard.dictionary(forKey: speechKey) as? [String: String])?[id] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    static func knownSpeechIDs() -> [String] {
        ((UserDefaults.standard.dictionary(forKey: speechKey) as? [String: String]) ?? [:]).keys.sorted()
    }

    /// A folder or file the user pointed Mowa to (removing it only forgets it).
    static func isOnThisMac(_ id: String) -> Bool { speechPath(id) != nil || id.hasPrefix("local/") }

    static func displayName(_ id: String) -> String {
        if let file = HFFileRef(id: id) {
            return (file.fileName as NSString).deletingPathExtension
        }
        return id.hasPrefix("local/") ? String(id.dropFirst("local/".count)) : id
    }

    static func forgetSpeech(_ id: String) {
        var map = UserDefaults.standard.dictionary(forKey: speechKey) as? [String: String] ?? [:]
        map[id] = nil
        UserDefaults.standard.set(map, forKey: speechKey)
    }

    /// Recognises the folder (or .gguf file) and registers it. nil = not a model Mowa can run:
    /// speech needs a WhisperKit Core ML folder, cleanup an MLX folder (config.json + .safetensors)
    /// on Apple silicon or a GGUF file on Intel Macs.
    static func register(_ url: URL) -> Found? {
        let fm = FileManager.default
        let has: (String) -> Bool = { fm.fileExists(atPath: url.appendingPathComponent($0).path) }
        // Intel Macs: whisper.cpp model files (ggml-….bin) for speech.
        if !Hardware.isAppleSilicon, url.pathExtension.lowercased() == "bin",
           url.lastPathComponent.lowercased().hasPrefix("ggml") {
            let id = "local-" + url.deletingPathExtension().lastPathComponent
            var map = UserDefaults.standard.dictionary(forKey: speechKey) as? [String: String] ?? [:]
            map[id] = url.path
            UserDefaults.standard.set(map, forKey: speechKey)
            return .speech(id: id)
        }
        if Hardware.isAppleSilicon, ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"].allSatisfy(has) {
            let id = url.lastPathComponent
            var map = UserDefaults.standard.dictionary(forKey: speechKey) as? [String: String] ?? [:]
            map[id] = url.path
            UserDefaults.standard.set(map, forKey: speechKey)
            return .speech(id: id)
        }
        let files = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        if Hardware.isAppleSilicon {
            if has("config.json"), files.contains(where: { $0.hasSuffix(".safetensors") }) {
                let id = "local/" + url.lastPathComponent
                LLMEngine.registerLocal(id: id, directory: url)
                return .cleanup(id: id)
            }
        } else {
            // Intel Macs run GGUF files (llama.cpp): the file itself, or a folder with one in it.
            let gguf = url.pathExtension.lowercased() == "gguf"
                ? url
                : files.filter { $0.lowercased().hasSuffix(".gguf") }.sorted().first.map { url.appendingPathComponent($0) }
            if let gguf {
                let id = "local/" + gguf.deletingPathExtension().lastPathComponent
                LLMEngine.registerLocal(id: id, directory: gguf)
                return .cleanup(id: id)
            }
        }
        return nil
    }

    /// File picker for a model file on Intel Macs (.gguf cleanup, ggml .bin speech),
    /// non-modal like `chooseFolder`.
    @MainActor static func chooseModelFile(extension ext: String, _ completion: @escaping @MainActor (URL?) -> Void) {
        present({
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
            return panel
        }, completion)
    }

    /// Folder picker shown as a normal window (not runModal, see NonModalAlert), so dictation
    /// keeps working while it is open. `completion` gets nil on Cancel.
    @MainActor static func chooseFolder(_ completion: @escaping @MainActor (URL?) -> Void) {
        present({
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            return panel
        }, completion)
    }

    /// The picker that is open. One at a time: clicking the button again brings it to the front
    /// instead of opening a second one.
    @MainActor private static var openPanel: NSOpenPanel?

    @MainActor private static func present(_ make: () -> NSOpenPanel, _ completion: @escaping @MainActor (URL?) -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        if let openPanel {
            openPanel.makeKeyAndOrderFront(nil)
            return
        }
        let panel = make()
        panel.allowsMultipleSelection = false
        panel.prompt = L("Add")
        openPanel = panel
        panel.begin { response in
            let url = response == .OK ? panel.url : nil
            MainActor.assumeIsolated {
                openPanel = nil
                completion(url)
            }
        }
    }

    @MainActor static func showNotUsable() {
        NonModalAlert.show(
            title: L("This folder doesn't contain a model Mowa can use."),
            text: Hardware.isAppleSilicon
                ? L("Speech models must be WhisperKit Core ML folders (with AudioEncoder.mlmodelc). Cleanup models must be MLX folders (config.json and .safetensors files). GGUF models (Ollama, LM Studio) can't be used.")
                : L("Speech models must be whisper.cpp model files (ggml-….bin). Cleanup models must be GGUF files (.gguf)."))
    }
}
