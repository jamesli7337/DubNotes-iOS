import UIKit
import SwiftUI

/// A row of colour swatches for a tool, then an "add colour" button. Position 0 is the tool's primary colour
/// (dotted ring, and the colour a note opens on). Swatches reorder by dragging; a long press removes one.
struct SwatchRow: View {
    let session: NotebookSession
    let tool: InkTool
    let current: String?
    let onPick: (String) -> Void

    @State private var adding = false

    private var colors: [String] { session.settings.swatches(tool) }

    private var paper: Paper { session.currentPage?.paper ?? .default }

    var body: some View {
        HStack(spacing: 10) {
            ForEach(colors, id: \.self) { c in swatch(c) }
            Button { adding = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add colour")
            .popover(isPresented: $adding) {
                ColorPickerPopover(session: session, tool: tool) { hex in
                    var s = session.settings
                    s.addCustomColor(tool, hex: hex)
                    session.settings = s
                    onPick(hex.lowercased())
                }
            }
        }
    }

    private func fill(_ c: String) -> Color {
        Color(hex: PaperStyle.resolve(c, on: paper))
    }

    private func swatch(_ c: String) -> some View {
        let isAuto = c == PaperStyle.autoColor
        let isPrimary = colors.first == c
        return Button { onPick(c) } label: {
            Circle()
                .fill(fill(c))
                .frame(width: 28, height: 28)
                .overlay {
                    if isAuto {
                        Text("A").font(.system(size: 12, weight: .bold))
                            .foregroundStyle(paper.color == .dark ? Color.black.opacity(0.7) : Color.white.opacity(0.85))
                    }
                }
                .overlay(Circle().strokeBorder(Color(.separator), lineWidth: 0.5))
                .overlay {
                    if isPrimary { Circle().strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [2, 2])).foregroundStyle(.secondary).padding(-4) }
                }
                .overlay {
                    if c == current { Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).padding(-3) }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isAuto ? "Ink auto — adapts to paper" : "Ink \(c)")
        .draggable(c)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first else { return false }
            var s = session.settings
            s.setSwatchOrder(tool, colors.moving(dragged, before: c))
            session.settings = s
            return true
        }
        .contextMenu {
            if !isPrimary {
                Button(role: .destructive) {
                    var s = session.settings
                    s.removeSwatch(tool, c)
                    session.settings = s
                } label: { Label("Remove colour", systemImage: "trash") }
            }
        }
    }
}

/// Saturation / value square, hue strip and hex field; presets that were removed can be brought back.
struct ColorPickerPopover: View {
    let session: NotebookSession
    let tool: InkTool
    let onAdd: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var hue = 0.6
    @State private var sat = 0.7
    @State private var val = 0.85
    @State private var hexText = ""
    @State private var seeded = false

    private var color: Color { Color(hue: hue, saturation: sat, brightness: val) }

    private var hex: String {
        let ui = UIColor(hue: hue, saturation: sat, brightness: val, alpha: 1)
        return ui.rgb.hex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GeometryReader { geo in
                ZStack {
                    LinearGradient(colors: [.white, Color(hue: hue, saturation: 1, brightness: 1)], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    Circle().strokeBorder(.white, lineWidth: 2)
                        .background(Circle().fill(color))
                        .frame(width: 20, height: 20)
                        .position(x: sat * geo.size.width, y: (1 - val) * geo.size.height)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    sat = min(max(g.location.x / geo.size.width, 0), 1)
                    val = 1 - min(max(g.location.y / geo.size.height, 0), 1)
                    hexText = hex
                })
            }
            .frame(height: 150)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.1).map { Color(hue: $0, saturation: 1, brightness: 1) },
                                   startPoint: .leading, endPoint: .trailing)
                        .clipShape(Capsule())
                    Circle().strokeBorder(.white, lineWidth: 2)
                        .background(Circle().fill(Color(hue: hue, saturation: 1, brightness: 1)))
                        .frame(width: 22, height: 22)
                        .offset(x: hue * (geo.size.width - 22))
                }
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    hue = min(max(g.location.x / geo.size.width, 0), 1)
                    hexText = hex
                })
            }
            .frame(height: 22)

            HStack {
                Circle().fill(color).frame(width: 28, height: 28)
                TextField("#rrggbb", text: $hexText)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { applyHex() }
            }

            let deleted = session.settings.deletedPresets(tool)
            if !deleted.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Removed colours").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(deleted, id: \.self) { c in
                            Button {
                                var s = session.settings
                                s.restorePreset(tool, c)
                                session.settings = s
                            } label: {
                                Circle().fill(Color(hex: PaperStyle.resolve(c, on: .default))).frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Restore \(c)")
                        }
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Add") {
                    applyHex()
                    onAdd(hex)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 280)
        .onAppear {
            guard !seeded else { return }
            seeded = true
            let seed = session.settings.color(tool)
            let resolved = seed == PaperStyle.autoColor ? "#2563eb" : seed
            if let rgb = RGB(hex: resolved) {
                var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
                UIColor(rgb).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
                hue = Double(h); sat = Double(s); val = Double(b)
            }
            hexText = hex
        }
    }

    private func applyHex() {
        guard let rgb = RGB(hex: hexText) else { hexText = hex; return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(rgb).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        hue = Double(h); sat = Double(s); val = Double(b)
        hexText = hex
    }
}

/// The collapsed size control: a dot previewing the true on-page width, opening a slider in a popover.
struct SizeButton: View {
    let session: NotebookSession
    let tool: InkTool

    @State private var open = false

    private var size: Double { session.settings.size(tool) }

    var body: some View {
        Button { open = true } label: {
            let d = min(size * Double(session.column?.zoom ?? 1), 18)
            ZStack {
                Capsule().strokeBorder(Color(.separator), lineWidth: 1)
                RoundedRectangle(cornerRadius: tool == .pen ? d / 2 : 2)
                    .fill(Color.primary.opacity(tool == .pen ? 1 : 0.5))
                    .frame(width: max(d, 3), height: tool == .pen ? max(d, 3) : max(3, d * 0.5))
            }
            .frame(width: 44, height: 32)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Size")
        .popover(isPresented: $open) { SizePanel(session: session, tool: tool) }
    }
}

struct SizePanel: View {
    let session: NotebookSession
    let tool: InkTool

    /// A dragged value within this much of a whole number lands exactly on it.
    static let snapRadius = 0.25

    var body: some View {
        let range = ToolSettings.sizeRange(tool)
        VStack(spacing: 10) {
            Slider(value: Binding(get: { session.settings.size(tool) }, set: { v in
                var value = v
                let whole = v.rounded()
                if range.contains(whole) && abs(v - whole) <= Self.snapRadius { value = whole }
                var s = session.settings
                s.setSize(tool, value)
                session.settings = s
            }), in: range, step: 0.1)
            .frame(width: 220)
            Text(String(format: "%.1f", session.settings.size(tool)))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .accessibilityLabel("\(tool == .pen ? "Pen" : "Highlighter") size")
    }
}
