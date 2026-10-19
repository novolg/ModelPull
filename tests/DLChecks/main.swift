import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

import DLCore

// Self-check runner (no XCTest in Command Line Tools). Exit code != 0 on failure.

var failures = 0
func check(_ cond: Bool, _ name: String) {
    print(cond ? "  ok   \(name)" : "  FAIL \(name)")
    if !cond { failures += 1 }
}

// MARK: - Fakes

/// In-memory "CDN": links expire, connections drop, sometimes returns 200 (ignores Range).
final class FakeServer: @unchecked Sendable {
    var blob: Data
    let lock = NSLock()
    var corruptOnce = false          // corrupt `corruptChunk` only the first time it is served
    var swapAfterBytes: Int64?       // publish a NEW file version (same size) after this many bytes served
    var giveHash = true              // false = source without hash
    var generation = 0          // bumps on every resolve; old links die (like new IP / expired signature)
    var fetchesPerLink = 0
    var bytesServed: Int64 = 0
    var dropRate: Double
    var expireAfter: Int        // fetches before link expires
    var ignoreRangeRate: Double
    var corruptChunk: Int?

    init(size: Int, dropRate: Double = 0, expireAfter: Int = .max, ignoreRangeRate: Double = 0) {
        var g = SystemRandomNumberGenerator()
        blob = Data((0..<size).map { _ in UInt8.random(in: 0...255, using: &g) })
        self.dropRate = dropRate
        self.expireAfter = expireAfter
        self.ignoreRangeRate = ignoreRangeRate
    }

    var sha: String { SHA256Stream.hex(of: blob) }

    func newLink() -> URL {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        fetchesPerLink = 0
        return URL(string: "https://cdn.fake/file?gen=\(generation)")!
    }

    var cutAfterFraction: Double? // every request dies after delivering this share of its range

    func serve(_ url: URL, range: ClosedRange<Int64>) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        guard url.query == "gen=\(generation)" else { throw DLError.linkExpired(403) }
        fetchesPerLink += 1
        if fetchesPerLink > expireAfter { throw DLError.linkExpired(403) }
        if Double.random(in: 0..<1) < ignoreRangeRate { throw DLError.rangeNotSupported }
        var d = blob.subdata(in: Int(range.lowerBound)..<Int(range.upperBound) + 1)
        if let c = corruptChunk, range.lowerBound == Int64(c) * 64 * 1024 {
            d[0] ^= 0xFF
            if corruptOnce { corruptChunk = nil }
        }
        return d
    }

    func served(_ n: Int) {
        lock.lock(); defer { lock.unlock() }
        bytesServed += Int64(n)
        if let s = swapAfterBytes, bytesServed >= s {
            swapAfterBytes = nil
            blob = Data(blob.map { $0 ^ 0x5A })   // new version, same size
        }
    }

    var currentSHA: String? { lock.lock(); defer { lock.unlock() }; return giveHash ? SHA256Stream.hex(of: blob) : nil }
}

struct FakeResolver: Resolver {
    let server: FakeServer
    func resolve(_ source: URL, tokens: Tokens) async throws -> ResolvedTarget {
        ResolvedTarget(directURL: server.newLink(), fileName: "model.safetensors", sha256: server.currentSHA)
    }
}

struct FakeFetcher: ChunkFetcher {
    let server: FakeServer
    func probe(_ t: ResolvedTarget) async throws -> Int64 {
        _ = try server.serve(t.directURL, range: 0...0)
        return Int64(server.blob.count)
    }
    /// Streams 16 KB pieces; connection can die mid-stream after some bytes were delivered.
    func fetch(_ t: ResolvedTarget, range: ClosedRange<Int64>, sink: @escaping @Sendable (Data) throws -> Void) async throws {
        let data = try server.serve(t.directURL, range: range)
        let cut = server.cutAfterFraction.map { max(1, Int(Double(data.count) * $0)) }
        var i = 0
        while i < data.count {
            try Task.checkCancellation()
            if let cut, i >= cut, data.count > 1 { throw URLError(.networkConnectionLost) }
            if Double.random(in: 0..<1) < server.dropRate / 4 { throw URLError(.networkConnectionLost) }
            let end = min(i + 16 * 1024, data.count)
            try sink(data.subdata(in: i..<end))
            server.served(end - i)
            i = end
            try await Task.sleep(nanoseconds: 50_000)
        }
    }
    func invalidate() {}
}

final class AlwaysOnline: NetworkWatching, @unchecked Sendable {
    var isOnline: Bool { true }
    func waitUntilOnline() async {}
    func subscribe(_ onChange: @escaping @Sendable () -> Void) -> UUID { UUID() }
    func unsubscribe(_ id: UUID) {}
}

let chunk: Int64 = 64 * 1024
let fastConfig = EngineConfig(connections: 4, verifySHA: true, backoffBase: 0.001, backoffMax: 0.01, linkRetryDelay: 0.001)

func makeEngine(_ server: FakeServer, state: JobState, dir: URL) -> DownloadEngine {
    DownloadEngine(state: state, stateDir: dir.appendingPathComponent("state"), resolver: FakeResolver(server: server),
                   makeFetcher: { FakeFetcher(server: server) }, tokens: { Tokens() },
                   network: AlwaysOnline(), config: fastConfig)
}

func tempDir() -> URL {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("dlchecks-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}

func newState(_ dir: URL) -> JobState {
    JobState(sourceURL: "https://example.test/model", kind: .direct, destDir: dir.path, chunkSize: chunk)
}

setvbuf(stdout, nil, _IOLBF, 0)

// MARK: - Request diagnostics: DLChecks --probe <url>

if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--probe" {
    let url = URL(string: CommandLine.arguments[2])!
    func timed(_ name: String, _ body: () async throws -> String) async {
        let t = Date()
        do { print("\(name): \(try await body()) in \(String(format: "%.2f", Date().timeIntervalSince(t)))s") }
        catch { print("\(name): ERROR \(error) after \(String(format: "%.2f", Date().timeIntervalSince(t)))s") }
    }
    // Matrix: which factor makes Linux URLSession hang? (fresh vs reused session, Accept-Encoding: identity, redirect blocked or followed)
    let shared = NoRedirect.makeSession()
    for round in 1...3 {
        for (name, session, identity) in [("fresh/plain", NoRedirect.makeSession(), false), ("fresh/identity", NoRedirect.makeSession(), true),
                                          ("shared/plain", shared, false), ("shared/identity", shared, true),
                                          ("follow/identity", URLSession(configuration: .ephemeral), true)] {
            await timed("r\(round) \(name)") {
                var r = URLRequest(url: url); r.timeoutInterval = 12
                r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                if identity { r.setValue("identity", forHTTPHeaderField: "Accept-Encoding") }
                let (d, resp) = try await session.dlData(for: r)
                return "\((resp as! HTTPURLResponse).statusCode) body=\(d.count)"
            }
        }
    }
    // Hypothesis: first transfer of a fresh session never starts until some other event drives the curl multi loop.
    for round in 1...3 {
        let s = NoRedirect.makeSession()
        var r = URLRequest(url: url); r.timeoutInterval = 12
        r.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let kick = Task { try? await Task.sleep(nanoseconds: 300_000_000); _ = try? await s.dlData(for: r) }
        await timed("r\(round) fresh+kick first") { let (_, resp) = try await s.dlData(for: r); return "\((resp as! HTTPURLResponse).statusCode)" }
        kick.cancel()
    }
    let noRedirect = NoRedirect.makeSession()
    for method in ["HEAD", "GET"] {
        await timed("\(method) no-redirect") {
            var r = URLRequest(url: url); r.httpMethod = method
            if method == "GET" { r.setValue("bytes=0-0", forHTTPHeaderField: "Range") }
            let (d, resp) = try await noRedirect.dlData(for: r)
            let h = resp as! HTTPURLResponse
            return "\(h.statusCode) body=\(d.count) loc=\(h.value(forHTTPHeaderField: "Location")?.prefix(60) ?? "-")"
        }
    }
    await timed("resolve") { let t = try await RouterResolver().resolve(url, tokens: Tokens()); return "\(t.directURL.host ?? "-") sha=\(t.sha256 ?? "none")" }
    guard let target = try? await RouterResolver().resolve(url, tokens: Tokens()) else { print("resolve failed, stop"); exit(1) }
    let fetcher = URLSessionFetcher()
    await timed("probe") { "size=\(try await fetcher.probe(target))" }
    await timed("stream 0-65535") {
        final class Count: @unchecked Sendable { let l = NSLock(); var n = 0 }; let c = Count()
        try await fetcher.fetch(target, range: 0...65535) { d in c.l.lock(); c.n += d.count; c.l.unlock() }
        return "bytes=\(c.n)"
    }
    exit(0)
}

// MARK: - Real download: DLChecks --real <url> <dir>

if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--real" {
    let env = ProcessInfo.processInfo.environment
    let tokens = Tokens(huggingface: env["HF_TOKEN"], civitai: env["CIVITAI_API_KEY"])
    let url = CommandLine.arguments[2]
    guard let kind = SourceParser.kind(of: URL(string: url)!) else { print("unsupported URL"); exit(2) }
    let stateDir = URL(fileURLWithPath: CommandLine.arguments[3]).appendingPathComponent(".state")
    // Reuse saved state for the same URL -> tests resume across process restarts.
    let state = StateStore.loadAll(in: stateDir).first { $0.sourceURL == url && $0.status != .done }
        ?? JobState(sourceURL: url, kind: kind, destDir: CommandLine.arguments[3], chunkSize: EngineConfig.defaultChunkSize)
    print("start doneBytes=\(state.doneBytes)")
    let engine = DownloadEngine(state: state, stateDir: stateDir,
                                tokens: { tokens }, config: EngineConfig(connections: Int(env["DL_CONNECTIONS"] ?? "4") ?? 4), onProgress: { p in
        print("\(p.phase) \(p.fileName ?? "?") \(p.doneBytes)/\(p.totalBytes ?? -1) \(Int(p.bytesPerSecond / 1024)) KB/s")
    })
    let final = await engine.run()
    print("RESULT \(final.status) label=\"\(final.status == .done ? final.doneLabel : "-")\" sha=\(final.sha256 ?? "none") git=\(final.gitSHA1 ?? "none") rev=\(final.revision ?? "-") repair=\(final.repairStage) file=\(final.finalURL?.path ?? "-") err=\(final.lastError ?? "-")")
    exit(final.status == .done ? 0 : 1)
}

// MARK: - Checks

print("Parsers")
check(HFResolver.resolveURL(from: URL(string: "https://huggingface.co/black-forest-labs/FLUX.1-dev/blob/main/flux1-dev.safetensors")!)?.absoluteString
      == "https://huggingface.co/black-forest-labs/FLUX.1-dev/resolve/main/flux1-dev.safetensors", "HF blob -> resolve")
check(HFResolver.resolveURL(from: URL(string: "https://huggingface.co/datasets/a/b/resolve/main/x/y.bin?download=true")!)?.absoluteString
      == "https://huggingface.co/datasets/a/b/resolve/main/x/y.bin", "HF dataset nested path, query dropped")
check(HFResolver.resolveURL(from: URL(string: "https://huggingface.co/a/b")!) == nil, "HF repo page rejected")
check(CivitaiResolver.parse(URL(string: "https://civitai.com/models/4201/realistic-vision?modelVersionId=130072")!) == .version(130072, downloadURL: nil), "Civitai model page with version")
check(CivitaiResolver.parse(URL(string: "https://civitai.com/models/4201/realistic-vision")!) == .model(4201), "Civitai model page")
let cdl = URL(string: "https://civitai.com/api/download/models/130072?type=Model&format=SafeTensor")!
check(CivitaiResolver.parse(cdl) == .version(130072, downloadURL: cdl), "Civitai download API link")
check(SourceParser.kind(of: URL(string: "https://civitai.com/user/x")!) == nil, "Civitai non-model page rejected")
check(Hex.sha256(from: "\"ABCDEF0123456789abcdef0123456789ABCDEF0123456789abcdef0123456789\"") == "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", "ETag -> sha256")

print("SHA256")
check(SHA256Stream.hex(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "abc vector")
check(SHA256Stream.hex(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", "empty vector")
do {
    let big = Data((0..<1_000_003).map { UInt8($0 % 251) })
    var s = SHA256Stream()
    var i = 0
    while i < big.count { let e = min(i + 777, big.count); s.update(big.subdata(in: i..<e)); i = e }  // odd split sizes
    check(s.hex() == SHA256Stream.hex(of: big), "streamed == one-shot")
    check(s.hex() == "a7c4bea888022868c93104055fd56077cc81fe9eb624820fe2f717f313188782",  // python hashlib reference
          "1 MB vector (\(s.hex()))")
}

print("SHA1 / git blob id / version pin")
check(SHA1Stream.hex(of: Data("abc".utf8)) == "a9993e364706816aba3e25717850c26c9cd0d89d", "sha1 abc vector")
check(SHA1Stream.hex(of: Data((0..<200).map { UInt8($0) })) == "54d11e99127d159799dbce10f51a75e697780478", "sha1 200-byte vector (python hashlib reference)")
do {
    let f = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("blob-\(UUID().uuidString)")
    try! Data("hello world\n".utf8).write(to: f)
    check((try? FileHash.gitBlobSHA1(of: f)) == "3b18e512dba79e4c8300dd08aeb37f8e728b8dad", "git blob id of 'hello world\\n' (same as `git hash-object`)")
}
check(Hex.sha1(from: "\"10C66461E4C109DB5A2196BFF4BB59BE30396ED8\"") == "10c66461e4c109db5a2196bff4bb59be30396ed8", "ETag -> git sha1")
check(HFResolver.pinned(URL(string: "https://huggingface.co/org/repo/blob/main/sub/f.bin")!, revision: "607a30d783dfa663caf39e06633721c8d4cfcd7e")?.absoluteString
      == "https://huggingface.co/org/repo/resolve/607a30d783dfa663caf39e06633721c8d4cfcd7e/sub/f.bin", "pin main -> commit")

print("Range validation")
check((try? RangeCheck.validate(status: 206, contentRange: "bytes 0-9/100", requested: 0...9, received: 10)) != nil, "valid 206")
check((try? RangeCheck.validate(status: 200, contentRange: nil, requested: 0...9, received: 100)) == nil, "200 rejected")
check((try? RangeCheck.validate(status: 206, contentRange: "bytes 0-9/100", requested: 0...9, received: 7)) == nil, "short body rejected")
check((try? RangeCheck.validate(status: 206, contentRange: "bytes 10-19/100", requested: 0...9, received: 10)) == nil, "wrong offset rejected")
do { try RangeCheck.status(403); check(false, "403 -> linkExpired") } catch { check(error as? DLError == .linkExpired(403), "403 -> linkExpired") }
check(RangeCheck.total(contentRange: "bytes 0-0/16106127360") == 16_106_127_360, "Content-Range total (15 GB)")

print("Engine: hostile network (30% drops, links expire every 5 fetches, 5% ignore Range)")
do {
    let dir = tempDir()
    let server = FakeServer(size: 3 * 1024 * 1024 + 123, dropRate: 0.3, expireAfter: 5, ignoreRangeRate: 0.05)
    let final = await makeEngine(server, state: newState(dir), dir: dir).run()
    check(final.status == .done, "finished (status=\(final.status), err=\(final.lastError ?? "-"))")
    let data = final.finalURL.flatMap { try? Data(contentsOf: $0) }
    check(data == server.blob, "bytes identical")
    check(server.generation > 3, "re-resolved links \(server.generation)x")
    check(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("model.safetensors.dlpart").path), "part file removed")
}

print("Engine: slow link — every request dies after 40% of its bytes")
do {
    let dir = tempDir()
    let server = FakeServer(size: 1024 * 1024 + 7)
    server.cutAfterFraction = 0.4
    let final = await makeEngine(server, state: newState(dir), dir: dir).run()
    check(final.status == .done, "finished anyway (status=\(final.status), err=\(final.lastError ?? "-"))")
    check(final.finalURL.flatMap { try? Data(contentsOf: $0) } == server.blob, "bytes identical")
    check(server.bytesServed < Int64(server.blob.count) * 11 / 10, "no bytes re-downloaded (\(server.bytesServed) served for \(server.blob.count))")
}

print("Engine: pause mid-way, resume with new engine -> no restart from zero")
do {
    let dir = tempDir()
    let server = FakeServer(size: 4 * 1024 * 1024)
    let state = newState(dir)
    let e1 = makeEngine(server, state: state, dir: dir)
    let t = Task { await e1.run() }
    while server.bytesServed < 1_500_000 { try? await Task.sleep(nanoseconds: 100_000) }
    t.cancel()
    let paused = await t.value
    check(paused.status == .paused, "paused")
    let doneBefore = paused.doneBytes
    check(doneBefore > 0, "progress saved (\(doneBefore) bytes)")

    // Reload from disk like an app relaunch.
    let reloaded = StateStore.loadAll(in: dir.appendingPathComponent("state")).first!
    check(reloaded.doneBytes == doneBefore, "state on disk matches")
    let servedBefore = server.bytesServed
    let final = await makeEngine(server, state: reloaded, dir: dir).run()
    check(final.status == .done, "finished after resume")
    check(final.finalURL.flatMap { try? Data(contentsOf: $0) } == server.blob, "bytes identical")
    let secondRun = server.bytesServed - servedBefore
    check(secondRun < Int64(server.blob.count) - doneBefore + 8 * chunk, "second run fetched only missing part (\(secondRun) bytes)")
}

func fileBytes(_ s: JobState) -> Data? { s.finalURL.flatMap { try? Data(contentsOf: $0) } }
func partExists(_ s: JobState) -> Bool { s.partURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

print("Engine: pause when verification starts keeps the part file")
do {
    let dir = tempDir()
    let server = FakeServer(size: 128 * 1024)
    let engine = DownloadEngine(state: newState(dir), stateDir: dir.appendingPathComponent("state"),
        resolver: FakeResolver(server: server), makeFetcher: { FakeFetcher(server: server) },
        tokens: { Tokens() }, network: AlwaysOnline(), config: fastConfig) { snap in
            if case .verifying(fraction: 0) = snap.phase {
                // Synchronous callback runs in the engine's run task: cancel at
                // the exact boundary, without timing-dependent sleeps.
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
    let paused = await Task { await engine.run() }.value
    check(paused.status == .paused, "verification cancellation pauses")
    check(partExists(paused) && fileBytes(paused) == nil, "cancelled verification never renames the file")
    let final = await makeEngine(server, state: paused, dir: dir).run()
    check(final.status == .done && final.verified == true, "resume verifies successfully")
    check(server.bytesServed == Int64(server.blob.count), "resume does not download completed bytes again")
}

print("Hashing: all file hash variants observe cancellation")
do {
    let dir = tempDir()
    let file = dir.appendingPathComponent("hash.bin")
    try! Data(repeating: 42, count: 1024).write(to: file)
    for variant in 0..<3 {
        let cancelled = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                switch variant {
                case 0: _ = try FileHash.sha256(of: file) { _ in }
                case 1: _ = try FileHash.gitBlobSHA1(of: file)
                default: _ = try FileHash.sha256(of: file, range: 0...1023)
                }
                return false
            } catch is CancellationError { return true }
            catch { return false }
        }.value
        check(cancelled, "hash variant \(variant) cancels")
    }
}

print("Integrity: server ALWAYS sends wrong bytes for one chunk -> never Done, file never gets its real name")
do {
    let dir = tempDir()
    let server = FakeServer(size: 1024 * 1024)
    server.corruptChunk = 3
    let final = await makeEngine(server, state: newState(dir), dir: dir).run()
    check(final.status == .failed && final.lastError == DLError.hashMismatch.errorDescription, "failed with hashMismatch (\(final.lastError ?? "-"))")
    check(final.repairStage == 2, "tried partial repair and full re-download first (stage \(final.repairStage))")
    check(fileBytes(final) == nil, "no file with the real name")
    check(partExists(final), ".dlpart kept")
}

print("Integrity: wrong bytes ONCE in transit -> full re-download -> Done, verified, identical")
do {
    let dir = tempDir()
    let server = FakeServer(size: 1024 * 1024 + 5)
    server.corruptChunk = 3
    server.corruptOnce = true
    let final = await makeEngine(server, state: newState(dir), dir: dir).run()
    check(final.status == .done && final.verified == true, "done + verified (\(final.status), \(final.lastError ?? "-"))")
    check(fileBytes(final) == server.blob, "bytes identical to source")
    check(final.doneLabel == "Done · SHA256 OK", "label: \(final.doneLabel)")
}

print("Integrity: byte damaged ON DISK after its chunk finished -> only that chunk re-downloaded -> Done, identical")
do {
    let dir = tempDir()
    let server = FakeServer(size: 4 * 1024 * 1024)
    let e1 = makeEngine(server, state: newState(dir), dir: dir)
    let t = Task { await e1.run() }
    while server.bytesServed < 2_000_000 { try? await Task.sleep(nanoseconds: 100_000) }
    t.cancel()
    let paused = await t.value
    check(paused.isDone(0) && paused.chunkHashes[0] != nil, "chunk 0 finished and hashed")
    // Damage one byte of chunk 0 on disk.
    let h = try! FileHandle(forUpdating: paused.partURL!)
    try! h.seek(toOffset: 100); let b = try! h.read(upToCount: 1)!; try! h.seek(toOffset: 100)
    try! h.write(contentsOf: Data([b[0] ^ 0xFF])); try! h.close()
    let servedBefore = server.bytesServed
    let final = await makeEngine(server, state: paused, dir: dir).run()
    check(final.status == .done && final.verified == true, "done + verified (\(final.status), \(final.lastError ?? "-"))")
    check(fileBytes(final) == server.blob, "bytes identical to source")
    check(final.repairStage == 1, "fixed by partial repair (stage \(final.repairStage))")
    let second = server.bytesServed - servedBefore
    let bound = Int64(server.blob.count) - paused.doneBytes + chunk
    check(second <= bound, "re-downloaded only the damaged chunk (second run \(second) bytes, remaining+1 chunk = \(bound), paused done=\(paused.doneBytes), partial=\(paused.partial.sorted { $0.key < $1.key }))")
}

print("Integrity: new file version published mid-download (same size) -> stop, never mix versions")
do {
    let dir = tempDir()
    let server = FakeServer(size: 2 * 1024 * 1024)
    server.swapAfterBytes = 900_000
    server.expireAfter = 3 // forces re-resolve, which sees the new hash
    let final = await makeEngine(server, state: newState(dir), dir: dir).run()
    check(final.status == .failed && final.lastError == DLError.sourceChanged.errorDescription, "failed with sourceChanged (\(final.lastError ?? "-"))")
    check(fileBytes(final) == nil, "no file with the real name")
}

print("Integrity: source without any hash -> Done but clearly NOT verified")
do {
    let dir = tempDir()
    let server = FakeServer(size: 300 * 1024)
    server.giveHash = false
    let final = await makeEngine(server, state: newState(dir), dir: dir).run()
    check(final.status == .done && final.verified == false, "done, verified=false")
    check(final.doneLabel.contains("not verified"), "label: \(final.doneLabel)")
}

print("Compatibility: state file from the previous app version still loads")
do {
    // Real file written by the previous version during a live HF test (2026-10-18).
    let old = try? Data(contentsOf: URL(fileURLWithPath: "tests/fixtures/state-v1.json"))
    let s = old.flatMap { try? JSONDecoder().decode(JobState.self, from: $0) }
    check(s != nil, "decodes")
    check(s?.doneBytes == 7_133_723 && s?.partial[0] == 1_888_255, "progress kept (\(s?.doneBytes ?? -1) bytes)")
    check(s?.sha256 == "248dfc3911869ec493c76e65bf2fcf7f615828b0254c12b473182f0f81d3a707", "expected hash kept")
    check(s?.repairStage == 0 && s?.chunkHashes.isEmpty == true && s?.revision == nil, "new fields default")
}

print("Engine: file changed on server -> fatal")
do {
    let dir = tempDir()
    let server = FakeServer(size: 512 * 1024)
    var s = newState(dir)
    s.totalSize = 999
    s.fileName = "model.safetensors"
    FileManager.default.createFile(atPath: dir.appendingPathComponent("model.safetensors.dlpart").path, contents: Data(count: 999))
    let final = await makeEngine(server, state: s, dir: dir).run()
    check(final.status == .failed, "failed with sizeChanged (\(final.lastError ?? "-"))")
}

// MARK: - Fixes for review findings 1-4

/// true if `op` finishes within `seconds`.
func finishes(within seconds: Double, _ op: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { g in
        g.addTask { await op(); return true }
        g.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return false }
        let first = await g.next()!
        g.cancelAll()
        return first
    }
}

struct NamedResolver: Resolver {
    let server: FakeServer
    let name: String
    func resolve(_ source: URL, tokens: Tokens) async throws -> ResolvedTarget {
        ResolvedTarget(directURL: server.newLink(), fileName: name, sha256: server.currentSHA)
    }
}

func namedEngine(_ server: FakeServer, _ name: String, state: JobState, dir: URL, stateDir: URL? = nil) -> DownloadEngine {
    DownloadEngine(state: state, stateDir: stateDir ?? dir.appendingPathComponent("state"), resolver: NamedResolver(server: server, name: name),
                   makeFetcher: { FakeFetcher(server: server) }, tokens: { Tokens() }, network: AlwaysOnline(), config: fastConfig)
}

print("Finding 3: server file names cannot escape the folder")
check(FileNames.safe("model.safetensors") == "model.safetensors", "normal name unchanged")
check(FileNames.safe("../../etc/passwd").map { !$0.contains("/") && !$0.hasPrefix(".") } == true, "../../etc/passwd -> \(FileNames.safe("../../etc/passwd") ?? "nil")")
check(FileNames.safe("..") == nil && FileNames.safe(".") == nil && FileNames.safe("  ") == nil && FileNames.safe("") == nil, "., .., blank rejected")
check(FileNames.safe("a\u{0}b\u{1F}c\\d:e") == "a_b_c_d_e", "control chars and separators replaced")
check((FileNames.safe(String(repeating: "я", count: 300)) ?? "").utf8.count <= 200, "length capped")
do {
    let dir = tempDir()
    let server = FakeServer(size: 200 * 1024)
    let final = await namedEngine(server, "../../escape.bin", state: newState(dir), dir: dir).run()
    check(final.status == .done, "download with hostile name still works")
    check(final.finalURL?.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path, "saved inside the chosen folder (\(final.fileName ?? "-"))")
    check(!FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("escape.bin").path), "nothing written outside")
    var bad = newState(dir); bad.fileName = "../outside.bin"
    let refused = await makeEngine(server, state: bad, dir: dir).run()
    check(refused.status == .failed && refused.lastError == DLError.unsafeFileName.errorDescription, "unsafe name in saved state refused")
}

print("Finding 1: two jobs with the same file name never share a part file")
do {
    let dir = tempDir()
    let a = FakeServer(size: 1024 * 1024), b = FakeServer(size: 1024 * 1024 + 9)   // different content, same name
    async let ra = namedEngine(a, "same.bin", state: newState(dir), dir: dir).run()
    async let rb = namedEngine(b, "same.bin", state: newState(dir), dir: dir).run()
    let (fa, fb) = await (ra, rb)
    check(fa.status == .done && fb.status == .done, "both done")
    check(fa.fileName != fb.fileName, "different names (\(fa.fileName ?? "-"), \(fb.fileName ?? "-"))")
    check(fileBytes(fa) == a.blob && fileBytes(fb) == b.blob, "each file has its own server's bytes")
}

print("Finding 2: crash during finalize is completed on restart, never re-downloaded")
do {
    let dir = tempDir()
    let server = FakeServer(size: 600 * 1024)
    let done = await makeEngine(server, state: newState(dir), dir: dir).run()
    check(done.status == .done && done.finalizing == false && !partExists(done), "normal finish leaves no intent and no part")
    let final = done.finalURL!, part = done.partURL!
    var crashed = done; crashed.status = .active; crashed.finalizing = true

    // a) crash after link+unlink, before saving "done"
    var served = server.bytesServed
    var r = await makeEngine(server, state: crashed, dir: dir).run()
    check(r.status == .done && server.bytesServed == served && fileBytes(r) == server.blob, "a) final present, part gone -> done, 0 bytes downloaded")

    // b) crash between link and unlink: both names point to the same file
    _ = link(final.path, part.path)
    served = server.bytesServed
    r = await makeEngine(server, state: crashed, dir: dir).run()
    check(r.status == .done && !partExists(r) && server.bytesServed == served, "b) hard-linked part removed -> done, 0 bytes downloaded")

    // c) crash before the rename: only the part exists -> verify again and publish
    try! FileManager.default.moveItem(at: final, to: part)
    served = server.bytesServed
    r = await makeEngine(server, state: crashed, dir: dir).run()
    check(r.status == .done && r.verified == true && fileBytes(r) == server.blob && server.bytesServed == served, "c) part only -> re-verified and published, 0 bytes downloaded")

    // d) the final name was taken by another file meanwhile -> never overwritten
    try! FileManager.default.moveItem(at: r.finalURL!, to: part)
    try! Data("someone else's file".utf8).write(to: final)
    r = await makeEngine(server, state: crashed, dir: dir).run()
    check(r.status == .done && (try? String(contentsOf: final, encoding: .utf8)) == "someone else's file", "d) existing file with that name untouched")
    check(fileBytes(r) == server.blob && r.fileName != done.fileName, "d) ours published under a new name (\(r.fileName ?? "-"))")
}
do {
    let dir = tempDir()
    let notADir = dir.appendingPathComponent("state-is-a-file")
    try! Data().write(to: notADir)
    let r = await namedEngine(FakeServer(size: 100 * 1024), "x.bin", state: newState(dir), dir: dir, stateDir: notADir).run()
    check(r.status == .failed && (r.lastError ?? "").contains("cannot save job state"), "state save failure stops the job instead of being ignored")
}

print("Finding 4: pause works while offline")
do {
    let w = CancellableWaiters()
    let early = Task { await w.wait { false } }
    early.cancel()
    check(await finishes(within: 2) { await early.value }, "cancel before registration")
    let late = Task { await w.wait { false } }
    while w.count == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    late.cancel()
    check(await finishes(within: 2) { await late.value }, "cancel after registration")
    check(w.count == 0, "no waiter left behind")
    let woken = Task { await w.wait { false } }
    while w.count == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    w.resumeAll()
    check(await finishes(within: 2) { await woken.value }, "resumeAll wakes waiters")
}
final class Offline: NetworkWatching, @unchecked Sendable {
    let w = CancellableWaiters()
    var isOnline: Bool { false }
    func waitUntilOnline() async { await w.wait { false } }
    func subscribe(_ onChange: @escaping @Sendable () -> Void) -> UUID { UUID() }
    func unsubscribe(_ id: UUID) {}
}
do {
    let dir = tempDir()
    let server = FakeServer(size: 100 * 1024)
    let net = Offline()
    let e = DownloadEngine(state: newState(dir), stateDir: dir.appendingPathComponent("state"), resolver: FakeResolver(server: server),
                           makeFetcher: { FakeFetcher(server: server) }, tokens: { Tokens() }, network: net, config: fastConfig)
    let t = Task { await e.run() }
    while net.w.count == 0 { try? await Task.sleep(nanoseconds: 1_000_000) }
    t.cancel()
    let ok = await finishes(within: 2) { _ = await t.value }
    check(ok, "engine waiting for network stops on pause")
    if ok { check(await t.value.status == .paused, "status paused") }
}

print("Rename: data from the old \"Downloader\" folders moves once")
do {
    let dir = tempDir()
    let fm = FileManager.default
    let old = dir.appendingPathComponent("Downloader/jobs"), new = dir.appendingPathComponent("ModelPull/jobs")
    try! fm.createDirectory(at: old, withIntermediateDirectories: true)
    try! Data("a".utf8).write(to: old.appendingPathComponent("a.json"))
    check(LegacyData.move(old, to: new), "old folder moved")
    check(fm.fileExists(atPath: new.appendingPathComponent("a.json").path) && !fm.fileExists(atPath: old.path), "file is in the new folder only")
    try! fm.createDirectory(at: old, withIntermediateDirectories: true)
    try! Data("b".utf8).write(to: old.appendingPathComponent("b.json"))
    check(!LegacyData.move(old, to: new), "existing new folder is never replaced")
    check(fm.fileExists(atPath: new.appendingPathComponent("a.json").path) && fm.fileExists(atPath: old.appendingPathComponent("b.json").path), "both folders unchanged")
    check(!LegacyData.move(dir.appendingPathComponent("none"), to: dir.appendingPathComponent("x")), "missing old folder: no-op")
}

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
