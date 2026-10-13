import PencilKit
import UIKit

/// One page of the notebook column: paper and elements underneath, a PencilKit canvas for pen / highlighter /
/// eraser / free-lasso ink, and an overlay for everything else (shapes, tape, text, box and circle lasso, the
/// laser, selection handles). Page units are view points; zooming is the scroll view's transform.
///
/// The document is the source of truth. The canvas drawing is derived from it, and every change PencilKit
/// reports is reconciled back into stroke records (see `StrokeConverter.reconcile`).
final class PageView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate, UITextViewDelegate {
    /// Tape draws above the ink (it covers); everything else sits beneath it.
    static func isAboveInk(_ e: PageElement) -> Bool {
        if case .tape = e.content { return true }
        return false
    }

    enum InputMode: Equatable {
        case none
        case shape
        case tapeDrag
        case laser
        case marquee
        /// A tap candidate on something that may turn into a drag.
        case press(PressTarget)
        case transform
        /// A press that only dismissed an open editor or selection.
        case dismiss
    }

    enum PressTarget: Equatable {
        case tape(String)
        case element(String)
        case text(String)
        case newText
    }

    struct TransformDrag {
        var handle: SelectionHandle
        var style: SelectionStyle
        var startFrame: ItemFrame
        var startItems: [PageItem]
        var pressPt: Pt
        var preview: [PageItem]
        var strokeImage: UIImage?
        var strokeImageRect: CGRect
    }

    struct LaserPoint {
        var x: Double
        var y: Double
        var t: CFTimeInterval
    }

    struct TextEdit {
        var textView: UITextView
        var element: PageElement
        var isNew: Bool
    }

    // MARK: Identity

    let pageId: String
    unowned let session: NotebookSession
    weak var column: PageColumnController?
    private(set) var mounted = false

    // MARK: Layers

    private(set) var back: BackLayerView?
    private(set) var canvas: PKCanvasView?
    let overlay = OverlayView()
    private var guideView: GuideView?
    private var eraseGR: UIPanGestureRecognizer?

    // MARK: Content

    var elements: [PageElement] = []
    var peeled = Set<String>()
    /// Items lifted off the page while they are dragged, or a text box being edited.
    var hiddenIds = Set<String>()

    // MARK: Ink sync

    var baseline: [Stroke] = []
    var inkHidden: [Stroke] = []
    private var loadingInk = false

    // MARK: Input state

    var mode: InputMode = .none
    var activeTouch: UITouch?
    var pressPt = Pt(0, 0)
    var moved = false
    var livePts: [Pt] = []
    var lassoPath: [Pt] = []
    var erasedShapeIds = Set<String>()

    // MARK: Selection

    var selectedIds = Set<String>()
    var selectionFrame: ItemFrame?
    var selectionStyle = SelectionStyle(rotate: false, aspect: true, edges: .none)
    var xf: TransformDrag?

    // MARK: Laser, text

    var laser: [[LaserPoint]] = []
    var displayLink: CADisplayLink?
    var editor: TextEdit?

    var currentPage: Page {
        session.doc.page(pageId) ?? Page(id: pageId, notebookId: session.doc.id, index: 0, paper: .default, createdAt: 0, updatedAt: 0)
    }

    var settings: ToolSettings { session.settings }
    var zoom: Double { Double(column?.zoom ?? 1) }

    // MARK: Lifecycle

    init(pageId: String, session: NotebookSession) {
        self.pageId = pageId
        self.session = session
        let p = session.doc.page(pageId)
        super.init(frame: CGRect(x: 0, y: 0, width: p?.pageWidth ?? PageUnits.width, height: p?.pageHeight ?? PageUnits.height))
        clipsToBounds = true
        layer.cornerRadius = 6
        backgroundColor = UIColor.fromHex(PaperStyle.ink((p ?? Page.placeholder).paper.color).bg)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { displayLink?.invalidate() }

    /// Builds the heavy layers (paper drawing, PencilKit canvas, overlay). Called when the page nears the viewport.
    func mount() {
        guard !mounted else { return }
        mounted = true
        let b = BackLayerView(page: currentPage)
        b.frame = bounds
        addSubview(b)
        back = b

        let c = PKCanvasView(frame: bounds)
        c.backgroundColor = .clear
        c.isOpaque = false
        c.overrideUserInterfaceStyle = .light // keep inks as stored; PencilKit would otherwise invert black / white
        c.drawingPolicy = .default
        c.isScrollEnabled = false
        c.contentInsetAdjustmentBehavior = .never
        c.delegate = self
        addSubview(c)
        canvas = c

        overlay.owner = self
        overlay.frame = bounds
        addSubview(overlay)

        let erase = UIPanGestureRecognizer(target: self, action: #selector(erasePan(_:)))
        erase.maximumNumberOfTouches = 1
        erase.cancelsTouchesInView = false
        erase.delegate = self
        addGestureRecognizer(erase)
        eraseGR = erase

        reload()
        applyTool()
        syncGuide()
        updateScale()
    }

    /// Tears the heavy layers down (the page scrolled far away); the paper colour stays as a placeholder.
    func unmount() {
        guard mounted else { return }
        commitEdit()
        displayLink?.invalidate()
        displayLink = nil
        laser = []
        if let g = eraseGR { removeGestureRecognizer(g) }
        eraseGR = nil
        for v in [back, canvas, overlay, guideView] as [UIView?] { v?.removeFromSuperview() }
        back = nil
        canvas = nil
        guideView = nil
        mounted = false
        mode = .none
        xf = nil
        backgroundColor = UIColor.fromHex(PaperStyle.ink(currentPage.paper.color).bg)
    }

    /// Re-reads everything from the document.
    func reload() {
        let page = currentPage
        if abs(bounds.width - page.pageWidth) > 0.5 || abs(bounds.height - page.pageHeight) > 0.5 {
            // the page changed size; the column re-lays-out, then the layers follow
            bounds = CGRect(x: 0, y: 0, width: page.pageWidth, height: page.pageHeight)
            for v in [back, canvas, overlay] as [UIView?] { v?.frame = bounds }
        }
        elements = session.doc.elements(of: pageId)
        peeled = peeled.intersection(elements.map(\.id))
        pruneSelection()
        back?.hiddenIds = hiddenIds
        back?.update(page: page, elements: elements)
        reloadInk()
        overlay.setNeedsDisplay()
    }

    func paperChanged() {
        guard mounted else {
            backgroundColor = UIColor.fromHex(PaperStyle.ink(currentPage.paper.color).bg)
            return
        }
        reload()
        applyTool()
        guideView?.setNeedsDisplay()
    }

    /// Backing-store resolution follows the zoom so ink and ruling stay sharp.
    func updateScale() {
        guard mounted else { return }
        // pixels per page unit follow the zoom, capped so one layer never needs more than ~8 million pixels
        let page = currentPage
        let cap = CGFloat((8_000_000 / max(page.pageWidth * page.pageHeight, 1)).squareRoot())
        let s = max(1, min(UIScreen.main.scale * CGFloat(zoom), 4, cap))
        back?.contentScaleFactor = s
        overlay.contentScaleFactor = max(1, min(s, 2)) // selection chrome and tape don't need more
        guideView?.contentScaleFactor = max(1, min(s, 3))
        guideView?.zoom = CGFloat(zoom)
        back?.setNeedsDisplay()
        overlay.setNeedsDisplay()
    }

    // MARK: Ink

    /// Rebuilds the canvas drawing from the model (minus anything lifted off for a drag).
    func reloadInk() {
        guard let canvas else { return }
        let all = session.doc.strokes(of: pageId)
        inkHidden = all.filter { hiddenIds.contains($0.id) }
        let shown = all.filter { !hiddenIds.contains($0.id) }
        baseline = shown
        loadingInk = true
        canvas.drawing = StrokeConverter.drawing(shown, paper: currentPage.paper)
        loadingInk = false
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !loadingInk, mounted else { return }
        let isHighlighter = settings.kind == .highlighter
        let tool: Stroke.Tool = isHighlighter ? .highlighter : .pen
        let nib = isHighlighter ? settings.highlighterSize : settings.penSize
        let rec = StrokeConverter.reconcile(canvasView.drawing, baseline: baseline, pageId: pageId,
                                            notebookId: session.doc.id, paper: currentPage.paper,
                                            tool: tool, nib: nib, now: LibraryStore.now())
        let merged = rec.strokes + inkHidden
        let old = session.doc.strokes(of: pageId)
        let oldIds = Set(old.map(\.id))
        let newIds = Set(merged.map(\.id))
        let removed = old.filter { !newIds.contains($0.id) }
        var added = merged.filter { !oldIds.contains($0.id) }
        baseline = rec.baseline
        if removed.isEmpty && added.isEmpty { return }

        // a single new stroke may snap: onto the ruler / protractor edge, or into a recognised shape
        if removed.isEmpty, added.count == 1, let s = added.first {
            if let snapped = snapToGuide(s) {
                added = [snapped]
                session.inkEdited(pageId: pageId, removed: [], added: added, canvasInSync: false)
                return
            }
            if settings.kind == .pen, s.tool == .pen, let shape = recognizedShape(for: s) {
                session.edit(removed: [], added: [.element(shape)], on: pageId)
                select(ids: [shape.id])
                return
            }
        }
        session.inkEdited(pageId: pageId, removed: removed, added: added, canvasInSync: true)
        if !removed.isEmpty { pruneSelection() }
    }

    /// A stroke that began beside the guide's straight edge runs along that edge.
    private func snapToGuide(_ s: Stroke) -> Stroke? {
        guard let g = guideView, let first = s.points.first,
              let edge = g.edgeNear(first.x, first.y) else { return nil }
        var out = s
        out.points = s.points.map { p in
            let q = edge.project(p.x, p.y)
            return StrokePoint(x: q.x, y: q.y, pressure: p.pressure)
        }
        return out
    }

    private func recognizedShape(for s: Stroke) -> PageElement? {
        guard let fit = ShapeRecognition.recognize(s.pts, nib: s.size, zoom: zoom) else { return nil }
        let shape = PageElement.Shape(shape: fit.shape, color: s.color, size: s.size, pts: fit.pts)
        return PageElement(id: UUID().uuidString, pageId: pageId, notebookId: session.doc.id,
                           x: fit.x, y: fit.y, w: fit.w, h: fit.h, rotation: fit.rotation,
                           createdAt: s.createdAt, content: .shape(shape))
    }

    // MARK: Tool

    /// Points the canvas at the current tool. Tools PencilKit doesn't provide hand their touches to the overlay.
    func applyTool() {
        guard let canvas else { return }
        let s = settings
        let paper = currentPage.paper
        switch s.kind {
        case .pen:
            let color = UIColor.fromHex(PaperStyle.resolve(s.penColor, on: paper))
            canvas.tool = PKInkingTool(.pen, color: color, width: CGFloat(s.penSize))
            canvas.isUserInteractionEnabled = true
        case .highlighter:
            let color = UIColor.fromHex(PaperStyle.resolve(s.highlighterColor, on: paper))
            canvas.tool = PKInkingTool(.marker, color: color, width: CGFloat(s.highlighterSize))
            canvas.isUserInteractionEnabled = true
        case .eraser:
            canvas.tool = PKEraserTool(s.eraserMode == .whole ? .vector : .bitmap)
            canvas.isUserInteractionEnabled = true
        case .lasso where s.lassoShape == .free:
            canvas.tool = PKLassoTool()
            canvas.isUserInteractionEnabled = true
        default:
            canvas.isUserInteractionEnabled = false
        }
        overlay.setNeedsDisplay()
    }

    func toolChanged() {
        if settings.kind != .text { commitEdit() }
        if !(settings.kind == .lasso || settings.kind == .shapes || settings.kind == .tape || settings.kind == .text) {
            clearSelection()
        }
        applyTool()
    }

    // MARK: Guide

    func syncGuide() {
        guard mounted else { return }
        let wanted = session.guidePageId == pageId ? session.guideKind : nil
        if let g = guideView, g.geometry.kind == wanted { return }
        guideView?.removeFromSuperview()
        guideView = nil
        if let kind = wanted {
            let g = GuideView(kind: kind, page: currentPage)
            g.zoom = CGFloat(zoom)
            insertSubview(g, belowSubview: overlay)
            guideView = g
            updateScale()
        }
    }

    // MARK: Eraser (shapes)

    /// PencilKit's eraser handles ink; this follows the same drag to remove shapes it touches (by outline).
    @objc private func erasePan(_ gr: UIPanGestureRecognizer) {
        guard settings.kind == .eraser else { return }
        let loc = gr.location(in: self)
        let pt = Pt(Double(loc.x), Double(loc.y))
        let tol = 6 / max(zoom, 0.1)
        switch gr.state {
        case .began, .changed:
            var hit = false
            for e in elements {
                guard case .shape(let s) = e.content, !erasedShapeIds.contains(e.id) else { continue }
                if Geometry.nearShapeOutline(e, s, pt.x, pt.y, s.size / 2 + tol) {
                    erasedShapeIds.insert(e.id)
                    hit = true
                }
            }
            if hit {
                hiddenIds.formUnion(erasedShapeIds)
                back?.hiddenIds = hiddenIds
                back?.setNeedsDisplay()
            }
        case .ended:
            finishShapeErase()
        case .cancelled, .failed:
            finishShapeErase()
        default:
            break
        }
    }

    private func finishShapeErase() {
        guard !erasedShapeIds.isEmpty else { return }
        let ids = erasedShapeIds
        erasedShapeIds = []
        hiddenIds.subtract(ids)
        session.remove(ids: ids, from: pageId)
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === eraseGR { return settings.kind == .eraser && mounted }
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === eraseGR
    }
}

extension Page {
    /// Stand-in used only if a page vanishes while its view is still alive.
    static var placeholder: Page {
        Page(id: "", notebookId: "", index: 0, paper: .default, createdAt: 0, updatedAt: 0)
    }
}
