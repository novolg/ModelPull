import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import DLCore

// ModelPull for Linux (also runs on macOS): local web UI on http://127.0.0.1:<port>.
// Usage: modelpull [--port 8765] [--no-open]

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let port: UInt16 = args.firstIndex(of: "--port").flatMap { args.indices.contains($0 + 1) ? UInt16(args[$0 + 1]) : nil } ?? 8765
let shouldOpen = !args.contains("--no-open")
let base = "http://127.0.0.1:\(port)"
let log = Log("main")

func launch(_ tool: String, _ arguments: [String]) {
    let p = Process()
    #if os(Linux)
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = [tool] + arguments
    #else
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = arguments
    #endif
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { log.error("launch failed tool=\(tool) error=\(error.localizedDescription)") }
}

func openInBrowser() { launch("xdg-open", [base]) }

struct AddBody: Decodable { let url: String }
struct TokensBody: Decodable { let huggingface: String?; let civitai: String? }

LegacyData.migrate()
let manager = Manager()
await manager.load()

let server = HTTPServer(port: port) { req in
    // Only same-machine page may talk to us: Host check (DNS rebinding) + custom header on POST (cross-site forms can't set it).
    let host = req.headers["host"] ?? ""
    guard host == "127.0.0.1:\(port)" || host == "localhost:\(port)" else { return .text("forbidden host", status: 403) }
    if req.method == "POST", req.headers["x-modelpull"] != "1" { return .text("forbidden", status: 403) }

    let parts = req.path.split(separator: "/").map(String.init)
    switch (req.method, parts) {
    case ("GET", []): return .html(Page.html)
    case ("GET", ["api", "ping"]): return .text("modelpull")
    case ("GET", ["icon.png"]): return HTTPResponse(status: 200, contentType: "image/png", body: LogoImage.png)
    case ("GET", ["api", "state"]): return .json(await manager.snapshot())
    case ("GET", ["api", "dirs"]):
        guard let d = manager.dirs(req.query["path"] ?? "~") else { return .error("Cannot open folder.") }
        return .json(d)
    case ("POST", ["api", "add"]):
        guard let b = try? JSONDecoder().decode(AddBody.self, from: req.body) else { return .error("Bad request.") }
        if let e = await manager.add(b.url) { return .error(e) }
        return .json(["ok": true])
    case ("POST", ["api", "settings"]):
        guard let s = try? JSONDecoder().decode(Manager.Settings.self, from: req.body) else { return .error("Bad request.") }
        if let e = await manager.update(settings: s) { return .error(e) }
        return .json(["ok": true])
    case ("POST", ["api", "tokens"]):
        guard let b = try? JSONDecoder().decode(TokensBody.self, from: req.body) else { return .error("Bad request.") }
        var status = errSecSuccess
        if let v = b.huggingface { status = Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: "huggingface") }
        if status == errSecSuccess, let v = b.civitai { status = Keychain.set(v.trimmingCharacters(in: .whitespacesAndNewlines), for: "civitai") }
        return status == errSecSuccess ? .json(["ok": true]) : .error("Cannot save tokens.", status: 500)
    case ("POST", _) where parts.count == 4 && parts[0] == "api" && parts[1] == "jobs":
        guard let id = UUID(uuidString: parts[2]) else { return .error("Bad id.") }
        switch parts[3] {
        case "pause": await manager.pause(id)
        case "resume": await manager.resume(id)
        case "restart": await manager.restart(id)
        case "remove": await manager.remove(id, deleteFile: false)
        case "delete": await manager.remove(id, deleteFile: true)
        case "reveal": if let p = await manager.revealPath(id) { launch("xdg-open", [p]) }
        default: return .error("Unknown action.", status: 404)
        }
        return .json(["ok": true])
    case ("POST", ["api", "quit"]):
        log.info("quit requested")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { exit(0) }
        return .json(["ok": true])
    default:
        return .text("not found", status: 404)
    }
}

do {
    try server.start()
} catch ServerError.inUse {
    // Already running? Then just show it.
    if let (d, _) = try? await URLSession.shared.dlData(for: URLRequest(url: URL(string: "\(base)/api/ping")!)), String(data: d, encoding: .utf8) == "modelpull" {
        print("ModelPull already running at \(base)")
        if shouldOpen { openInBrowser() }
        exit(0)
    }
    print("Port \(port) is busy. Start with: modelpull --port 8766")
    exit(1)
} catch {
    print("Cannot start server: \(error)")
    exit(1)
}

print("ModelPull running at \(base)  (close this terminal or use Quit in the page to stop)")
if shouldOpen { openInBrowser() }
while true { try? await Task.sleep(nanoseconds: 3_600_000_000_000) }
