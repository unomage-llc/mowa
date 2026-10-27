import SwiftUI
import MowaCore

/// Which models Settings → "Browse Hugging Face…" lists. Each one is the format this Mac's
/// engine runs: MLX folders and WhisperKit Core ML folders on Apple silicon, single GGUF and
/// whisper.cpp ggml files on Intel (llama.cpp / whisper.cpp).
enum HFBrowserKind: String, Identifiable {
    case mlx, gguf, whisperKit, ggml
    var id: String { rawValue }

    static var speech: HFBrowserKind { Hardware.isAppleSilicon ? .whisperKit : .ggml }
    static var cleanup: HFBrowserKind { Hardware.isAppleSilicon ? .mlx : .gguf }

    var modelKind: ModelManager.Kind { self == .whisperKit || self == .ggml ? .speech : .cleanup }

    var title: String { modelKind == .speech ? L("Speech models on Hugging Face") : L("Models on Hugging Face") }

    var footnote: String {
        switch self {
        case .mlx: return L("MLX models from mlx-community, most downloaded first. Mowa downloads the one you add.")
        case .gguf: return L("GGUF models, most downloaded first. Pick a model, then the file to download: a larger file is more accurate and slower.")
        case .whisperKit: return L("Whisper models from argmaxinc/whisperkit-coreml. Mowa downloads the one you add.")
        case .ggml: return L("Whisper models from ggerganov/whisper.cpp. Mowa downloads the one you add.")
        }
    }

    var searchPrompt: String {
        modelKind == .speech ? L("Search, e.g. large-v3 or small") : L("Search, e.g. Qwen3 or Gemma")
    }
}

/// A row in the browser. `modelID` is the Mowa model id; nil for a GGUF repo, whose file is
/// picked in a second step.
struct HFItem: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let size: Int64?
    let downloads: Int?
    let modelID: String?
}

/// Hugging Face's public API (no account needed).
enum HFModelSearch {
    static let limit = 50
    static let whisperKitRepo = "argmaxinc/whisperkit-coreml"
    static let whisperCppRepo = "ggerganov/whisper.cpp"

    private struct BadStatus: Error {}

    private struct Model: Decodable {
        let id: String
        let downloads: Int?
        /// Bytes stored in the repo — about what Mowa downloads (MLX: one model per repo).
        let usedStorage: Int64?
    }

    private struct TreeEntry: Decodable {
        let type: String
        let path: String
        let size: Int64?
        struct LFS: Decodable { let size: Int64? }
        let lfs: LFS?
        var bytes: Int64? { lfs?.size ?? size }
    }

    static func items(_ kind: HFBrowserKind, query: String) async throws -> [HFItem] {
        switch kind {
        case .mlx:
            let found = try await models(query, author: "mlx-community", filter: nil, withSizes: true)
            return found.map { m in
                HFItem(id: m.id, title: m.id.hasPrefix("mlx-community/") ? String(m.id.dropFirst(14)) : m.id,
                       size: m.usedStorage, downloads: m.downloads, modelID: m.id)
            }
        case .gguf:
            // A GGUF repo holds every quantisation of the model, so its storage isn't one download.
            let found = try await models(query, author: nil, filter: "gguf", withSizes: false)
            return found.map { HFItem(id: $0.id, title: $0.id, size: nil, downloads: $0.downloads, modelID: nil) }
        case .whisperKit:
            let dirs = try await tree(whisperKitRepo).filter { $0.type == "directory" && !$0.path.hasPrefix(".") }
            return matching(query, dirs.map { d in
                HFItem(id: d.path, title: d.path, size: sizeInName(d.path), downloads: nil, modelID: d.path)
            })
        case .ggml:
            let files = try await tree(whisperCppRepo).filter {
                $0.type == "file" && $0.path.hasPrefix("ggml-") && $0.path.hasSuffix(".bin")
            }
            return matching(query, files.map { f in
                let ref = HFFileRef(repo: whisperCppRepo, path: f.path)
                return HFItem(id: ref.id, title: (f.path as NSString).deletingPathExtension, size: f.bytes,
                              downloads: nil, modelID: ref.id)
            })
        }
    }

    /// The model files of a GGUF repo (no vision projectors, no multi-part files: llama.cpp in
    /// Mowa loads one file).
    static func ggufFiles(repo: String) async throws -> [HFItem] {
        try await tree(repo)
            .filter { e in
                let name = e.path.lowercased()
                return e.type == "file" && name.hasSuffix(".gguf") && !name.contains("mmproj")
                    && name.range(of: #"-\d{5}-of-\d{5}"#, options: .regularExpression) == nil
            }
            .map { e in
                let ref = HFFileRef(repo: repo, path: e.path)
                return HFItem(id: ref.id, title: ref.fileName, size: e.bytes, downloads: nil, modelID: ref.id)
            }
            .sorted { ($0.size ?? 0) < ($1.size ?? 0) }
    }

    /// The file Mowa suggests: Q4_K_M (the catalog's choice) when it fits this Mac's memory,
    /// otherwise the largest file that fits, otherwise the smallest.
    static func suggestedFile(_ files: [HFItem], ramGB: Int) -> HFItem? {
        let fits = files.filter { !needsMoreMemory($0.size, ramGB: ramGB) }
        return fits.first { $0.title.uppercased().contains("Q4_K_M") } ?? fits.last ?? files.first
    }

    /// Same rule of thumb as the catalog: a model needs ~1.2× its download in memory, and
    /// Mowa leaves the rest of the Mac's memory to the user's apps.
    static func needsMoreMemory(_ bytes: Int64?, ramGB: Int) -> Bool {
        guard let bytes, bytes > 0 else { return false }
        return Double(bytes) / 1e9 * 1.2 > Double(ramGB) * 0.65
    }

    /// WhisperKit's compressed variants carry their size in the name ("…_turbo_632MB").
    private static func sizeInName(_ name: String) -> Int64? {
        guard let r = name.range(of: #"_(\d+)MB$"#, options: .regularExpression) else { return nil }
        return Int64(name[r].dropFirst().dropLast(2)).map { $0 * 1_000_000 }
    }

    /// Repos with a fixed list (whisper folders and files) are filtered here: every word typed
    /// must appear in the name.
    private static func matching(_ query: String, _ items: [HFItem]) -> [HFItem] {
        let words = query.lowercased().split(whereSeparator: { $0 == " " }).map(String.init)
        guard !words.isEmpty else { return items }
        return items.filter { item in words.allSatisfy { item.title.lowercased().contains($0) } }
    }

    private static func models(_ query: String, author: String?, filter: String?, withSizes: Bool) async throws -> [Model] {
        var items = [
            URLQueryItem(name: "pipeline_tag", value: "text-generation"),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
        ]
        if let author { items.append(URLQueryItem(name: "author", value: author)) }
        if let filter { items.append(URLQueryItem(name: "filter", value: filter)) }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty { items.append(URLQueryItem(name: "search", value: q)) }
        do {
            var withExtras = items
            if withSizes {
                withExtras += [URLQueryItem(name: "expand[]", value: "downloads"),
                               URLQueryItem(name: "expand[]", value: "usedStorage")]
            }
            return try await get("models", withExtras)
        } catch is BadStatus where withSizes {
            // Sizes are an optional extra of the API; without them the list is still useful.
            return try await get("models", items)
        }
    }

    private static func tree(_ repo: String) async throws -> [TreeEntry] {
        try await get("models/\(repo)/tree/main", [])
    }

    private static func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var c = URLComponents(string: "https://huggingface.co/api/" + path)!
        if !query.isEmpty { c.queryItems = query }
        guard let url = c.url else { throw BadStatus() }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw BadStatus() }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Settings → Models → "Browse Hugging Face…": pick a model instead of typing its id.
struct HuggingFaceBrowser: View {
    let kind: HFBrowserKind
    let ram: Int
    /// Gets the Mowa model id (a catalog id when the pick is a catalog model).
    let onChoose: (String) -> Void
    @ObservedObject private var models = ModelManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [HFItem] = []
    @State private var loading = false
    @State private var failed = false
    @State private var picked: String?
    // GGUF: the files of the picked repo.
    @State private var files: [HFItem] = []
    @State private var pickedFile: String?
    @State private var loadingFiles = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(kind.title).font(.title2).fontWeight(.semibold)
            TextField("", text: $query, prompt: Text(kind.searchPrompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
            ZStack {
                List(results, selection: $picked) { item in row(item).tag(item.id) }
                if results.isEmpty {
                    if loading {
                        ProgressView()
                    } else {
                        Text(failed ? L("Couldn't reach Hugging Face. Check your internet connection.") : L("No models found."))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                    }
                }
            }
            .frame(minHeight: 260)
            if kind == .gguf, picked != nil { filePicker }
            Text(kind.footnote).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if !models.canAdd(kind.modelKind) {
                    Text(LF("You can add up to %d models. Delete one to add another.", ModelManager.maxAdded))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Add")) {
                    guard let id = chosenModelID else { return }
                    onChoose(id)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosenModelID.map { !canAdd($0) } ?? true)
            }
        }
        .padding(18)
        .frame(width: 560, height: kind == .gguf ? 580 : 540)
        .task(id: query) {
            // Ask Hugging Face once typing pauses, not on every key.
            if !query.isEmpty { try? await Task.sleep(nanoseconds: 400_000_000) }
            guard !Task.isCancelled else { return }
            await load()
        }
        .task(id: picked) {
            guard kind == .gguf else { return }
            await loadFiles()
        }
    }

    @ViewBuilder
    private var filePicker: some View {
        HStack(spacing: 8) {
            if loadingFiles {
                ProgressView().controlSize(.small)
                Text(L("Loading the model's files…")).font(.callout).foregroundStyle(.secondary)
            } else if files.isEmpty {
                Text(L("This model has no single GGUF file Mowa can use.")).font(.callout).foregroundStyle(.secondary)
            } else {
                Picker(L("File"), selection: $pickedFile) {
                    ForEach(files) { f in Text(fileLabel(f)).tag(Optional(f.id)) }
                }
            }
        }
    }

    /// The pick resolved to a Mowa model id: a catalog id when it is a catalog model.
    private var chosenModelID: String? {
        let id: String?
        if kind == .gguf {
            id = pickedFile
        } else {
            id = results.first { $0.id == picked }?.modelID
        }
        guard let id else { return nil }
        if let file = HFFileRef(id: id), let catalog = ModelCatalog.catalogID(for: file) { return catalog }
        return id
    }

    private func isListed(_ id: String) -> Bool {
        let resolved = HFFileRef(id: id).flatMap { ModelCatalog.catalogID(for: $0) } ?? id
        if models.added(kind.modelKind).contains(resolved) { return true }
        return kind.modelKind == .speech
            ? ModelCatalog.speechModel(id: resolved) != nil
            : ModelCatalog.cleanupModel(id: resolved) != nil
    }

    private func canAdd(_ id: String) -> Bool { isListed(id) || models.canAdd(kind.modelKind) }

    private func tooBig(_ size: Int64?) -> Bool {
        kind.modelKind == .cleanup && HFModelSearch.needsMoreMemory(size, ramGB: ram)
    }

    private func row(_ item: HFItem) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                let details = [
                    item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                    item.downloads.map { LF("%@ downloads", $0.formatted()) },
                ].compactMap { $0 }
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let id = item.modelID, isListed(id) {
                Text(L("Added")).font(.caption).foregroundStyle(.secondary)
            } else if tooBig(item.size) {
                Text(L("needs more memory")).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func fileLabel(_ f: HFItem) -> String {
        var label = f.title
        if let size = f.size { label += " — " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
        if isListed(f.id) { label += " — " + L("Added") } else if tooBig(f.size) { label += " — " + L("needs more memory") }
        return label
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let found = try await HFModelSearch.items(kind, query: query)
            guard !Task.isCancelled else { return }
            results = found
            failed = false
            if let picked, !found.contains(where: { $0.id == picked }) { self.picked = nil }
        } catch {
            guard !Task.isCancelled else { return }
            Log.error("Hugging Face search failed: \(error.localizedDescription)")
            results = []
            failed = true
        }
    }

    private func loadFiles() async {
        files = []
        pickedFile = nil
        guard let repo = picked else { return }
        loadingFiles = true
        defer { loadingFiles = false }
        do {
            let found = try await HFModelSearch.ggufFiles(repo: repo)
            guard !Task.isCancelled else { return }
            files = found
            pickedFile = HFModelSearch.suggestedFile(found, ramGB: ram)?.id
        } catch {
            guard !Task.isCancelled else { return }
            Log.error("Hugging Face files of \(repo) failed: \(error.localizedDescription)")
        }
    }
}
