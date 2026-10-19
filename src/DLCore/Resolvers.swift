import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public protocol Resolver: Sendable {
    /// Turn the permanent source link into a fresh, short-lived direct link.
    func resolve(_ source: URL, tokens: Tokens) async throws -> ResolvedTarget
}

public enum SourceParser {
    public static func kind(of url: URL) -> SourceKind? {
        guard let host = url.host?.lowercased(), url.scheme == "https" || url.scheme == "http" else { return nil }
        if host == "huggingface.co" || host == "hf.co" || host.hasSuffix(".huggingface.co") { return HFResolver.resolveURL(from: url) == nil ? nil : .huggingface }
        if host == "civitai.com" || host.hasSuffix(".civitai.com") { return CivitaiResolver.parse(url) == nil ? nil : .civitai }
        return .direct
    }
}

/// Routes by source kind.
public struct RouterResolver: Resolver {
    let session: URLSession
    public init(session: URLSession = NoRedirect.makeSession()) { self.session = session }

    public func resolve(_ source: URL, tokens: Tokens) async throws -> ResolvedTarget {
        switch SourceParser.kind(of: source) {
        case .huggingface: return try await HFResolver(session: session).resolve(source, tokens: tokens)
        case .civitai: return try await CivitaiResolver(session: session).resolve(source, tokens: tokens)
        case .direct: return ResolvedTarget(directURL: source, fileName: source.lastPathComponent.isEmpty ? "download" : source.lastPathComponent, sha256: nil)
        case nil: throw DLError.unsupportedURL
        }
    }
}

// MARK: - Hugging Face

public struct HFResolver: Resolver {
    let session: URLSession

    /// Accepts .../resolve/<rev>/<path> and .../blob/<rev>/<path>; returns canonical resolve URL.
    public static func resolveURL(from url: URL) -> URL? {
        var parts = url.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(where: { $0 == "resolve" || $0 == "blob" }),
              i >= 2, parts.count >= i + 3 else { return nil }
        parts[i] = "resolve"
        var c = URLComponents()
        c.scheme = "https"
        c.host = "huggingface.co"
        c.path = "/" + parts.joined(separator: "/")
        return c.url
    }

    /// Same file, but at a fixed commit instead of a branch like `main`.
    public static func pinned(_ url: URL, revision: String) -> URL? {
        guard let canonical = resolveURL(from: url) else { return nil }
        var parts = canonical.path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "resolve") else { return nil }
        parts[i + 1] = revision
        var c = URLComponents()
        c.scheme = "https"
        c.host = "huggingface.co"
        c.path = "/" + parts.joined(separator: "/")
        return c.url
    }

    public func resolve(_ source: URL, tokens: Tokens) async throws -> ResolvedTarget {
        guard var url = Self.resolveURL(from: source) else { throw DLError.unsupportedURL }
        let fileName = url.lastPathComponent
        var sha: String?
        var gitSHA1: String?
        var revision: String?
        var auth: [String: String] = [:]
        if let t = tokens.huggingface, !t.isEmpty { auth["Authorization"] = "Bearer \(t)" }

        for _ in 0..<6 {
            // GET + Range 0-0 instead of HEAD: Linux FoundationNetworking hangs on HEAD until timeout.
            var req = URLRequest(url: url)
            req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
            auth.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            let (_, resp) = try await NoRedirect.send(req, session: session)

            // LFS files: X-Linked-Etag = SHA256. Small git files: (X-Linked-)ETag = git blob SHA1.
            for h in ["X-Linked-Etag", "ETag"] {
                guard let v = resp.value(forHTTPHeaderField: h) else { continue }
                if sha == nil, let s = Hex.sha256(from: v) { sha = s }
                if gitSHA1 == nil, let g = Hex.sha1(from: v) { gitSHA1 = g }
            }
            if revision == nil, let r = resp.value(forHTTPHeaderField: "X-Repo-Commit"), Hex.sha1(from: r) != nil { revision = r.lowercased() }

            switch resp.statusCode {
            case 200, 206:
                // Small non-LFS file served by huggingface.co itself: keep auth (same host).
                return ResolvedTarget(directURL: url, fileName: fileName, sha256: sha, headers: auth,
                                      gitSHA1: sha == nil ? gitSHA1 : nil, revision: revision)
            case 301, 302, 303, 307, 308:
                guard let loc = resp.value(forHTTPHeaderField: "Location"),
                      let next = URL(string: loc, relativeTo: url)?.absoluteURL else { throw DLError.badResponse("redirect without Location") }
                if next.host == url.host { url = next; continue }      // internal HF redirect (renamed repo etc.)
                // signed CDN link, no auth header
                return ResolvedTarget(directURL: next, fileName: fileName, sha256: sha, gitSHA1: sha == nil ? gitSHA1 : nil, revision: revision)
            case 401, 403: throw DLError.authRequired(.huggingface)
            case 404: throw DLError.notFound
            default: throw DLError.http(resp.statusCode)
            }
        }
        throw DLError.badResponse("too many redirects")
    }
}

// MARK: - Civitai

public struct CivitaiResolver: Resolver {
    let session: URLSession
    static let api = "https://civitai.com/api"

    public enum Ref: Equatable { case version(Int, downloadURL: URL?), model(Int) }

    public static func parse(_ url: URL) -> Ref? {
        let parts = url.path.split(separator: "/").map(String.init)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        // /api/download/models/<versionId>[?type=..&format=..]
        if parts.count >= 4, parts[0] == "api", parts[1] == "download", parts[2] == "models", let v = Int(parts[3]) {
            return .version(v, downloadURL: url)
        }
        // /models/<modelId>[/slug][?modelVersionId=<v>]
        if parts.count >= 2, parts[0] == "models", let m = Int(parts[1]) {
            if let v = query.first(where: { $0.name == "modelVersionId" })?.value.flatMap(Int.init) { return .version(v, downloadURL: nil) }
            return .model(m)
        }
        return nil
    }

    struct VersionDTO: Decodable {
        struct File: Decodable {
            struct Hashes: Decodable { let SHA256: String? }
            let name: String
            let primary: Bool?
            let downloadUrl: String?
            let hashes: Hashes?
        }
        let id: Int
        let files: [File]
    }
    struct ModelDTO: Decodable { struct V: Decodable { let id: Int }; let modelVersions: [V] }

    public func resolve(_ source: URL, tokens: Tokens) async throws -> ResolvedTarget {
        guard let ref = Self.parse(source) else { throw DLError.unsupportedURL }
        let token = tokens.civitai.flatMap { $0.isEmpty ? nil : $0 }

        var versionId: Int
        var explicitDownload: URL?
        switch ref {
        case .version(let v, let d): versionId = v; explicitDownload = d
        case .model(let m):
            let model: ModelDTO = try await getJSON("\(Self.api)/v1/models/\(m)", token: token)
            guard let first = model.modelVersions.first else { throw DLError.notFound }
            versionId = first.id
        }

        let version: VersionDTO = try await getJSON("\(Self.api)/v1/model-versions/\(versionId)", token: token)
        let file = version.files.first(where: { f in
            guard let e = explicitDownload, let d = f.downloadUrl.flatMap(URL.init(string:)) else { return false }
            return d.path == e.path && (e.query == nil || d.query == e.query)
        }) ?? version.files.first(where: { $0.primary == true }) ?? version.files.first
        guard let file else { throw DLError.notFound }
        guard let dl = explicitDownload ?? file.downloadUrl.flatMap(URL.init(string:)) else { throw DLError.notFound }

        // Ask download endpoint for the signed CDN link. Range 0-0 keeps body tiny if it serves the file directly.
        var req = URLRequest(url: dl)
        req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        var auth: [String: String] = [:]
        if let token { auth["Authorization"] = "Bearer \(token)" }
        auth.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (_, resp) = try await NoRedirect.send(req, session: session)
        let sha = file.hashes?.SHA256.flatMap(Hex.sha256(from:))

        switch resp.statusCode {
        case 301, 302, 303, 307, 308:
            guard let loc = resp.value(forHTTPHeaderField: "Location"),
                  let next = URL(string: loc, relativeTo: dl)?.absoluteURL else { throw DLError.badResponse("redirect without Location") }
            if next.host?.hasSuffix("civitai.com") == true, next.path.lowercased().contains("login") {
                throw DLError.authRequired(.civitai)
            }
            return ResolvedTarget(directURL: next, fileName: file.name, sha256: sha)
        case 200, 206:
            return ResolvedTarget(directURL: dl, fileName: file.name, sha256: sha, headers: auth)
        case 401, 403: throw DLError.authRequired(.civitai)
        case 404: throw DLError.notFound
        default: throw DLError.http(resp.statusCode)
        }
    }

    private func getJSON<T: Decodable>(_ s: String, token: String?) async throws -> T {
        var req = URLRequest(url: URL(string: s)!)
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await NoRedirect.send(req, session: session)
        switch resp.statusCode {
        case 200: break
        case 401, 403: throw DLError.authRequired(.civitai)
        case 404: throw DLError.notFound
        default: throw DLError.http(resp.statusCode)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw DLError.badResponse("Civitai API JSON: \(error.localizedDescription)") }
    }
}

// MARK: - Helpers

public enum Hex {
    /// Extract a 64-char hex SHA256 from an ETag-like string (quotes, W/ prefix, any case).
    public static func sha256(from raw: String) -> String? {
        let s = raw.replacingOccurrences(of: "W/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        guard s.count == 64, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return s
    }

    /// 40-char hex (git blob SHA1 / commit id).
    public static func sha1(from raw: String) -> String? {
        let s = raw.replacingOccurrences(of: "W/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\" ")).lowercased()
        guard s.count == 40, s.allSatisfy({ $0.isHexDigit }) else { return nil }
        return s
    }
}

public enum NoRedirect {
    final class Delegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil) // surface 3xx to caller
        }
    }

    public static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 30
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: Delegate(), delegateQueue: nil)
    }

    static func send(_ req: URLRequest, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.dlData(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DLError.badResponse("not HTTP") }
        return (data, http)
    }
}
