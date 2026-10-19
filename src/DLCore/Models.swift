import Foundation

public enum SourceKind: String, Codable, Sendable {
    case huggingface, civitai, direct

    public var label: String {
        switch self {
        case .huggingface: return "HF"
        case .civitai: return "CIVITAI"
        case .direct: return "URL"
        }
    }
}

/// Short-lived download target. Re-created on every retry cycle — never persisted.
public struct ResolvedTarget: Sendable {
    public var directURL: URL
    public var fileName: String
    public var sha256: String?          // lowercase hex, nil when source gives none
    public var headers: [String: String] // extra headers for the data request (auth only for same-host files)
    public var gitSHA1: String?          // HF non-LFS files: git blob SHA1 (sha1("blob <size>\0" + content))
    public var revision: String?         // HF commit the link resolved to; later retries pin to it

    public init(directURL: URL, fileName: String, sha256: String?, headers: [String: String] = [:],
                gitSHA1: String? = nil, revision: String? = nil) {
        self.gitSHA1 = gitSHA1
        self.revision = revision
        self.directURL = directURL
        self.fileName = fileName
        self.sha256 = sha256
        self.headers = headers
    }
}

public struct Tokens: Sendable {
    public var huggingface: String?
    public var civitai: String?
    public init(huggingface: String? = nil, civitai: String? = nil) {
        self.huggingface = huggingface
        self.civitai = civitai
    }
}

public enum DLError: Error, LocalizedError, Equatable {
    case unsupportedURL
    case authRequired(SourceKind)
    case notFound
    case linkExpired(Int)          // CDN refused signed URL -> re-resolve
    case http(Int)                 // retryable server status
    case rangeNotSupported
    case badRange(String)
    case sizeChanged(old: Int64, new: Int64)
    case hashMismatch               // only after partial repair AND full re-download both failed
    case sourceChanged              // server now serves a different file (new hash) -> never mix versions
    case unsafeFileName             // name from server / saved state is not a safe single path component
    case badResponse(String)
    case disk(String)

    /// Fatal = retrying cannot help without user action.
    public var isFatal: Bool {
        switch self {
        case .unsupportedURL, .authRequired, .notFound, .sizeChanged, .hashMismatch, .sourceChanged, .unsafeFileName, .disk: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL: return "Link not supported. Use a Hugging Face or Civitai link."
        case .authRequired(let k):
            return k == .civitai ? "Civitai needs an API key for this file. Add it in Settings, then Retry."
                                 : "Hugging Face needs a token (gated or private model). Add it in Settings, then Retry."
        case .notFound: return "File not found (404)."
        case .linkExpired(let s): return "Download link expired (\(s)). Getting a new one."
        case .http(let s): return "Server error \(s)."
        case .rangeNotSupported: return "Server ignored resume request."
        case .badRange(let m): return "Bad partial response: \(m)"
        case .sizeChanged(let o, let n): return "File on server changed (\(o) → \(n) bytes). Restart from zero."
        case .hashMismatch: return "File failed the hash check even after a full re-download. Stopped; the file was not saved."
        case .unsafeFileName: return "The file name from the server is not safe to use. Stopped; nothing was written outside the folder."
        case .sourceChanged: return "The file on the server changed (new version). Stopped so versions are not mixed. Restart from zero."
        case .badResponse(let m): return "Unexpected response: \(m)"
        case .disk(let m): return "Disk error: \(m)"
        }
    }
}

public enum Phase: Sendable, Equatable {
    case queued
    case resolving
    case downloading
    case waitingNetwork
    case retrying(reason: String, inSeconds: Int)
    case verifying(fraction: Double)
    case paused
    case done
    case failed(String)

    public var isActive: Bool {
        switch self {
        case .resolving, .downloading, .waitingNetwork, .retrying, .verifying: return true
        default: return false
        }
    }
}

public struct ProgressSnapshot: Sendable, Equatable {
    public var phase: Phase
    public var fileName: String?
    public var totalBytes: Int64?
    public var doneBytes: Int64
    public var bytesPerSecond: Double

    public init(phase: Phase, fileName: String?, totalBytes: Int64?, doneBytes: Int64, bytesPerSecond: Double) {
        self.phase = phase
        self.fileName = fileName
        self.totalBytes = totalBytes
        self.doneBytes = doneBytes
        self.bytesPerSecond = bytesPerSecond
    }
}
