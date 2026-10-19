import Foundation

/// Persistent per-job state. Written atomically after every finished chunk,
/// so a crash / Ctrl+Q / power loss never loses more than in-flight chunks.
public struct JobState: Codable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable { case active, paused, done, failed }

    public var id: UUID
    public var sourceURL: String
    public var kind: SourceKind
    public var destDir: String
    public var fileName: String?
    public var totalSize: Int64?
    public var sha256: String?
    public var chunkSize: Int64
    public var doneBitmap: Data
    /// Bytes already on disk from the start of each unfinished chunk. Lets a slow link resume mid-chunk.
    public var partial: [Int: Int64]
    public var status: Status
    public var lastError: String?
    public var addedAt: Date

    // Integrity (all optional in JSON so state files from older versions still load)
    /// HF commit pinned on first resolve: retries download exactly this version, never a newer `main`.
    public var revision: String?
    /// Git blob SHA1 for small HF files that have no SHA256.
    public var gitSHA1: String?
    /// SHA256 of each finished chunk, read back from disk. Finds damaged chunks if the full-file hash fails.
    public var chunkHashes: [Int: String]
    /// 0 = none, 1 = damaged chunks re-downloaded, 2 = whole file re-downloaded. Mismatch at 2 = stop.
    public var repairStage: Int
    /// After done: true = hash matched the source, false = source gave no hash (or check was off).
    public var verified: Bool?
    /// Name of the reserved part file (created with O_EXCL). nil in old states → "<fileName>.dlpart".
    public var partFileName: String?
    /// Durable intent: part verified, about to be renamed to `fileName`. Lets a restart finish the
    /// rename instead of downloading again if the app died between rename and saving "done".
    public var finalizing: Bool

    public init(id: UUID = UUID(), sourceURL: String, kind: SourceKind, destDir: String, chunkSize: Int64) {
        self.id = id
        self.sourceURL = sourceURL
        self.kind = kind
        self.destDir = destDir
        self.chunkSize = chunkSize
        self.doneBitmap = Data()
        self.partial = [:]
        self.status = .active
        self.addedAt = Date()
        self.chunkHashes = [:]
        self.repairStage = 0
        self.finalizing = false
    }

    enum CodingKeys: String, CodingKey {
        case id, sourceURL, kind, destDir, fileName, totalSize, sha256, chunkSize, doneBitmap, partial, status, lastError, addedAt
        case revision, gitSHA1, chunkHashes, repairStage, verified, partFileName, finalizing
    }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        sourceURL = try c.decode(String.self, forKey: .sourceURL)
        kind = try c.decode(SourceKind.self, forKey: .kind)
        destDir = try c.decode(String.self, forKey: .destDir)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        totalSize = try c.decodeIfPresent(Int64.self, forKey: .totalSize)
        sha256 = try c.decodeIfPresent(String.self, forKey: .sha256)
        chunkSize = try c.decode(Int64.self, forKey: .chunkSize)
        doneBitmap = try c.decodeIfPresent(Data.self, forKey: .doneBitmap) ?? Data()
        partial = try c.decodeIfPresent([Int: Int64].self, forKey: .partial) ?? [:]
        status = try c.decode(Status.self, forKey: .status)
        lastError = try c.decodeIfPresent(String.self, forKey: .lastError)
        addedAt = try c.decode(Date.self, forKey: .addedAt)
        revision = try c.decodeIfPresent(String.self, forKey: .revision)
        gitSHA1 = try c.decodeIfPresent(String.self, forKey: .gitSHA1)
        chunkHashes = try c.decodeIfPresent([Int: String].self, forKey: .chunkHashes) ?? [:]
        repairStage = try c.decodeIfPresent(Int.self, forKey: .repairStage) ?? 0
        verified = try c.decodeIfPresent(Bool.self, forKey: .verified)
        partFileName = try c.decodeIfPresent(String.self, forKey: .partFileName)
        finalizing = try c.decodeIfPresent(Bool.self, forKey: .finalizing) ?? false
    }

    /// Text for a finished job. Only says "OK" when the full-file hash matched the source.
    public var doneLabel: String {
        guard verified == true else { return "Done · not verified (source gives no hash)" }
        return sha256 != nil ? "Done · SHA256 OK" : "Done · git hash OK"
    }

    public var chunkCount: Int {
        guard let total = totalSize, total > 0 else { return 0 }
        return Int((total + chunkSize - 1) / chunkSize)
    }

    public func range(of chunk: Int) -> ClosedRange<Int64> {
        let start = Int64(chunk) * chunkSize
        let end = min(start + chunkSize, totalSize!) - 1
        return start...end
    }

    public func isDone(_ chunk: Int) -> Bool {
        let byte = chunk / 8
        guard byte < doneBitmap.count else { return false }
        return doneBitmap[byte] & (1 << UInt8(chunk % 8)) != 0
    }

    public mutating func markDone(_ chunk: Int) {
        let byte = chunk / 8
        if byte >= doneBitmap.count { doneBitmap.append(contentsOf: [UInt8](repeating: 0, count: byte - doneBitmap.count + 1)) }
        doneBitmap[byte] |= (1 << UInt8(chunk % 8))
    }

    public var missingChunks: [Int] { (0..<chunkCount).filter { !isDone($0) } }

    public var doneBytes: Int64 {
        let full = (0..<chunkCount).reduce(Int64(0)) { acc, c in isDone(c) ? acc + Int64(range(of: c).count) : acc }
        return full + partial.values.reduce(0, +)
    }

    /// Forget all progress (used for "Restart from zero").
    public mutating func reset() {
        totalSize = nil
        sha256 = nil
        doneBitmap = Data()
        partial = [:]
        lastError = nil
        status = .active
        revision = nil      // user chose restart: take the current server version
        gitSHA1 = nil
        chunkHashes = [:]
        repairStage = 0
        verified = nil
        finalizing = false
        fileName = nil       // a new name is reserved on the next run (old part file is deleted by the caller)
        partFileName = nil
    }

    public var finalURL: URL? { fileName.map { URL(fileURLWithPath: destDir).appendingPathComponent($0) } }
    public var partURL: URL? {
        if let p = partFileName { return URL(fileURLWithPath: destDir).appendingPathComponent(p) }
        return finalURL.map { $0.appendingPathExtension("dlpart") }
    }

    /// Both stored names must be single safe path components (state files are user-writable input).
    public var namesAreSafe: Bool {
        [fileName, partFileName].allSatisfy { $0 == nil || FileNames.safe($0!) == $0 }
    }
}

/// Server-provided names must never become paths outside the chosen folder.
public enum FileNames {
    /// One path component: no separators, no control chars, not "."/".."/empty, ≤ 200 UTF-8 bytes.
    /// Returns nil if nothing usable is left.
    public static func safe(_ raw: String) -> String? {
        var s = String(raw.unicodeScalars.map { sc -> Character in
            if sc == "/" || sc == "\\" || sc == ":" || sc.properties.generalCategory == .control || sc == "\u{7F}" { return "_" }
            return Character(sc)
        })
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }          // no hidden files, no "." / ".."
        while s.utf8.count > 200 { s.removeLast() }
        return s.isEmpty ? nil : s
    }
}

public enum StateStore {
    static var overrideDirectory: String? { ProcessInfo.processInfo.environment["MODELPULL_STATE_DIR"] }
    static var appSupport: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0] }

    public static var directory: URL {
        if let custom = overrideDirectory { return URL(fileURLWithPath: custom, isDirectory: true) }
        return appSupport.appendingPathComponent("ModelPull/jobs", isDirectory: true)
    }

    public static func url(for id: UUID, in dir: URL = directory) -> URL {
        dir.appendingPathComponent("\(id.uuidString).json")
    }

    /// `durable: true` also fsyncs the directory so the atomic rename of the state file itself survives power loss.
    /// Used at critical transitions (name reserved, finalize intent, done). Checkpoints skip it: losing one only
    /// means resuming from an older, smaller offset.
    public static func save(_ state: JobState, in dir: URL = directory, durable: Bool = false) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url(for: state.id, in: dir), options: .atomic)
        if durable { syncDirectory(dir) }
    }

    /// fsync a directory so renames/creations inside it are on disk. Best effort.
    public static func syncDirectory(_ dir: URL) {
        let fd = open(dir.path, O_RDONLY)
        guard fd >= 0 else { return }
        _ = fsync(fd)
        close(fd)
    }

    public static func loadAll(in dir: URL = directory) -> [JobState] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(JobState.self, from: Data(contentsOf: $0)) }
            .sorted { $0.addedAt < $1.addedAt }
    }

    public static func delete(_ id: UUID, in dir: URL = directory) {
        try? FileManager.default.removeItem(at: url(for: id, in: dir))
    }
}
