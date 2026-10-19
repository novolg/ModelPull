import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension URLSession {
    /// Portable async request: Linux FoundationNetworking has no `data(for:)`. Honors task cancellation.
    public func dlData(for req: URLRequest) async throws -> (Data, URLResponse) {
        #if canImport(FoundationNetworking)
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<(Data, URLResponse), Error>) in
                let t = dataTask(with: req) { d, r, e in
                    if let e { c.resume(throwing: e) }
                    else if let r { c.resume(returning: (d ?? Data(), r)) }
                    else { c.resume(throwing: URLError(.badServerResponse)) }
                }
                if box.set(t) { t.resume() } else { t.cancel() }
            }
        } onCancel: { box.cancel() }
        #else
        return try await data(for: req)
        #endif
    }
}

public protocol ChunkFetcher: Sendable {
    /// Total size of the remote file. Throws `rangeNotSupported` if server ignores Range.
    func probe(_ target: ResolvedTarget) async throws -> Int64
    /// Streams exactly `range` into `sink` as bytes arrive. Bytes already passed to `sink`
    /// stay valid even when this throws (connection drop) — caller keeps them.
    func fetch(_ target: ResolvedTarget, range: ClosedRange<Int64>, sink: @escaping @Sendable (Data) throws -> Void) async throws
    func invalidate()
}

public final class URLSessionFetcher: ChunkFetcher, @unchecked Sendable {
    /// One session per parallel connection. CDNs speak HTTP/2, and one URLSession multiplexes all its
    /// requests over ONE TCP connection — "4 connections" would then download as fast as one.
    /// Separate sessions = separate TCP connections (and often different CDN edges).
    private struct Lane { let session: URLSession; let delegate: StreamDelegate; var inFlight = 0 }
    private var lanes: [Lane]
    private let lanesLock = NSLock()
    private let probeSession: URLSession

    /// New sessions per retry cycle: drops pooled sockets bound to the old IP / VPN tunnel.
    public init(connections: Int = 4) {
        func config() -> URLSessionConfiguration {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30      // idle timeout = stall guard
            cfg.timeoutIntervalForResource = 6 * 3600
            cfg.urlCache = nil
            cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
            cfg.httpMaximumConnectionsPerHost = 16
            #if os(macOS)
            cfg.waitsForConnectivity = false
            #endif
            return cfg
        }
        lanes = (0..<max(1, connections)).map { _ in
            let d = StreamDelegate()
            return Lane(session: URLSession(configuration: config(), delegate: d, delegateQueue: nil), delegate: d)
        }
        probeSession = URLSession(configuration: config())
    }

    public func invalidate() {
        lanesLock.lock(); let all = lanes; lanesLock.unlock()
        all.forEach { $0.session.invalidateAndCancel() }
        probeSession.invalidateAndCancel()
    }

    /// Least-busy lane, so each in-flight request gets its own TCP connection.
    private func acquireLane() -> Int {
        lanesLock.lock(); defer { lanesLock.unlock() }
        let i = lanes.indices.min { lanes[$0].inFlight < lanes[$1].inFlight }!
        lanes[i].inFlight += 1
        return i
    }

    private func releaseLane(_ i: Int) { lanesLock.lock(); lanes[i].inFlight -= 1; lanesLock.unlock() }

    private func laneParts(_ i: Int) -> (URLSession, StreamDelegate) {
        lanesLock.lock(); defer { lanesLock.unlock() }
        return (lanes[i].session, lanes[i].delegate)
    }

    public func probe(_ target: ResolvedTarget) async throws -> Int64 {
        let (_, resp) = try await probeSession.dlData(for: request(target, range: 0...0))
        guard let http = resp as? HTTPURLResponse else { throw DLError.badResponse("not HTTP") }
        try RangeCheck.status(http.statusCode)
        guard let cr = http.value(forHTTPHeaderField: "Content-Range"), let total = RangeCheck.total(contentRange: cr) else {
            throw DLError.badRange("no Content-Range total")
        }
        return total
    }

    public func fetch(_ target: ResolvedTarget, range: ClosedRange<Int64>, sink: @escaping @Sendable (Data) throws -> Void) async throws {
        let lane = acquireLane()
        defer { releaseLane(lane) }
        let (session, delegate) = laneParts(lane)
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let task = session.dataTask(with: request(target, range: range))
                delegate.register(task.taskIdentifier, StreamDelegate.Handler(range: range, sink: sink) { cont.resume(with: $0) })
                if box.set(task) { task.resume() } else { task.cancel() }
            }
        } onCancel: { box.cancel() }
    }

    private func request(_ target: ResolvedTarget, range: ClosedRange<Int64>) -> URLRequest {
        var req = URLRequest(url: target.directURL)
        req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding") // no gzip: byte offsets must be raw
        target.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        return req
    }
}

/// Cancellation can arrive before the task exists — remember it.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func set(_ t: URLSessionTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        task = t
        return !cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; let t = task; lock.unlock()
        t?.cancel()
    }
}

final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Handler {
        let range: ClosedRange<Int64>
        let sink: @Sendable (Data) throws -> Void
        let done: (Result<Void, Error>) -> Void
        var received: Int64 = 0
        var error: Error?
    }

    private let lock = NSLock()
    private var handlers: [Int: Handler] = [:]

    func register(_ id: Int, _ h: Handler) { lock.lock(); handlers[id] = h; lock.unlock() }

    private func with<R>(_ id: Int, _ body: (inout Handler) -> R) -> R? {
        lock.lock(); defer { lock.unlock() }
        guard var h = handlers[id] else { return nil }
        let r = body(&h)
        handlers[id] = h
        return r
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = with(dataTask.taskIdentifier) { h -> Bool in
            do {
                guard let http = response as? HTTPURLResponse else { throw DLError.badResponse("not HTTP") }
                try RangeCheck.header(status: http.statusCode, contentRange: http.value(forHTTPHeaderField: "Content-Range"), requested: h.range)
                return true
            } catch { h.error = error; return false }
        } ?? false
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // sink runs outside the lock (it does disk I/O)
        guard let sink = with(dataTask.taskIdentifier, { h -> (@Sendable (Data) throws -> Void)? in
            guard h.error == nil else { return nil }
            if h.received + Int64(data.count) > Int64(h.range.count) { h.error = DLError.badRange("body longer than range"); return nil }
            return h.sink
        }) ?? nil else { dataTask.cancel(); return }
        do {
            try sink(data)
            _ = with(dataTask.taskIdentifier) { $0.received += Int64(data.count) }
        } catch {
            _ = with(dataTask.taskIdentifier) { $0.error = error }
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let h = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let h else { return }
        if let e = h.error ?? error { h.done(.failure(e)); return }
        if h.received != Int64(h.range.count) { h.done(.failure(DLError.badRange("short body \(h.received)/\(h.range.count)"))); return }
        h.done(.success(()))
    }
}

/// Pure response checks — unit-tested in DLChecks.
public enum RangeCheck {
    public static func status(_ code: Int) throws {
        switch code {
        case 206: return
        case 200: throw DLError.rangeNotSupported
        case 400, 401, 403, 404, 410: throw DLError.linkExpired(code)   // signed URL dead (expired / IP-bound)
        case 416: throw DLError.badRange("416")
        default: throw DLError.http(code)
        }
    }

    /// "bytes 0-0/12345" -> 12345
    public static func total(contentRange: String) -> Int64? {
        guard let slash = contentRange.lastIndex(of: "/") else { return nil }
        return Int64(contentRange[contentRange.index(after: slash)...].trimmingCharacters(in: .whitespaces))
    }

    public static func header(status code: Int, contentRange: String?, requested: ClosedRange<Int64>) throws {
        try status(code)
        guard let cr = contentRange else { throw DLError.badRange("missing Content-Range") }
        let expectedPrefix = "bytes \(requested.lowerBound)-\(requested.upperBound)/"
        guard cr.hasPrefix(expectedPrefix) else { throw DLError.badRange("got \(cr), want \(expectedPrefix)") }
    }

    public static func validate(status code: Int, contentRange: String?, requested: ClosedRange<Int64>, received: Int) throws {
        try header(status: code, contentRange: contentRange, requested: requested)
        guard Int64(received) == Int64(requested.count) else { throw DLError.badRange("short body \(received)/\(requested.count)") }
    }
}
