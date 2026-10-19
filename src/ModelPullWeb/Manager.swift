import Foundation
import DLCore

/// Web-side job scheduler. Same rules as the macOS JobStore: persisted states, N downloads at once, keep awake.
actor Manager {
    struct Settings: Codable {
        var connections = 4
        var maxActive = 1
        var verifySHA = true
        var keepAwake = true
        var saveDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads").path
    }

    struct JobDTO: Encodable {
        let id: String, name: String, kind: String, url: String, status: String, phase: String, text: String
        let done: Int64, total: Int64?, speed: Double, fraction: Double, hasSHA: Bool
    }
    struct StateDTO: Encodable {
        let jobs: [JobDTO]
        let settings: Settings
        let tokens: [String: Bool]
        let online: Bool
    }
    struct DirsDTO: Encodable { let path: String; let parent: String?; let dirs: [String] }

    private var order: [UUID] = []                 // newest first
    private var states: [UUID: JobState] = [:]
    private var progress: [UUID: ProgressSnapshot] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private(set) var settings = Settings()
    private let awake = KeepAwake()
    private let log = Log("manager")

    static var settingsFile: URL { AppConfig.directory.appendingPathComponent("settings.json") }

    func load() {
        if let d = try? Data(contentsOf: Self.settingsFile), let s = try? JSONDecoder().decode(Settings.self, from: d) { settings = s }
        for s in StateStore.loadAll().reversed() {
            order.append(s.id)
            states[s.id] = s
            progress[s.id] = Self.initialProgress(s)
        }
        pump()
    }

    // MARK: Queries

    func snapshot() -> StateDTO {
        let tokens = Keychain.tokens()
        let jobs = order.compactMap { id -> JobDTO? in
            guard let s = states[id], let p = progress[id] else { return nil }
            let (phase, text) = Self.describe(p.phase, doneLabel: s.doneLabel)
            var fraction = 0.0
            if case .verifying(let f) = p.phase { fraction = f }
            else if let t = p.totalBytes, t > 0 { fraction = Double(p.doneBytes) / Double(t) }
            return JobDTO(id: id.uuidString, name: p.fileName ?? s.fileName ?? s.sourceURL, kind: s.kind.label, url: s.sourceURL,
                          status: s.status.rawValue, phase: phase, text: text, done: p.doneBytes, total: p.totalBytes,
                          speed: p.bytesPerSecond, fraction: fraction, hasSHA: s.sha256 != nil)
        }
        return StateDTO(jobs: jobs, settings: settings,
                        tokens: ["huggingface": !(tokens.huggingface ?? "").isEmpty, "civitai": !(tokens.civitai ?? "").isEmpty],
                        online: NetworkMonitor.shared.isOnline)
    }

    nonisolated func dirs(_ path: String) -> DirsDTO? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        let dirs = items.filter { !$0.lastPathComponent.hasPrefix(".") && ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) == true }
            .map(\.lastPathComponent).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return DirsDTO(path: url.path, parent: url.path == "/" ? nil : url.deletingLastPathComponent().path, dirs: dirs)
    }

    // MARK: Actions

    func add(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let kind = SourceParser.kind(of: url) else {
            return "Paste a Hugging Face file link (…/resolve/… or …/blob/…) or a Civitai model link."
        }
        if states.values.contains(where: { $0.sourceURL == trimmed && $0.status != .done }) { return "This link is already in the list." }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: settings.saveDir, isDirectory: &isDir), isDir.boolValue else {
            return "Save folder does not exist: \(settings.saveDir)"
        }
        let s = JobState(sourceURL: trimmed, kind: kind, destDir: settings.saveDir, chunkSize: EngineConfig.defaultChunkSize)
        do { try StateStore.save(s) } catch { return "Cannot save job: \(error.localizedDescription)" }
        order.insert(s.id, at: 0)
        states[s.id] = s
        progress[s.id] = Self.initialProgress(s)
        pump()
        return nil
    }

    func pause(_ id: UUID) {
        if let t = tasks[id] { t.cancel() } else { setStatus(id, .paused, .paused) }
    }

    func resume(_ id: UUID) {
        setStatus(id, .active, .queued)
        pump()
    }

    func restart(_ id: UUID) async {
        await stop(id)
        guard var s = states[id] else { return }
        if let part = s.partURL { try? FileManager.default.removeItem(at: part) }
        s.reset()
        states[id] = s
        progress[id] = Self.initialProgress(s)
        try? StateStore.save(s)
        pump()
    }

    func remove(_ id: UUID, deleteFile: Bool) async {
        await stop(id)
        guard let s = states[id] else { return }
        if let part = s.partURL { try? FileManager.default.removeItem(at: part) }
        if deleteFile, s.status == .done, let f = s.finalURL { try? FileManager.default.removeItem(at: f) }
        StateStore.delete(id)
        order.removeAll { $0 == id }
        states[id] = nil
        progress[id] = nil
        pump()
    }

    func revealPath(_ id: UUID) -> String? { states[id]?.destDir }

    func update(settings new: Settings) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: new.saveDir, isDirectory: &isDir), isDir.boolValue else { return "Folder does not exist." }
        settings = new
        settings.connections = min(16, max(1, new.connections))
        settings.maxActive = min(5, max(1, new.maxActive))
        do {
            try FileManager.default.createDirectory(at: Self.settingsFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: Self.settingsFile, options: .atomic)
        } catch {
            log.error("settings save failed error=\(error.localizedDescription)")
            return "Cannot save settings: \(error.localizedDescription)"
        }
        pump()
        return nil
    }

    // MARK: Engine plumbing

    private func pump() {
        var running = tasks.count
        for id in order.reversed() where tasks[id] == nil && states[id]?.status == .active && running < settings.maxActive {
            start(id)
            running += 1
        }
        awake.set(settings.keepAwake && !tasks.isEmpty)
    }

    private func start(_ id: UUID) {
        guard let s = states[id] else { return }
        let engine = DownloadEngine(state: s, config: EngineConfig(connections: settings.connections, verifySHA: settings.verifySHA)) { [weak self] snap in
            guard let self else { return }
            Task { await self.report(id, snap) }
        }
        log.info("start job=\(id)")
        tasks[id] = Task {
            let final = await engine.run()
            self.finished(id, final)
        }
    }

    private func report(_ id: UUID, _ snap: ProgressSnapshot) {
        guard tasks[id] != nil else { return } // late event after finish
        progress[id] = snap
    }

    private func finished(_ id: UUID, _ final: JobState) {
        tasks[id] = nil
        guard states[id] != nil else { return }
        states[id] = final
        var p = Self.initialProgress(final)
        p.bytesPerSecond = 0
        progress[id] = p
        pump()
    }

    private func stop(_ id: UUID) async {
        guard let t = tasks[id] else { return }
        t.cancel()
        await t.value
    }

    private func setStatus(_ id: UUID, _ status: JobState.Status, _ phase: Phase) {
        guard var s = states[id] else { return }
        s.status = status
        s.lastError = nil
        states[id] = s
        progress[id]?.phase = phase
        do { try StateStore.save(s) } catch { log.error("save failed job=\(id) error=\(error.localizedDescription)") }
    }

    static func initialProgress(_ s: JobState) -> ProgressSnapshot {
        let phase: Phase
        switch s.status {
        case .active: phase = .queued
        case .paused: phase = .paused
        case .done: phase = .done
        case .failed: phase = .failed(s.lastError ?? "Failed")
        }
        return ProgressSnapshot(phase: phase, fileName: s.fileName, totalBytes: s.totalSize,
                                doneBytes: s.status == .done ? (s.totalSize ?? 0) : s.doneBytes, bytesPerSecond: 0)
    }

    static func describe(_ p: Phase, doneLabel: String) -> (String, String) {
        switch p {
        case .queued: return ("queued", "Queued")
        case .resolving: return ("resolving", "Getting a fresh download link…")
        case .downloading: return ("downloading", "Downloading")
        case .waitingNetwork: return ("waiting", "No network. Waiting…")
        case .retrying(let r, let s): return ("retrying", "\(r) Retry in \(s) s.")
        case .verifying(let f): return ("verifying", "Checking SHA256… \(Int(f * 100))%")
        case .paused: return ("paused", "Paused")
        case .done: return ("done", doneLabel)
        case .failed(let m): return ("failed", m)
        }
    }
}

/// Blocks system idle sleep while downloads run. Linux: systemd-inhibit. macOS: caffeinate.
final class KeepAwake: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func set(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        if on, process == nil {
            let p = Process()
            #if os(Linux)
            p.executableURL = URL(fileURLWithPath: "/usr/bin/systemd-inhibit")
            // tail --pid exits when we die (even on crash) -> inhibitor never outlives the app.
            p.arguments = ["--what=idle:sleep", "--who=ModelPull", "--why=Downloading files", "--mode=block",
                           "tail", "--pid=\(getpid())", "-f", "/dev/null"]
            #else
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-i", "-w", "\(getpid())"]
            #endif
            do { try p.run(); process = p } catch { Log("awake").error("keep-awake failed error=\(error.localizedDescription)") }
        } else if !on, let p = process {
            p.terminate()
            process = nil
        }
    }
}
