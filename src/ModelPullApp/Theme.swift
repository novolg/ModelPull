import SwiftUI

/// Monochrome dark UI kit: near-black ground, soft panels, tiny tracked caps labels.
enum T {
    static let bg = Color(white: 0.04)
    static let panel = Color(white: 0.075)
    static let field = Color(white: 0.105)
    static let fieldHover = Color(white: 0.13)
    static let stroke = Color.white.opacity(0.07)
    static let text = Color(white: 0.93)
    static let dim = Color(white: 0.55)
    static let faint = Color(white: 0.36)
    static let mono = Font.system(size: 11).monospacedDigit()
}

struct CapsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(T.dim)
    }
}

struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }
            .font(.system(size: 12))
            .foregroundStyle(T.text)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(T.field, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(T.stroke))
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(T.panel, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(T.stroke))
    }
}

struct SoftButtonStyle: ButtonStyle {
    var primary = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(primary ? Color.black : T.text)
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(primary ? Color.white.opacity(configuration.isPressed ? 0.75 : 0.92)
                                : (configuration.isPressed ? T.fieldHover : T.field),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(primary ? .clear : T.stroke))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hover ? T.text : T.dim)
                .frame(width: 26, height: 26)
                .background(hover ? T.fieldHover : .clear, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Pill switch with "on"/"off" text inside the track, like the reference.
struct DarkToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 12) {
                ZStack {
                    Capsule().fill(configuration.isOn ? Color(white: 0.17) : Color(white: 0.09))
                        .overlay(Capsule().stroke(T.stroke))
                    HStack(spacing: 0) {
                        if configuration.isOn {
                            Text("on").font(.system(size: 8, weight: .medium)).foregroundStyle(T.dim)
                            Spacer()
                            Circle().fill(Color.white).frame(width: 7, height: 7)
                        } else {
                            Circle().fill(Color(white: 0.3)).frame(width: 7, height: 7)
                            Spacer()
                            Text("off").font(.system(size: 8, weight: .medium)).foregroundStyle(T.faint)
                        }
                    }
                    .padding(.horizontal, 9)
                }
                .frame(width: 48, height: 22)
                configuration.label.font(.system(size: 12)).foregroundStyle(T.text)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: configuration.isOn)
    }
}

struct RadioRow<V: Hashable>: View {
    let options: [(V, String)]
    @Binding var selection: V
    var body: some View {
        HStack(spacing: 18) {
            ForEach(options, id: \.0) { value, title in
                Button { selection = value } label: {
                    HStack(spacing: 8) {
                        ZStack {
                            Circle().stroke(selection == value ? T.text : T.faint, lineWidth: 1).frame(width: 12, height: 12)
                            if selection == value { Circle().fill(Color.white).frame(width: 6, height: 6) }
                        }
                        Text(title).font(.system(size: 12)).foregroundStyle(selection == value ? T.text : T.dim)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ProgressLine: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(white: 0.14))
                Capsule().fill(Color.white.opacity(0.9)).frame(width: max(0, min(1, fraction)) * g.size.width)
            }
        }
        .frame(height: 3)
        .animation(.linear(duration: 0.25), value: fraction)
    }
}

struct Tag: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 8.5, weight: .semibold)).tracking(1.2)
            .foregroundStyle(T.dim)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(Capsule().stroke(T.stroke))
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }

    static func duration(_ s: Double) -> String {
        guard s.isFinite, s > 0 else { return "" }
        let m = Int(s) / 60
        if m >= 60 { return "\(m / 60) h \(m % 60) min" }
        if m > 0 { return "\(m) min" }
        return "\(Int(s)) s"
    }
}
