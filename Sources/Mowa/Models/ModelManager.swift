import Foundation
import MowaCore

/// Download state of every model in the catalog (plus custom model ids the user
/// typed in), observed by the Models settings tab and onboarding.
@MainActor
final class ModelManager: ObservableObject {
    static let shared = ModelManager()

    enum Kind { case speech, cleanup }

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case failed(String)
    }

    @Published private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private var lastProgress: [String: (value: Double, at: Date)] = [:]
    static let stallTimeout: TimeInterval = 90
    static let maxAttempts = 6

    private init() {
        addedSpeech = Self.loadAdded(.speech)
        addedCleanup = Self.loadAdded(.cleanup)
        refresh()
    }

    func refresh() {
        for m in ModelCatalog.speechModels { refresh(m.id, kind: .speech) }
        for m in ModelCatalog.cleanupModels { refresh(m.id, kind: .cleanup) }
        for id in addedSpeech { refresh(id, kind: .speech) }
        for id in addedCleanup { refresh(id, kind: .cleanup) }
        let s = AppSettings.shared
        if !s.cleanupModelID.isEmpty, s.cleanupModelID != RemoteLLM.selectionID { refresh(s.cleanupModelID, kind: .cleanup) }
        if !s.speechModelID.isEmpty { refresh(s.speechModelID, kind: .speech) }
    }

    private func refresh(_ id: String, kind: Kind) {
        if case .downloading = states[id] { return }
        states[id] = isDownloaded(id, kind: kind) ? .downloaded : .notDownloaded
    }

    func isDownloaded(_ id: String, kind: Kind) -> Bool {
        switch kind {
        case .speech: return Transcriber.isDownloaded(id)
        case .cleanup: return LLMEngine.isDownloaded(id)
        }
    }

    func state(_ id: String) -> State { states[id] ?? .notDownloaded }

    var anyDownloading: Bool {
        states.values.contains { if case .downloading = $0 { return true } else { return false } }
    }

    /// Starts (or joins) a download. Calls `completion` on the main actor.
    func download(_ id: String, kind: Kind, completion: ((Bool) -> Void)? = nil) {
        guard tasks[id] == nil else { return }
        if isDownloaded(id, kind: kind) {
            states[id] = .downloaded
            completion?(true)
            return
        }
        states[id] = .downloading(0)
        Log.info("Downloading \(id)")
        lastProgress[id] = (0, Date())
        tasks[id] = Task { [weak self] in
            let progress: @Sendable (Double) -> Void = { value in
                Task { @MainActor in
                    guard let self, case .downloading = self.states[id] else { return }
                    let v = min(max(value, 0), 1)
                    if v > (self.lastProgress[id]?.value ?? -1) { self.lastProgress[id] = (v, Date()) }
                    self.states[id] = .downloading(v)
                }
            }
            var ok = false
            var lastError: Error?
            // A stalled connection (no new bytes for `stallTimeout`) is cancelled and
            // retried. Finished files are kept and partial ones resume, so a retry
            // continues roughly where it stopped.
            for attempt in 1...Self.maxAttempts {
                if Task.isCancelled { break }
                await MainActor.run { self?.lastProgress[id] = (self?.lastProgress[id]?.value ?? 0, Date()) }
                let job = Task {
                    switch kind {
                    case .speech: try await Transcriber.download(id, progress: progress)
                    case .cleanup: try await LLMEngine.download(id, progress: progress)
                    }
                }
                let watchdog = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
                        guard let self, let last = self.lastProgress[id] else { return }
                        if Date().timeIntervalSince(last.at) > Self.stallTimeout {
                            Log.error("Download of \(id) stalled at \(Int(last.value * 100))% — retrying")
                            job.cancel()
                            return
                        }
                    }
                }
                do {
                    // Cancelling the download (✕) cancels the running attempt too.
                    try await withTaskCancellationHandler {
                        try await job.value
                    } onCancel: {
                        job.cancel()
                    }
                    watchdog.cancel()
                    ok = true
                    break
                } catch {
                    watchdog.cancel()
                    lastError = error
                    if Task.isCancelled { break }   // the user cancelled
                    Log.error("Download of \(id) attempt \(attempt) failed: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(min(attempt * 3, 15)) * 1_000_000_000)
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.tasks[id] = nil
                self.lastProgress[id] = nil
                if ok {
                    self.states[id] = .downloaded
                } else if case .downloading = self.states[id] {
                    self.states[id] = .failed(lastError?.localizedDescription ?? L("Download failed."))
                }
                completion?(ok)
            }
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        states[id] = .notDownloaded
    }

    func delete(_ id: String, kind: Kind) {
        do {
            switch kind {
            case .speech: try Transcriber.delete(id)
            case .cleanup: try LLMEngine.delete(id)
            }
        } catch {
            Log.error("Deleting \(id) failed: \(error.localizedDescription)")
        }
        states[id] = .notDownloaded
        removeAdded(id, kind: kind)
    }

    // MARK: Added models

    /// Models the user added with "Add existing Model" (a folder or file on this Mac) or typed in
    /// (a Hugging Face id), oldest first. They stay listed when another model is selected and
    /// leave the list only through their delete button.
    static let maxAdded = 5
    @Published private(set) var addedSpeech: [String] = []
    @Published private(set) var addedCleanup: [String] = []

    func added(_ kind: Kind) -> [String] { kind == .speech ? addedSpeech : addedCleanup }
    func canAdd(_ kind: Kind) -> Bool { added(kind).count < Self.maxAdded }

    /// false when the list is full (the id is not added).
    @discardableResult
    func add(_ id: String, kind: Kind) -> Bool {
        var ids = added(kind)
        if ids.contains(id) { return true }
        guard ids.count < Self.maxAdded else { return false }
        ids.append(id)
        setAdded(ids, kind: kind)
        refresh(id, kind: kind)
        return true
    }

    func removeAdded(_ id: String, kind: Kind) {
        let ids = added(kind)
        guard ids.contains(id) else { return }
        setAdded(ids.filter { $0 != id }, kind: kind)
    }

    private func setAdded(_ ids: [String], kind: Kind) {
        if kind == .speech { addedSpeech = ids } else { addedCleanup = ids }
        UserDefaults.standard.set(ids, forKey: Self.addedKey(kind))
    }

    private static func addedKey(_ kind: Kind) -> String {
        kind == .speech ? "addedSpeechModelIDs" : "addedCleanupModelIDs"
    }

    /// Before this list existed only the selected custom model was shown (and vanished once
    /// another was picked): start the list from that model and from the speech folders Mowa knows.
    private static func loadAdded(_ kind: Kind) -> [String] {
        if let ids = UserDefaults.standard.stringArray(forKey: addedKey(kind)) { return ids }
        let s = AppSettings.shared
        var ids: [String] = []
        switch kind {
        case .speech:
            ids = LocalModels.knownSpeechIDs()
            let current = s.speechModelID
            if !current.isEmpty, !ModelCatalog.speechModels.contains(where: { $0.id == current }), !ids.contains(current) {
                ids.append(current)
            }
        case .cleanup:
            let current = s.cleanupModelID
            if !current.isEmpty, current != RemoteLLM.selectionID, ModelCatalog.cleanupModel(id: current) == nil {
                ids.append(current)
            }
        }
        ids = Array(ids.prefix(maxAdded))
        UserDefaults.standard.set(ids, forKey: addedKey(kind))
        return ids
    }

    /// Bytes used by downloaded models.
    nonisolated static func diskUsage() -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for root in [AppPaths.speechModels, AppPaths.cleanupModels] {
            guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]) else { continue }
            for case let url as URL in e {
                let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
                if v?.isSymbolicLink == true { continue }
                total += Int64(v?.totalFileAllocatedSize ?? 0)
            }
        }
        return total
    }
}
