import Foundation


public struct EngineConfig: Sendable {
    public var connections: Int
    public var verifySHA: Bool
    public var backoffBase: Double
    public var backoffMax: Double
    public var linkRetryDelay: Double

    public init(connections: Int = 4, verifySHA: Bool = true, backoffBase: Double = 2, backoffMax: Double = 60, linkRetryDelay: Double = 1) {
        self.connections = connections
        self.verifySHA = verifySHA
        self.backoffBase = backoffBase
        self.backoffMax = backoffMax
        self.linkRetryDelay = linkRetryDelay
    }

    public static let defaultChunkSize: Int64 = 8 << 20
}

/// One file. Loop: resolve fresh link → probe size → fetch missing chunks → repeat on any failure.
/// Only `fatal` errors or cancellation (= pause) stop it.
public actor DownloadEngine {
    public private(set) var state: JobState
    private let stateDir: URL
    private let resolver: Resolver
    private let makeFetcher: @Sendable () -> ChunkFetcher
    private let tokens: @Sendable () -> Tokens
    private let network: NetworkWatching
    private let config: EngineConfig
    private let onProgress: @Sendable (ProgressSnapshot) -> Void
    private let log = Log("engine")

    private var cycleTask: Task<Void, Error>?
    private var networkRestart = false
    private var progressed = false
    private var rangeFailures = 0
    private var phase: Phase = .queued
    private var speed = SpeedMeter()
    private var lastEmit = Date.distantPast

    public init(state: JobState, stateDir: URL = StateStore.directory, resolver: Resolver = RouterResolver(),
                makeFetcher: (@Sendable () -> ChunkFetcher)? = nil,
                tokens: @escaping @Sendable () -> Tokens = { Keychain.tokens() },
                network: NetworkWatching = NetworkMonitor.shared, config: EngineConfig = EngineConfig(),
                onProgress: @escaping @Sendable (ProgressSnapshot) -> Void = { _ in }) {
        self.state = state
        self.stateDir = stateDir
        self.resolver = resolver
        let lanes = config.connections
        self.makeFetcher = makeFetcher ?? { URLSessionFetcher(connections: lanes) }
        self.tokens = tokens
        self.network = network
        self.config = config
        self.onProgress = onProgress
    }

    // MARK: Run loop

    public func run() async -> JobState {
        let sub = network.subscribe { [weak self] in
            guard let engine = self else { return }
            Task { await engine.networkChanged() }
        }
        defer { network.unsubscribe(sub) }

        // Saved state is user-writable input: names must stay inside the chosen folder.
        guard state.namesAreSafe else { return fail(.unsafeFileName) }
        do {
            if try reconcileFinalizing() { emit(.done, force: true); return state }
        } catch { return fail(error as? DLError ?? .disk(error.localizedDescription)) }

        state.status = .active
        state.lastError = nil
        persist()
        var backoff = Backoff(base: config.backoffBase, max: config.backoffMax)

        // Outer loop: download → verify. A failed verify schedules a repair and downloads again.
        while true {
        while true {
            if Task.isCancelled { return pause() }
            if !network.isOnline {
                emit(.waitingNetwork, force: true)
                await network.waitUntilOnline()
                continue
            }

            let task = Task { try await self.cycle() }
            cycleTask = task
            do {
                try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                cycleTask = nil
                break // all chunks on disk
            } catch {
                cycleTask = nil
                if Task.isCancelled { return pause() }
                if progressed { backoff.reset(); rangeFailures = 0 }
                progressed = false

                let dl = error as? DLError
                if dl == .rangeNotSupported { rangeFailures += 1 }
                if let dl, dl.isFatal || rangeFailures >= 5 { return fail(dl) }

                let delay: Double
                if networkRestart { delay = config.linkRetryDelay }                    // VPN / Wi-Fi switch
                else if case .linkExpired = dl { delay = config.linkRetryDelay }      // just get a new link
                else { delay = backoff.next() }
                networkRestart = false

                let reason = Self.describe(error)
                log.info("retry job=\(self.state.id) delay=\(delay) reason=\(reason)")
                emit(.retrying(reason: reason, inSeconds: Int(delay.rounded(.up))), force: true)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }

        do {
            if try await finish() { return state }   // verified (or no hash available) and saved
        } catch {
            if Task.isCancelled { return pause() }
            return fail(error as? DLError ?? .disk(error.localizedDescription))
        }
        }
    }

    private func networkChanged() {
        guard let t = cycleTask else { return }
        log.info("network changed -> restart cycle job=\(self.state.id)")
        networkRestart = true
        t.cancel()
    }

    // MARK: Cycle

    private func cycle() async throws {
        emit(.resolving, force: true)
        // Our part file vanished (user deleted it): its name is no longer reserved → start this file over
        // under a freshly reserved name rather than re-creating a path another job may own now.
        if state.fileName != nil, let p = state.partURL, !FileManager.default.fileExists(atPath: p.path) {
            log.info("part file missing, re-reserving job=\(state.id) path=\(p.path)")
            state.reset()
            state.status = .active
        }
        guard var src = URL(string: state.sourceURL) else { throw DLError.unsupportedURL }
        // Retries fetch exactly the version we started with, never a newer `main`.
        if state.kind == .huggingface, let rev = state.revision, let p = HFResolver.pinned(src, revision: rev) { src = p }
        log.info("resolve job=\(state.id) src=\(src.absoluteString)")
        let target = try await resolver.resolve(src, tokens: tokens())
        log.info("resolved job=\(state.id) host=\(target.directURL.host ?? "-") sha=\(target.sha256 ?? "none") git=\(target.gitSHA1 ?? "none") rev=\(target.revision ?? "-")")
        try Task.checkCancellation()

        if state.fileName == nil {
            guard let safe = FileNames.safe(target.fileName) else { throw DLError.unsafeFileName }
            try reservePart(for: safe)
            try persistOrThrow()
        }
        // Same file or stop: a different hash means the server now has another version.
        if let s = target.sha256 {
            if let known = state.sha256, known != s { throw DLError.sourceChanged }
            state.sha256 = s
        }
        if let g = target.gitSHA1 {
            if let known = state.gitSHA1, known != g { throw DLError.sourceChanged }
            state.gitSHA1 = g
        }
        if state.revision == nil, let r = target.revision { state.revision = r }
        persist()

        let fetcher = makeFetcher()
        defer { fetcher.invalidate() }
        let total = try await fetcher.probe(target)
        log.info("probe job=\(state.id) size=\(total) done=\(state.doneBytes)")

        if let known = state.totalSize, known != total { throw DLError.sizeChanged(old: known, new: total) }
        let part = state.partURL!
        if state.totalSize == nil || !FileManager.default.fileExists(atPath: part.path) {
            state.totalSize = total
            state.doneBitmap = Data()
            state.partial = [:]
            state.chunkHashes = [:]
            try preparePart(part, size: total)
            persist()
        }

        emit(.downloading, force: true)
        try await fetchMissing(target, fetcher: fetcher, part: part)
    }

    private func fetchMissing(_ target: ResolvedTarget, fetcher: ChunkFetcher, part: URL) async throws {
        // Chunks fully written just before a pause/crash: mark done, with their hash read from disk.
        for (c, n) in state.partial where c >= state.chunkCount || isDone(c) || n >= Int64(state.range(of: c).count) {
            if c < state.chunkCount, !isDone(c) {
                do { state.chunkHashes[c] = try FileHash.sha256(of: part, range: state.range(of: c)) }
                catch { throw DLError.disk(error.localizedDescription) }
                state.markDone(c)
            }
            state.partial[c] = nil
        }
        let missing = state.missingChunks
        guard !missing.isEmpty else { return }

        let writer: PartWriter
        do {
            writer = try PartWriter(url: part, starts: Dictionary(uniqueKeysWithValues: missing.map { ($0, state.range(of: $0).lowerBound) }),
                                    partial: state.partial)
        } catch { throw DLError.disk(error.localizedDescription) }
        defer { writer.close() }

        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { break } // fetch finished while sleeping: file may already be renamed
                self.checkpoint(writer) // Task inherits actor isolation
            }
        }
        defer { ticker.cancel() }

        // Each request starts where the chunk's bytes on disk end.
        let jobs = missing.map { c -> (Int, ClosedRange<Int64>) in
            let r = state.range(of: c)
            return (c, (r.lowerBound + (state.partial[c] ?? 0))...r.upperBound)
        }
        do {
            try await withThrowingTaskGroup(of: Int.self) { group in
                var next = 0
                func addNext() {
                    guard next < jobs.count else { return }
                    let (idx, r) = jobs[next]
                    next += 1
                    group.addTask {
                        try await fetcher.fetch(target, range: r) { data in try writer.append(chunk: idx, data) }
                        return idx
                    }
                }
                for _ in 0..<max(1, config.connections) { addNext() }

                while let idx = try await group.next() {
                    try completeChunk(idx, writer: writer)
                    addNext()
                }
            }
        } catch {
            checkpoint(writer) // keep every byte that reached the disk before the drop
            throw error
        }
    }

    private func isDone(_ c: Int) -> Bool { state.isDone(c) }

    /// fsync first, then record. State never claims bytes that are not on disk.
    /// The chunk hash is read back FROM DISK, so it describes what was really stored.
    private func completeChunk(_ idx: Int, writer: PartWriter) throws {
        // Other lanes keep writing while this chunk is hashed. Only record counters
        // captured before the flush, never a newer snapshot taken after it.
        let snap = writer.snapshot()
        do {
            try writer.sync()
            state.chunkHashes[idx] = try FileHash.sha256(of: state.partURL!, range: state.range(of: idx))
        } catch { throw DLError.disk(error.localizedDescription) }
        writer.complete(idx)
        state.markDone(idx)
        state.partial = snap.filter { !state.isDone($0.key) }
        progressed = true
        persist()
        emit(.downloading)
    }

    private func checkpoint(_ writer: PartWriter) {
        let snap = writer.snapshot()          // snapshot BEFORE fsync -> everything counted is durable
        do { try writer.sync() } catch {
            log.error("fsync failed job=\(self.state.id) error=\(error.localizedDescription)")
            return
        }
        let filtered = snap.filter { !state.isDone($0.key) }
        if filtered.values.reduce(0, +) > state.partial.values.reduce(0, +) { progressed = true }
        state.partial = filtered
        persist()
        emit(.downloading)
    }

    // MARK: Finish

    /// Verify the WHOLE file against the source hash. The file gets its real name only if it matches.
    /// Mismatch → stage 1: re-download chunks whose bytes on disk changed → verify whole file again.
    ///          → stage 2: re-download everything → verify whole file again.
    ///          → still wrong: stop (hashMismatch). The .dlpart is never renamed.
    /// Returns true when saved, false when a repair download was scheduled.
    private func finish() async throws -> Bool {
        try Task.checkCancellation()
        let part = state.partURL!
        var verified = false
        if config.verifySHA, state.sha256 != nil || state.gitSHA1 != nil {
            emit(.verifying(fraction: 0), force: true)
            let snapshot = currentSnapshot
            let report = onProgress
            let useSHA256 = state.sha256 != nil
            // Off the actor: hashing 15+ GB takes a while.
            let hashing = Task.detached {
                if !useSHA256 { return try FileHash.gitBlobSHA1(of: part) }
                var last = Date.distantPast
                return try FileHash.sha256(of: part) { f in
                    guard Date().timeIntervalSince(last) > 0.25 else { return }
                    last = Date()
                    var s = snapshot; s.phase = .verifying(fraction: f); report(s)
                }
            }
            let actual = try await withTaskCancellationHandler {
                try await hashing.value
            } onCancel: { hashing.cancel() }
            try Task.checkCancellation()
            let expected = useSHA256 ? state.sha256! : state.gitSHA1!
            if actual != expected {
                log.error("hash mismatch job=\(self.state.id) stage=\(self.state.repairStage) want=\(expected) got=\(actual)")
                try await scheduleRepair()
                return false
            }
            verified = true
        }
        try Task.checkCancellation()
        if state.partFileName == nil { state.partFileName = part.lastPathComponent } // part path must not follow fileName changes
        let dest = try publish(part, verified: verified)
        state.status = .done
        state.finalizing = false
        try persistOrThrow()
        emit(.done, force: true)
        log.info("done job=\(self.state.id) verified=\(verified) file=\(dest.path)")
        return true
    }

    /// Give the part its final name without ever replacing an existing file.
    /// Each attempt first records the intended name durably (finalizing = true), then hard-links
    /// part → final (fails atomically if the name is taken), then removes the part name.
    /// A crash anywhere in here is completed by `reconcileFinalizing()` on the next run.
    private func publish(_ part: URL, verified: Bool) throws -> URL {
        let dir = URL(fileURLWithPath: state.destDir)
        let wanted = state.fileName!
        for i in 0..<1000 {
            let name = Self.numbered(wanted, i)
            let dest = dir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: dest.path) { continue }
            state.fileName = name
            state.verified = verified
            state.finalizing = true
            try persistOrThrow()
            if link(part.path, dest.path) == 0 {
                unlink(part.path)
            } else if errno == EEXIST {
                continue                               // someone took the name since our check
            } else if [EPERM, ENOTSUP, EOPNOTSUPP, EMLINK, EXDEV].contains(errno) {
                // File system without hard links (exFAT/FAT external drives): rename that refuses to replace.
                try Self.renameNoReplace(part, dest)
            } else {
                throw DLError.disk("link failed: \(String(cString: strerror(errno)))")
            }
            StateStore.syncDirectory(dir)
            return dest
        }
        throw DLError.disk("no free file name for \(wanted)")
    }

    /// Restart after a crash during `publish`: finish the rename instead of downloading again.
    /// Returns true if the job is now done.
    private func reconcileFinalizing() throws -> Bool {
        guard state.finalizing, let part = state.partURL, let final = state.finalURL else { return false }
        let fm = FileManager.default
        let partExists = fm.fileExists(atPath: part.path)
        let finalExists = fm.fileExists(atPath: final.path)
        if finalExists && (!partExists || Self.sameFile(part, final)) {
            if partExists { unlink(part.path) }
            state.status = .done
            state.finalizing = false
            try persistOrThrow()
            log.info("reconciled interrupted finalize job=\(state.id) file=\(final.path)")
            return true
        }
        // Rename never happened (or final name belongs to another file): verify + publish again.
        state.finalizing = false
        try persistOrThrow()
        return false
    }

    private static func renameNoReplace(_ from: URL, _ to: URL) throws {
        #if os(macOS)
        if renamex_np(from.path, to.path, UInt32(RENAME_EXCL)) != 0 {
            throw DLError.disk("rename failed: \(String(cString: strerror(errno)))")
        }
        #else
        // Linux fallback: no portable no-replace rename in Glibc's Swift overlay; check then rename (small race window).
        if FileManager.default.fileExists(atPath: to.path) { throw DLError.disk("target appeared: \(to.lastPathComponent)") }
        if rename(from.path, to.path) != 0 { throw DLError.disk("rename failed: \(String(cString: strerror(errno)))") }
        #endif
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        var sa = stat(), sb = stat()
        guard stat(a.path, &sa) == 0, stat(b.path, &sb) == 0 else { return false }
        return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino
    }

    /// "a.bin", 0 → "a.bin"; "a.bin", 2 → "a (2).bin"
    static func numbered(_ name: String, _ i: Int) -> String {
        guard i > 0 else { return name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
    }

    private func scheduleRepair() async throws {
        if state.repairStage == 0 {
            // Which finished chunks no longer match the hash recorded when they were written?
            let part = state.partURL!
            let snapshot = state
            let hashing = Task.detached { () -> [Int] in
                try (0..<snapshot.chunkCount).filter { c in
                    try Task.checkCancellation()
                    guard let recorded = snapshot.chunkHashes[c] else { return true }
                    return try FileHash.sha256(of: part, range: snapshot.range(of: c)) != recorded
                }
            }
            let damaged = try await withTaskCancellationHandler {
                try await hashing.value
            } onCancel: { hashing.cancel() }
            try Task.checkCancellation()
            state.repairStage = 1
            if !damaged.isEmpty {
                redownload(damaged)
                let msg = "Hash check failed. Re-downloading \(damaged.count) damaged part(s), then checking the whole file again."
                log.info("repair stage=1 job=\(state.id) chunks=\(damaged)")
                emit(.retrying(reason: msg, inSeconds: 0), force: true)
                return
            }
            // All chunks are as written: wrong bytes arrived. Only a full re-download can fix that.
        }
        if state.repairStage <= 1 {
            state.repairStage = 2
            redownload(Array(0..<state.chunkCount))
            log.info("repair stage=2 job=\(state.id) full re-download")
            emit(.retrying(reason: "Hash check failed. Downloading the whole file again, then checking it again.", inSeconds: 0), force: true)
            return
        }
        throw DLError.hashMismatch
    }

    private func redownload(_ chunks: [Int]) {
        var bitmap = Data(count: state.doneBitmap.count)
        let drop = Set(chunks)
        for c in 0..<state.chunkCount where state.isDone(c) && !drop.contains(c) {
            bitmap[c / 8] |= (1 << UInt8(c % 8))
        }
        state.doneBitmap = bitmap
        for c in chunks { state.partial[c] = nil; state.chunkHashes[c] = nil }
        persist()
    }

    // MARK: Helpers

    private func pause() -> JobState {
        state.status = .paused
        persist()
        emit(.paused, force: true)
        return state
    }

    private func fail(_ e: DLError) -> JobState {
        state.status = .failed
        state.lastError = e.errorDescription
        persist()
        emit(.failed(e.errorDescription ?? "Error"), force: true)
        log.error("failed job=\(self.state.id) error=\(e.errorDescription ?? "")")
        return state
    }

    private func preparePart(_ url: URL, size: Int64) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            let h = try FileHandle(forWritingTo: url)
            defer { try? h.close() }
            try h.truncate(atOffset: UInt64(size)) // sparse on APFS: no real disk use until written
        } catch { throw DLError.disk(error.localizedDescription) }
    }

    /// Pick a free name and create its part file with O_CREAT|O_EXCL, so two jobs (in this or another
    /// process) can never share a part file, even if both chose the same name at the same moment.
    private func reservePart(for safeName: String) throws {
        let dir = URL(fileURLWithPath: state.destDir)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { throw DLError.disk(error.localizedDescription) }
        for i in 0..<1000 {
            let name = Self.numbered(safeName, i)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) { continue }
            let partName = name + ".dlpart"
            let fd = open(dir.appendingPathComponent(partName).path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd < 0 {
                if errno == EEXIST { continue }
                throw DLError.disk("cannot create part file: \(String(cString: strerror(errno)))")
            }
            close(fd)
            state.fileName = name
            state.partFileName = partName
            return
        }
        throw DLError.disk("no free file name for \(safeName)")
    }

    private func persist() {
        do { try StateStore.save(state, in: stateDir) }
        catch { log.error("state save failed job=\(self.state.id) error=\(error.localizedDescription)") }
    }

    /// For transitions that must not be lost (name reserved, finalize intent, done): fail loudly.
    private func persistOrThrow() throws {
        do { try StateStore.save(state, in: stateDir, durable: true) }
        catch { throw DLError.disk("cannot save job state: \(error.localizedDescription)") }
    }

    private var currentSnapshot: ProgressSnapshot {
        ProgressSnapshot(phase: phase, fileName: state.fileName, totalBytes: state.totalSize,
                         doneBytes: state.doneBytes, bytesPerSecond: speed.bytesPerSecond)
    }

    private func emit(_ p: Phase, force: Bool = false) {
        if p != .downloading { speed.reset() } else { speed.add(state.doneBytes) }
        let changed = p != phase
        phase = p
        guard force || changed || Date().timeIntervalSince(lastEmit) > 0.25 else { return }
        lastEmit = Date()
        onProgress(currentSnapshot)
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? DLError { return e.errorDescription ?? "\(e)" }
        if error is CancellationError { return "Network changed. Reconnecting." }
        if let u = error as? URLError {
            switch u.code {
            case .cancelled: return "Network changed. Reconnecting."
            case .timedOut: return "Connection stalled."
            case .notConnectedToInternet, .networkConnectionLost: return "Connection lost."
            case .cannotFindHost, .dnsLookupFailed: return "DNS failed."
            default: return "Network error (\(u.code.rawValue))."
            }
        }
        return error.localizedDescription
    }
}
