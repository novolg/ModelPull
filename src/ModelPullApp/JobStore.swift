import AppKit
import DLCore
import os

@MainActor
final class JobItem: ObservableObject, Identifiable {
    let id: UUID
    @Published var state: JobState
    @Published var progress: ProgressSnapshot
    var task: Task<Void, Never>?
    var runID: UUID?

    init(_ state: JobState) {
        id = state.id
        self.state = state
        let phase: Phase
        switch state.status {
        case .active: phase = .queued
        case .paused: phase = .paused
        case .done: phase = .done
        case .failed: phase = .failed(state.lastError ?? "Failed")
        }
        progress = ProgressSnapshot(phase: phase, fileName: state.fileName, totalBytes: state.totalSize,
                                    doneBytes: state.status == .done ? (state.totalSize ?? 0) : state.doneBytes, bytesPerSecond: 0)
    }

    var displayName: String { progress.fileName ?? state.fileName ?? state.sourceURL }
}

enum Prefs {
    static let connections = "connections"
    static let maxActive = "maxActive"
    static let verifySHA = "verifySHA"
    static let keepAwake = "keepAwake"
    static let saveDir = "saveDir"

    static func register() {
        UserDefaults.standard.register(defaults: [
            connections: 4, maxActive: 1, verifySHA: true, keepAwake: true,
            saveDir: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path,
        ])
    }
}

@MainActor
final class JobStore: ObservableObject {
    @Published private(set) var jobs: [JobItem] = []
    private var sleepActivity: NSObjectProtocol?
    private let log = Logger(subsystem: AppIdentity.id, category: "store")
    private let defaults = UserDefaults.standard

    init() {
        LegacyData.migrate()
        Prefs.register()
        jobs = StateStore.loadAll().map(JobItem.init)
        pump()
    }

    // MARK: Actions

    /// Returns an error message for the UI, nil on success.
    func add(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let kind = SourceParser.kind(of: url) else {
            return "Paste a Hugging Face file link (…/resolve/… or …/blob/…) or a Civitai model link."
        }
        if jobs.contains(where: { $0.state.sourceURL == trimmed && $0.state.status != .done }) {
            return "This link is already in the list."
        }
        let state = JobState(sourceURL: trimmed, kind: kind, destDir: defaults.string(forKey: Prefs.saveDir)!,
                             chunkSize: EngineConfig.defaultChunkSize)
        do { try StateStore.save(state) } catch { return "Cannot save job: \(error.localizedDescription)" }
        jobs.insert(JobItem(state), at: 0)
        pump()
        return nil
    }

    func pause(_ job: JobItem) {
        if let t = job.task { t.cancel() } else { setStatus(job, .paused, phase: .paused) }
    }

    func resume(_ job: JobItem) {
        setStatus(job, .active, phase: .queued)
        pump()
    }

    func restartFromZero(_ job: JobItem) {
        Task {
            await stop(job)
            if let part = job.state.partURL { try? FileManager.default.removeItem(at: part) }
            job.state.reset()
            job.progress = ProgressSnapshot(phase: .queued, fileName: job.state.fileName, totalBytes: nil, doneBytes: 0, bytesPerSecond: 0)
            try? StateStore.save(job.state)
            pump()
        }
    }

    func remove(_ job: JobItem, deleteFile: Bool) {
        Task {
            await stop(job)
            if let part = job.state.partURL { try? FileManager.default.removeItem(at: part) }
            if deleteFile, job.state.status == .done, let f = job.state.finalURL { try? FileManager.default.removeItem(at: f) }
            StateStore.delete(job.id)
            jobs.removeAll { $0.id == job.id }
            pump()
        }
    }

    func reveal(_ job: JobItem) {
        let url = job.state.status == .done ? job.state.finalURL : job.state.partURL
        if let url, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: job.state.destDir))
        }
    }

    // MARK: Scheduling

    /// Start queued jobs up to the simultaneous-downloads limit.
    private func pump() {
        let limit = max(1, defaults.integer(forKey: Prefs.maxActive))
        var running = jobs.filter { $0.task != nil }.count
        for job in jobs.reversed() where job.task == nil && job.state.status == .active && running < limit {
            start(job)
            running += 1
        }
        updateKeepAwake()
    }

    private func start(_ job: JobItem) {
        let config = EngineConfig(connections: max(1, defaults.integer(forKey: Prefs.connections)),
                                  verifySHA: defaults.bool(forKey: Prefs.verifySHA))
        let runID = UUID()
        job.runID = runID
        let engine = DownloadEngine(state: job.state, config: config) { snap in
            Task { @MainActor in
                guard job.runID == runID else { return }
                job.progress = snap
            }
        }
        log.info("start job=\(job.id, privacy: .public)")
        job.task = Task {
            let final = await engine.run()
            job.runID = nil
            job.state = final
            job.progress = JobItem(final).progress
            job.task = nil
            pump()
        }
    }

    private func stop(_ job: JobItem) async {
        guard let t = job.task else { return }
        t.cancel()
        await t.value
    }

    private func setStatus(_ job: JobItem, _ status: JobState.Status, phase: Phase) {
        job.state.status = status
        job.state.lastError = nil
        job.progress.phase = phase
        do { try StateStore.save(job.state) }
        catch { log.error("save failed job=\(job.id, privacy: .public) error=\(error.localizedDescription, privacy: .public)") }
    }

    private func updateKeepAwake() {
        let busy = jobs.contains { $0.task != nil } && defaults.bool(forKey: Prefs.keepAwake)
        if busy, sleepActivity == nil {
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                                  reason: "Downloading files")
        } else if !busy, let a = sleepActivity {
            ProcessInfo.processInfo.endActivity(a)
            sleepActivity = nil
        }
    }
}
