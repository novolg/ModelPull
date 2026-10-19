import Foundation
#if canImport(os)
import os
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

// Platform seams: logging, SHA256, token storage. Apple uses system frameworks; Linux uses portable fallbacks.

// MARK: - Names and folders

public enum AppIdentity {
    /// Bundle id, log subsystem and Keychain service.
    public static let id = "io.github.novolg.modelpull"
}

/// ~/.config/modelpull (XDG_CONFIG_HOME respected): Linux tokens, web UI settings.
public enum AppConfig {
    static var base: URL {
        ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
    }
    public static var directory: URL { base.appendingPathComponent("modelpull", isDirectory: true) }
}

/// The app was called "Downloader" before. Moves its jobs and config folder to the new place once, at start.
/// Keychain tokens and macOS app settings are not moved (they are keyed by the old bundle id).
public enum LegacyData {
    public static func migrate() {
        if StateStore.overrideDirectory == nil {
            let old = StateStore.appSupport.appendingPathComponent("Downloader", isDirectory: true)
            if move(old.appendingPathComponent("jobs", isDirectory: true), to: StateStore.directory),
               (try? FileManager.default.contentsOfDirectory(atPath: old.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: old)
            }
        }
        move(AppConfig.base.appendingPathComponent("downloader", isDirectory: true), to: AppConfig.directory)
    }

    /// Moves `old` to `new` only when `old` exists and `new` does not. Returns true when it moved.
    @discardableResult
    public static func move(_ old: URL, to new: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return false }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)
            Log("migrate").info("moved \(old.path) -> \(new.path)")
            return true
        } catch {
            Log("migrate").error("move failed from=\(old.path) to=\(new.path) error=\(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Logging

public struct Log {
    let category: String
    #if canImport(os)
    private let logger: Logger
    #endif

    public init(_ category: String) {
        self.category = category
        #if canImport(os)
        logger = Logger(subsystem: AppIdentity.id, category: category)
        #endif
    }

    public func info(_ msg: String) { write("info", msg) }
    public func error(_ msg: String) { write("error", msg) }

    private static let toStderr: Bool = {
        #if canImport(os)
        return ProcessInfo.processInfo.environment["DL_LOG_STDERR"] == "1"
        #else
        return true
        #endif
    }()

    private func write(_ level: String, _ msg: String) {
        #if canImport(os)
        if level == "error" { logger.error("\(msg, privacy: .public)") } else { logger.info("\(msg, privacy: .public)") }
        #endif
        if Self.toStderr {
            let line = "\(ISO8601DateFormatter().string(from: Date())) level=\(level) cat=\(category) \(msg)\n"
            FileHandle.standardError.write(Data(line.utf8))
        }
    }
}

// MARK: - SHA256

public struct SHA256Stream {
    #if canImport(CryptoKit)
    private var h = CryptoKit.SHA256()
    public init() {}
    public mutating func update(_ data: Data) { h.update(data: data) }
    public func hex() -> String { h.finalize().map { String(format: "%02x", $0) }.joined() }
    #else
    private var state: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
    private var buffer = [UInt8]()
    private var length: UInt64 = 0
    public init() { buffer.reserveCapacity(64) }

    public mutating func update(_ data: Data) {
        length += UInt64(data.count)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let p = raw.bindMemory(to: UInt8.self)
            var i = 0
            if !buffer.isEmpty {
                let need = min(64 - buffer.count, p.count)
                buffer.append(contentsOf: p[0..<need]); i = need
                if buffer.count == 64 { buffer.withUnsafeBufferPointer { compress($0.baseAddress!) }; buffer.removeAll(keepingCapacity: true) }
            }
            while i + 64 <= p.count { compress(p.baseAddress! + i); i += 64 }
            if i < p.count { buffer.append(contentsOf: p[i..<p.count]) }
        }
    }

    public func hex() -> String {
        var copy = self
        var tail = copy.buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for s in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bits >> UInt64(s)) & 0xff)) }
        tail.withUnsafeBufferPointer { b in
            var off = 0
            while off < b.count { copy.compress(b.baseAddress! + off); off += 64 }
        }
        return copy.state.map { String(format: "%08x", $0) }.joined()
    }

    private static let k: [UInt32] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]

    @inline(__always) private func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }

    private mutating func compress(_ p: UnsafePointer<UInt8>) {
        // Stack buffer: no heap allocation per 64-byte block (15 GB = 250M blocks).
        withUnsafeTemporaryAllocation(of: UInt32.self, capacity: 64) { compress(p, w: $0) }
    }

    private mutating func compress(_ p: UnsafePointer<UInt8>, w: UnsafeMutableBufferPointer<UInt32>) {
        for i in 0..<16 {
            w[i] = UInt32(p[i * 4]) << 24 | UInt32(p[i * 4 + 1]) << 16 | UInt32(p[i * 4 + 2]) << 8 | UInt32(p[i * 4 + 3])
        }
        for i in 16..<64 {
            let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
            let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
            w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
        }
        var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4], f = state[5], g = state[6], h = state[7]
        for i in 0..<64 {
            let t1 = h &+ (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) &+ ((e & f) ^ (~e & g)) &+ Self.k[i] &+ w[i]
            let t2 = (rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) &+ ((a & b) ^ (a & c) ^ (b & c))
            h = g; g = f; f = e; e = d &+ t1; d = c; c = b; b = a; a = t1 &+ t2
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d
        state[4] &+= e; state[5] &+= f; state[6] &+= g; state[7] &+= h
    }
    #endif

    public static func hex(of data: Data) -> String { var s = SHA256Stream(); s.update(data); return s.hex() }
}

// MARK: - SHA1 (only for git blob ids of small HF files)

public struct SHA1Stream {
    #if canImport(CryptoKit)
    private var h = Insecure.SHA1()
    public init() {}
    public mutating func update(_ data: Data) { h.update(data: data) }
    public func hex() -> String { h.finalize().map { String(format: "%02x", $0) }.joined() }
    #else
    private var state: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
    private var buffer = [UInt8]()
    private var length: UInt64 = 0
    public init() {}

    public mutating func update(_ data: Data) {
        length += UInt64(data.count)
        buffer.append(contentsOf: data)
        var off = 0
        while buffer.count - off >= 64 {
            buffer.withUnsafeBufferPointer { compress($0.baseAddress! + off) }
            off += 64
        }
        buffer.removeFirst(off)
    }

    public func hex() -> String {
        var copy = self
        var tail = copy.buffer
        tail.append(0x80)
        while tail.count % 64 != 56 { tail.append(0) }
        let bits = length &* 8
        for s in stride(from: 56, through: 0, by: -8) { tail.append(UInt8((bits >> UInt64(s)) & 0xff)) }
        tail.withUnsafeBufferPointer { b in
            var off = 0
            while off < b.count { copy.compress(b.baseAddress! + off); off += 64 }
        }
        return copy.state.map { String(format: "%08x", $0) }.joined()
    }

    private mutating func compress(_ p: UnsafePointer<UInt8>) {
        var w = [UInt32](repeating: 0, count: 80) // small files only: allocation is fine
        for i in 0..<16 { w[i] = UInt32(p[i * 4]) << 24 | UInt32(p[i * 4 + 1]) << 16 | UInt32(p[i * 4 + 2]) << 8 | UInt32(p[i * 4 + 3]) }
        for i in 16..<80 { let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]; w[i] = (x << 1) | (x >> 31) }
        var a = state[0], b = state[1], c = state[2], d = state[3], e = state[4]
        for i in 0..<80 {
            let (f, k): (UInt32, UInt32)
            switch i {
            case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
            case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
            case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
            default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
            }
            let t = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
            e = d; d = c; c = (b << 30) | (b >> 2); b = a; a = t
        }
        state[0] &+= a; state[1] &+= b; state[2] &+= c; state[3] &+= d; state[4] &+= e
    }
    #endif

    public static func hex(of data: Data) -> String { var s = SHA1Stream(); s.update(data); return s.hex() }
}

// MARK: - Token storage

#if !canImport(Security)
public typealias OSStatus = Int32
public let errSecSuccess: OSStatus = 0

/// Linux: ~/.config/modelpull/tokens.json, mode 600, dir mode 700.
public enum Keychain {
    static var file: URL { AppConfig.directory.appendingPathComponent("tokens.json") }

    private static func load() -> [String: String] {
        guard let d = try? Data(contentsOf: file) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: d)) ?? [:]
    }

    public static func get(_ account: String) -> String? { load()[account] }

    @discardableResult
    public static func set(_ value: String, for account: String) -> OSStatus {
        var all = load()
        all[account] = value.isEmpty ? nil : value
        let fm = FileManager.default
        let dir = file.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let tmp = dir.appendingPathComponent(".tokens.tmp")
            try? fm.removeItem(at: tmp)
            guard fm.createFile(atPath: tmp.path, contents: try JSONEncoder().encode(all), attributes: [.posixPermissions: 0o600]) else { return -1 }
            // POSIX rename: atomic overwrite. (FileManager.replaceItemAt is broken on Linux corelibs.)
            guard rename(tmp.path, file.path) == 0 else {
                Log("tokens").error("rename failed errno=\(errno)")
                return -1
            }
            return errSecSuccess
        } catch {
            Log("tokens").error("save failed error=\(error.localizedDescription)")
            return -1
        }
    }

    public static func tokens() -> Tokens { Tokens(huggingface: get("huggingface"), civitai: get("civitai")) }
}
#endif
