import Foundation
#if canImport(Glibc)
import Glibc
#endif
import DLCore

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String] // lowercased keys
    let body: Data
}

struct HTTPResponse {
    var status: Int
    var contentType: String
    var body: Data

    static func json<T: Encodable>(_ v: T, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, contentType: "application/json", body: (try? JSONEncoder().encode(v)) ?? Data("{}".utf8))
    }
    static func error(_ msg: String, status: Int = 400) -> HTTPResponse { json(["error": msg], status: status) }
    static func text(_ s: String, status: Int = 200) -> HTTPResponse { HTTPResponse(status: status, contentType: "text/plain; charset=utf-8", body: Data(s.utf8)) }
    static func html(_ s: String) -> HTTPResponse { HTTPResponse(status: 200, contentType: "text/html; charset=utf-8", body: Data(s.utf8)) }
}

enum ServerError: Error { case inUse, socket(String) }

/// Minimal HTTP/1.1 server (one request per connection). Binds 127.0.0.1 only.
final class HTTPServer: @unchecked Sendable {
    let port: UInt16
    private let handler: @Sendable (HTTPRequest) async -> HTTPResponse
    private var listenFD: Int32 = -1
    private let log = Log("http")

    init(port: UInt16, handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        signal(SIGPIPE, SIG_IGN)
        #if os(Linux)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw ServerError.socket(String(cString: strerror(errno))) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 {
            let e = errno
            close(fd)
            throw e == EADDRINUSE ? ServerError.inUse : ServerError.socket(String(cString: strerror(e)))
        }
        guard listen(fd, 64) == 0 else { throw ServerError.socket(String(cString: strerror(errno))) }
        listenFD = fd

        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; log.error("accept failed errno=\(errno)"); continue }
                DispatchQueue.global().async { self.serve(client) }
            }
        }
    }

    private func serve(_ fd: Int32) {
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard let req = readRequest(fd) else { close(fd); return }
        Task {
            let resp = await handler(req)
            write(fd, resp)
            close(fd)
        }
    }

    private func readRequest(_ fd: Int32) -> HTTPRequest? {
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 16 * 1024)
        let sep = Data("\r\n\r\n".utf8)
        var headerEnd: Range<Data.Index>?
        while headerEnd == nil {
            let n = recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { return nil }
            buf.append(contentsOf: tmp[0..<n])
            headerEnd = buf.range(of: sep)
            if buf.count > 64 * 1024 { return nil }
        }
        guard let end = headerEnd, let head = String(data: buf[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        // Reject malformed framing before constructing a Data prefix (negative
        // lengths trap). This server does not implement transfer encodings.
        let rawLength = headers["content-length"] ?? "0"
        guard headers["transfer-encoding"] == nil,
              !rawLength.isEmpty, rawLength.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let length = Int(rawLength), length <= 1 << 20 else { return nil }
        var body = Data(buf[end.upperBound...])
        while body.count < length {
            let n = recv(fd, &tmp, tmp.count, 0)
            if n <= 0 { return nil }
            body.append(contentsOf: tmp[0..<n])
        }
        let target = String(first[1])
        let comps = URLComponents(string: "http://x" + target)
        var query: [String: String] = [:]
        comps?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        return HTTPRequest(method: String(first[0]), path: comps?.path ?? target, query: query, headers: headers, body: body.prefix(length))
    }

    private func write(_ fd: Int32, _ r: HTTPResponse) {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"][r.status] ?? "OK"
        let head = "HTTP/1.1 \(r.status) \(reason)\r\nContent-Type: \(r.contentType)\r\nContent-Length: \(r.body.count)\r\n"
            + "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(r.body)
        out.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var sent = 0
            while sent < p.count {
                let n = send(fd, p.baseAddress! + sent, p.count - sent, 0)
                if n <= 0 { if errno == EINTR { continue }; return }
                sent += n
            }
        }
    }
}
