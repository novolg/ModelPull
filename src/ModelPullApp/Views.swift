import SwiftUI
import AppKit
import DLCore

struct ContentView: View {
    @EnvironmentObject var store: JobStore
    @AppStorage(Prefs.saveDir) private var saveDir = ""
    @State private var link = ""
    @State private var error: String?
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                if let logo = NSImage(data: LogoImage.png) {
                    Image(nsImage: logo).resizable().interpolation(.high).frame(width: 18, height: 18)
                }
                Text("ModelPull").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text)
                Spacer()
                IconButton(symbol: "gearshape", help: "Settings") { showSettings = true }
            }

            VStack(alignment: .leading, spacing: 7) {
                CapsLabel("Link")
                HStack(spacing: 8) {
                    FieldBox {
                        TextField("", text: $link, prompt: Text("Paste Hugging Face or Civitai link").foregroundColor(T.faint))
                            .textFieldStyle(.plain)
                            .onSubmit(add)
                        Image(systemName: "link").font(.system(size: 11)).foregroundStyle(T.faint)
                    }
                    Button("Add", action: add).buttonStyle(SoftButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
                }
                if let error { Text(error).font(.system(size: 11)).foregroundStyle(T.dim) }
            }

            VStack(alignment: .leading, spacing: 7) {
                CapsLabel("Save to")
                Button(action: pickFolder) {
                    FieldBox {
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(T.faint)
                        Text((saveDir as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(T.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            HStack {
                CapsLabel("Downloads")
                Spacer()
                Text("\(store.jobs.count)").font(T.mono).foregroundStyle(T.faint)
            }
            .padding(.top, 4)

            if store.jobs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.circle").font(.system(size: 22, weight: .light)).foregroundStyle(T.faint)
                    Text("No downloads yet").font(.system(size: 12)).foregroundStyle(T.dim)
                    Text("Downloads survive drops, VPN switches and app restarts.").font(.system(size: 11)).foregroundStyle(T.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(store.jobs) { JobRow(job: $0) }
                    }
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 30)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(T.bg)
        .dropDestination(for: URL.self) { urls, _ in
            urls.forEach { link = $0.absoluteString; add() }
            return !urls.isEmpty
        }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }

    private func add() {
        guard !link.isEmpty else { return }
        error = store.add(link)
        if error == nil { link = "" }
    }

    private func pickFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.directoryURL = URL(fileURLWithPath: saveDir)
        if p.runModal() == .OK, let url = p.url { saveDir = url.path }
    }
}

struct JobRow: View {
    @EnvironmentObject var store: JobStore
    @ObservedObject var job: JobItem
    @State private var confirmRemove = false

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(job.displayName).font(.system(size: 12.5, weight: .medium)).foregroundStyle(T.text)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Tag(text: job.state.kind.label)
                }

                ProgressLine(fraction: fraction)

                HStack(spacing: 6) {
                    Text(stats).font(T.mono).foregroundStyle(T.dim)
                    Spacer()
                    actions
                }

                Text(statusText).font(.system(size: 11)).foregroundStyle(isFailed ? T.text : T.faint)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)

                if confirmRemove {
                    HStack(spacing: 8) {
                        Text("Remove from list?").font(.system(size: 11)).foregroundStyle(T.dim)
                        Spacer()
                        Button("Cancel") { confirmRemove = false }.buttonStyle(SoftButtonStyle())
                        if job.state.status == .done {
                            Button("Keep file") { store.remove(job, deleteFile: false) }.buttonStyle(SoftButtonStyle())
                            Button("Delete file") { store.remove(job, deleteFile: true) }.buttonStyle(SoftButtonStyle(primary: true))
                        } else {
                            Button("Remove + delete partial") { store.remove(job, deleteFile: false) }.buttonStyle(SoftButtonStyle(primary: true))
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch job.progress.phase {
        case .done:
            EmptyView()
        case .paused:
            IconButton(symbol: "play.fill", help: "Resume") { store.resume(job) }
        case .failed:
            IconButton(symbol: "arrow.clockwise", help: "Retry") { store.resume(job) }
            IconButton(symbol: "gobackward", help: "Restart from zero") { store.restartFromZero(job) }
        default:
            IconButton(symbol: "pause.fill", help: "Pause") { store.pause(job) }
        }
        IconButton(symbol: "folder", help: "Show in Finder") { store.reveal(job) }
        IconButton(symbol: "xmark", help: "Remove") { confirmRemove.toggle() }
    }

    private var isFailed: Bool { if case .failed = job.progress.phase { return true } else { return false } }

    private var fraction: Double {
        if case .verifying(let f) = job.progress.phase { return f }
        guard let t = job.progress.totalBytes, t > 0 else { return 0 }
        return Double(job.progress.doneBytes) / Double(t)
    }

    private var stats: String {
        let p = job.progress
        guard let total = p.totalBytes else { return "—" }
        if p.phase == .done { return Fmt.bytes(total) }
        var parts = ["\(Fmt.bytes(p.doneBytes)) / \(Fmt.bytes(total))"]
        if p.phase == .downloading, p.bytesPerSecond > 0 {
            parts.append("\(Fmt.bytes(Int64(p.bytesPerSecond)))/s")
            let eta = Fmt.duration(Double(total - p.doneBytes) / p.bytesPerSecond)
            if !eta.isEmpty { parts.append(eta) }
        }
        return parts.joined(separator: "  ·  ")
    }

    private var statusText: String {
        switch job.progress.phase {
        case .queued: return "Queued"
        case .resolving: return "Getting a fresh download link…"
        case .downloading: return "Downloading"
        case .waitingNetwork: return "No network. Waiting…"
        case .retrying(let reason, let s): return "\(reason) Retry in \(s) s."
        case .verifying(let f): return "Checking SHA256… \(Int(f * 100))%"
        case .paused: return "Paused"
        case .done: return job.state.doneLabel
        case .failed(let m): return m
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(Prefs.connections) private var connections = 4
    @AppStorage(Prefs.maxActive) private var maxActive = 1
    @AppStorage(Prefs.verifySHA) private var verifySHA = true
    @AppStorage(Prefs.keepAwake) private var keepAwake = true
    @State private var hf = Keychain.get("huggingface") ?? ""
    @State private var civitai = Keychain.get("civitai") ?? ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Settings").font(.system(size: 13, weight: .semibold)).foregroundStyle(T.text)

            VStack(alignment: .leading, spacing: 7) {
                CapsLabel("Hugging Face token")
                FieldBox { SecureField("", text: $hf, prompt: Text("hf_…").foregroundColor(T.faint)).textFieldStyle(.plain) }
                Text("For gated or private models. huggingface.co/settings/tokens").font(.system(size: 10.5)).foregroundStyle(T.faint)
            }
            VStack(alignment: .leading, spacing: 7) {
                CapsLabel("Civitai API key")
                FieldBox { SecureField("", text: $civitai, prompt: Text("API key").foregroundColor(T.faint)).textFieldStyle(.plain) }
                Text("For models that need login. civitai.com/user/account").font(.system(size: 10.5)).foregroundStyle(T.faint)
            }

            VStack(alignment: .leading, spacing: 9) {
                CapsLabel("Connections per file")
                RadioRow(options: [(2, "2"), (4, "4"), (8, "8")], selection: $connections)
            }
            VStack(alignment: .leading, spacing: 9) {
                CapsLabel("Downloads at once")
                RadioRow(options: [(1, "1"), (2, "2"), (3, "3")], selection: $maxActive)
            }

            VStack(alignment: .leading, spacing: 10) {
                Toggle("Check SHA256 after download", isOn: $verifySHA).toggleStyle(DarkToggleStyle())
                Toggle("Keep Mac awake while downloading", isOn: $keepAwake).toggleStyle(DarkToggleStyle())
            }

            if let saveError { Text(saveError).font(.system(size: 11)).foregroundStyle(T.text) }

            HStack {
                Text("Tokens are stored in macOS Keychain.").font(.system(size: 10.5)).foregroundStyle(T.faint)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(SoftButtonStyle())
                Button("Save", action: save).buttonStyle(SoftButtonStyle(primary: true)).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 420)
        .background(T.panel)
    }

    private func save() {
        let a = Keychain.set(hf.trimmingCharacters(in: .whitespacesAndNewlines), for: "huggingface")
        let b = Keychain.set(civitai.trimmingCharacters(in: .whitespacesAndNewlines), for: "civitai")
        guard a == errSecSuccess, b == errSecSuccess else { saveError = "Keychain error (\(a), \(b))."; return }
        dismiss()
    }
}
