import Foundation
#if canImport(Network)
import Network
#endif
#if canImport(Security)
import Security
#endif
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Backoff

public struct Backoff: Sendable {
    let base: Double
    let max: Double
    private var n = 0

    public init(base: Double = 2, max: Double = 60) { self.base = base; self.max = max }

    /// base * 2^n with ±25% jitter, capped.
    public mutating func next() -> Double {
        let raw = Swift.min(max, base * pow(2, Double(n)))
        n += 1
        return raw * Double.random(in: 0.75...1.25)
    }

    public mutating func reset() { n = 0 }
}

// MARK: - Part file writer

/// Thread-safe positional writes into the .dlpart file, called from URLSession delegate threads.
final class PartWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let starts: [Int: Int64]
    private var partial: [Int: Int64]

    init(url: URL, starts: [Int: Int64], partial: [Int: Int64]) throws {
        handle = try FileHandle(forWritingTo: url)
        self.starts = starts
        self.partial = partial
    }

    func append(chunk: Int, _ data: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard let start = starts[chunk] else { throw DLError.disk("unknown chunk \(chunk)") }
        var offset = start + partial[chunk, default: 0]
        let fd = handle.fileDescriptor
        try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            var done = 0
            while done < buf.count {
                let n = pwrite(fd, buf.baseAddress! + done, buf.count - done, off_t(offset))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw DLError.disk(String(cString: strerror(errno)))
                }
                done += n
                offset += Int64(n)
            }
        }
        partial[chunk, default: 0] += Int64(data.count)
    }

    func complete(_ chunk: Int) { lock.lock(); partial[chunk] = nil; lock.unlock() }
    func snapshot() -> [Int: Int64] { lock.lock(); defer { lock.unlock() }; return partial }
    func sync() throws { try handle.synchronize() }
    func close() { try? handle.close() }
}

// MARK: - Speed

struct SpeedMeter {
    private var samples: [(Date, Int64)] = []

    mutating func add(_ bytes: Int64, at t: Date = Date()) {
        samples.append((t, bytes))
        samples.removeAll { t.timeIntervalSince($0.0) > 10 }
    }

    mutating func reset() { samples.removeAll() }

    var bytesPerSecond: Double {
        guard let first = samples.first, let last = samples.last, last.0 > first.0 else { return 0 }
        return Double(last.1 - first.1) / last.0.timeIntervalSince(first.0)
    }
}

// MARK: - SHA256

public enum FileHash {
    public static func sha256(of url: URL, progress: (Double) -> Void) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = Double((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 1)
        var hasher = SHA256Stream()
        var read: Double = 0
        while true {
            try Task.checkCancellation()
            let chunk = try pooled { try h.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
            read += Double(chunk.count)
            progress(read / size)
        }
        return hasher.hex()
    }

    /// Git blob id: sha1("blob <size>\0" + content). How HF identifies small non-LFS files.
    public static func gitBlobSHA1(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        var hasher = SHA1Stream()
        hasher.update(Data("blob \(size)\0".utf8))
        while true {
            try Task.checkCancellation()
            let chunk = try pooled { try h.read(upToCount: 8 << 20) } ?? Data()
            if chunk.isEmpty { break }
            hasher.update(chunk)
        }
        return hasher.hex()
    }

    /// SHA256 of one byte range of a file (used per chunk).
    public static func sha256(of url: URL, range: ClosedRange<Int64>) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        try h.seek(toOffset: UInt64(range.lowerBound))
        var left = Int(range.count)
        var hasher = SHA256Stream()
        while left > 0 {
            try Task.checkCancellation()
            let chunk = try pooled { try h.read(upToCount: min(left, 4 << 20)) } ?? Data()
            if chunk.isEmpty { throw DLError.disk("short read at \(range.lowerBound)") }
            hasher.update(chunk)
            left -= chunk.count
        }
        return hasher.hex()
    }

    private static func pooled<R>(_ body: () throws -> R) rethrows -> R {
        #if canImport(ObjectiveC)
        return try autoreleasepool(invoking: body)
        #else
        return try body()
        #endif
    }
}

// MARK: - Network

public protocol NetworkWatching: AnyObject, Sendable {
    var isOnline: Bool { get }
    func waitUntilOnline() async
    func subscribe(_ onChange: @escaping @Sendable () -> Void) -> UUID
    func unsubscribe(_ id: UUID)
}

/// Suspension points that end on `resumeAll()` OR on task cancellation (so pause works while offline).
/// Race-safe: cancel before registration resumes immediately; cancel after registration removes and resumes.
public final class CancellableWaiters: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledEarly: Set<UUID> = []

    public init() {}

    /// `ready` is evaluated under this object's lock, so a `resumeAll()` that races with registration is never lost
    /// (callers set their condition BEFORE calling `resumeAll()`).
    public func wait(unlessReady ready: @escaping () -> Bool) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.lock()
                if ready() || cancelledEarly.remove(id) != nil { lock.unlock(); c.resume(); return }
                waiting[id] = c
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            if let c = waiting.removeValue(forKey: id) { lock.unlock(); c.resume() }
            else { cancelledEarly.insert(id); lock.unlock() }
        }
    }

    public func resumeAll() {
        lock.lock()
        let all = Array(waiting.values)
        waiting.removeAll()
        lock.unlock()
        all.forEach { $0.resume() }
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return waiting.count }
}

/// Fires on every real network change (Wi-Fi drop, VPN reconnect = new tunnel interface / IP).
/// Apple: NWPathMonitor. Linux: polls getifaddrs every 2 s (interface names + addresses).
public final class NetworkMonitor: NetworkWatching, @unchecked Sendable {
    public static let shared = NetworkMonitor()

    private let lock = NSLock()
    private var online = true
    private var signature = ""
    private let waiters = CancellableWaiters()
    private var subscribers: [UUID: @Sendable () -> Void] = [:]

    #if canImport(Network)
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let sig = "\(path.status)|" + path.availableInterfaces.map(\.name).sorted().joined(separator: ",")
            self?.update(signature: sig, online: path.status == .satisfied)
        }
        monitor.start(queue: DispatchQueue(label: "dl.network"))
    }
    #else
    private let timer: DispatchSourceTimer

    private init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dl.network"))
        timer.schedule(deadline: .now(), repeating: 2)
        timer.setEventHandler { [weak self] in
            let addrs = Self.interfaceAddresses()
            self?.update(signature: addrs.joined(separator: ","), online: !addrs.isEmpty)
        }
        timer.resume()
    }

    /// "name=addr" for every up, running, non-loopback interface.
    static func interfaceAddresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let p = cur {
            defer { cur = p.pointee.ifa_next }
            let flags = p.pointee.ifa_flags
            guard flags & 0x1 != 0, flags & 0x40 != 0, flags & 0x8 == 0, let sa = p.pointee.ifa_addr else { continue } // UP, RUNNING, !LOOPBACK
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let len = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(sa, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            out.append("\(String(cString: p.pointee.ifa_name))=\(String(cString: host))")
        }
        return out.sorted()
    }
    #endif

    private func update(signature sig: String, online isOnline: Bool) {
        lock.lock()
        let first = signature.isEmpty
        let changed = sig != signature
        signature = sig
        online = isOnline
        let subs = (changed && !first) ? Array(subscribers.values) : []
        lock.unlock()
        if isOnline { waiters.resumeAll() }
        subs.forEach { $0() }
    }

    public var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }

    /// Returns when online OR when the calling task is cancelled (pause / remove while offline).
    public func waitUntilOnline() async {
        await waiters.wait { [unowned self] in self.isOnline }
    }

    public func subscribe(_ onChange: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock(); subscribers[id] = onChange; lock.unlock()
        return id
    }

    public func unsubscribe(_ id: UUID) { lock.lock(); subscribers[id] = nil; lock.unlock() }
}

// MARK: - Keychain (Linux fallback lives in Platform.swift)

#if canImport(Security)
public enum Keychain {
    static let service = AppIdentity.id

    public static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// Empty value deletes the item.
    @discardableResult
    public static func set(_ value: String, for account: String) -> OSStatus {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return errSecSuccess }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        return SecItemAdd(add as CFDictionary, nil)
    }

    public static func tokens() -> Tokens { Tokens(huggingface: get("huggingface"), civitai: get("civitai")) }
}
#endif
