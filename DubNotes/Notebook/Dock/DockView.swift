import SwiftUI

extension ToolKind {
    var symbol: String {
        switch self {
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .text: return "textformat"
        case .shapes: return "square.on.circle"
        case .tape: return "bandage"
        case .laser: return "scope"
        case .hand: return "hand.raised"
        }
    }

    var label: String {
        switch self {
        case .pen: return "Pen"
        case .highlighter: return "Highlighter"
        case .eraser: return "Eraser"
        case .lasso: return "Lasso select"
        case .text: return "Text"
        case .shapes: return "Shapes"
        case .tape: return "Tape"
        case .laser: return "Laser pointer"
        case .hand: return "Hand — drag to pan with pen or finger"
        }
    }
}

extension LassoShape {
    var symbol: String {
        switch self {
        case .free: return "lasso"
        case .box: return "rectangle.dashed"
        case .circle: return "circle.dashed"
        }
    }

    var label: String {
        switch self {
        case .free: return "Freehand lasso"
        case .box: return "Box select"
        case .circle: return "Circle select"
        }
    }
}

extension PlacedShape {
    var symbol: String {
        switch self {
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        case .arrow: return "arrow.up.right"
        }
    }

    var label: String {
        switch self {
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .arrow: return "Arrow"
        case .triangle: return "Triangle"
        }
    }
}

/// The floating dock: every tool in the user's order, the drawing aids, undo / redo, and below them a row of
/// options for the active tool. Re-tapping the active tool folds the options row away.
struct DockView: View {
    let session: NotebookSession
    @Binding var optionsOpen: Bool
    let onEraserMenu: () -> Void

    private var settings: ToolSettings { session.settings }

    var body: some View {
        VStack(spacing: 0) {
            toolRow
            if optionsOpen {
                SwiftUI.Divider().padding(.horizontal, 10)
                optionsRow
                    .frame(minHeight: 48)
                    .padding(.horizontal, 12)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .animation(.easeOut(duration: 0.15), value: optionsOpen)
    }

    // MARK: Tools

    private var toolRow: some View {
        HStack(spacing: 4) {
            ForEach(settings.toolOrder, id: \.self) { kind in toolButton(kind) }
            separator
            guideButton(.ruler, symbol: "ruler", label: "Ruler")
            guideButton(.protractor, symbol: "angle", label: "Protractor")
            separator
            Button { session.undo() } label: { iconLabel("arrow.uturn.backward") }
                .disabled(!session.canUndo)
                .accessibilityLabel("Undo")
            Button { session.redo() } label: { iconLabel("arrow.uturn.forward") }
                .disabled(!session.canRedo)
                .accessibilityLabel("Redo")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .frame(height: 48)
    }

    private var separator: some View {
        Rectangle().fill(Color(.separator)).frame(width: 1, height: 24).padding(.horizontal, 4)
    }

    private func iconLabel(_ symbol: String, active: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 19, weight: .regular))
            .frame(width: 42, height: 40)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .background(active ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
            .contentShape(Capsule())
    }

    private func toolButton(_ kind: ToolKind) -> some View {
        Button {
            if settings.kind == kind {
                if kind == .eraser { onEraserMenu() } else { optionsOpen.toggle() }
            } else {
                session.column?.deactivateAll()
                var s = session.settings
                s.kind = kind
                session.settings = s
                optionsOpen = true
            }
        } label: { iconLabel(kind.symbol, active: settings.kind == kind) }
        .accessibilityLabel(kind.label)
        .accessibilityAddTraits(settings.kind == kind ? .isSelected : [])
        .draggable(kind.rawValue)
        .dropDestination(for: String.self) { items, _ in
            guard let raw = items.first, let dragged = ToolKind(rawValue: raw) else { return false }
            var s = session.settings
            s.setToolOrder(s.toolOrder.moving(dragged, before: kind))
            session.settings = s
            return true
        }
    }

    private func guideButton(_ kind: GuideKind, symbol: String, label: String) -> some View {
        Button { toggleGuide(kind) } label: { iconLabel(symbol, active: session.guideKind == kind) }
            .accessibilityLabel(label)
    }

    /// Shows the ruler / protractor on the page in view, or hides it if it is already shown.
    private func toggleGuide(_ kind: GuideKind) {
        if session.guideKind == kind {
            session.guideKind = nil
            session.guidePageId = nil
        } else {
            session.guideKind = kind
            session.guidePageId = session.currentPage?.id
        }
    }

    // MARK: Options

    @ViewBuilder
    private var optionsRow: some View {
        switch settings.kind {
        case .pen, .highlighter:
            inkOptions(settings.kind == .pen ? .pen : .highlighter)
        case .eraser:
            HStack(spacing: 12) {
                Button(action: onEraserMenu) {
                    HStack(spacing: 6) {
                        Text(settings.eraserMode.label)
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Eraser mode")
                hint(settings.eraserMode == .partial ? "Rub out just the parts you touch." : "Drag the pencil across a stroke to erase it.")
            }
        case .lasso:
            lassoOptions
        case .text:
            HStack(spacing: 12) {
                SwatchRow(session: session, tool: .pen, current: settings.textColor) { c in
                    var s = session.settings
                    s.textColor = c
                    session.settings = s
                }
                hint("Tap to place text. Tap a box to edit it.")
            }
        case .shapes:
            shapeOptions
        case .tape:
            hint("Drag to cover an area. Tap a strip to peel it back; tap again to cover it.")
        case .laser:
            hint("Point and drag: the trail fades and is never saved.")
        case .hand:
            hint("Drag anywhere — with the pen or a finger — to pan the page.")
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
    }

    private func inkOptions(_ tool: InkTool) -> some View {
        HStack(spacing: 14) {
            SwatchRow(session: session, tool: tool, current: settings.color(tool)) { c in
                var s = session.settings
                s.setColor(tool, c)
                session.settings = s
            }
            SizeButton(session: session, tool: tool)
            if tool == .pen { hint("Draw a straight-ish stroke or a closed shape and lift to snap it.") }
        }
    }

    private var lassoOptions: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(LassoShape.allCases, id: \.self) { shape in
                    Button {
                        var s = session.settings
                        s.lassoShape = shape
                        session.settings = s
                    } label: { iconLabel(shape.symbol, active: settings.lassoShape == shape) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(shape.label)
                }
            }
            separator
            if let sel = session.selection, sel.count > 0 {
                if sel.hasPen {
                    SwatchRow(session: session, tool: .pen, current: nil) { c in session.column?.recolorSelection(.pen, color: c) }
                }
                if sel.hasHighlighter {
                    SwatchRow(session: session, tool: .highlighter, current: nil) { c in session.column?.recolorSelection(.highlighter, color: c) }
                }
                if !sel.hasPen && !sel.hasHighlighter { hint("Tap the selection for Duplicate, Cut, Copy and Delete.") }
            } else {
                hint(settings.lassoShape == .free ? "Draw around ink to select it. Tap an item to select it." : "Drag across items to select them.")
                if !session.clipboard.isEmpty {
                    Button { session.column?.pasteIntoCurrentPage() } label: { iconLabel("doc.on.clipboard") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Paste")
                }
            }
        }
    }

    private var shapeOptions: some View {
        HStack(spacing: 12) {
            HStack(spacing: 2) {
                ForEach(PlacedShape.allCases, id: \.self) { shape in
                    Button {
                        var s = session.settings
                        s.shapeKind = shape
                        session.settings = s
                    } label: { iconLabel(shape.symbol, active: settings.shapeKind == shape) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(shape.label)
                }
            }
            separator
            SwatchRow(session: session, tool: .pen, current: settings.penColor) { c in
                var s = session.settings
                s.penColor = c
                session.settings = s
            }
            SizeButton(session: session, tool: .pen)
            if session.hasSelection {
                separator
                Button { session.column?.deleteSelection() } label: { iconLabel("trash") }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Delete")
            }
            hint("Drag to place a shape. Tap a shape to adjust it.")
        }
    }
}
