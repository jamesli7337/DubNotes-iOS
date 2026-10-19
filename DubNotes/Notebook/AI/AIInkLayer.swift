import PencilKit
import UIKit

/// The PencilKit canvas that sits above one page while AI mode is on. Pen strokes here are always violet at the
/// current pen width; the eraser removes only strokes on this canvas. Every change goes to `AIInkStore` and nowhere else.
final class AIInkLayer: NSObject, PKCanvasViewDelegate {
    /// The tour has no Pencil, so `-seedAIInk` draws one test stroke on entering AI mode.
    static var seedEnabled: Bool { ProcessInfo.processInfo.arguments.contains("-seedAIInk") }

    let pageId: String
    let canvas = PKCanvasView()
    private unowned let session: NotebookSession
    private var loading = false

    init(pageId: String, session: NotebookSession) {
        self.pageId = pageId
        self.session = session
        super.init()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.overrideUserInterfaceStyle = .light // keep the violet as stored, as the main canvas does
        canvas.drawingPolicy = .default
        canvas.isScrollEnabled = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = self
        reload()
        applyTool()
    }

    /// Re-reads the page's drawing from the store (after an undo, a redo or a clear).
    func reload() {
        loading = true
        canvas.drawing = session.aiInk.drawing(for: pageId)
        loading = false
    }

    /// Pen and eraser draw here; any other tool leaves the canvas inert.
    func applyTool() {
        let s = session.settings
        switch s.kind {
        case .pen:
            canvas.tool = PKInkingTool(.pen, color: AITheme.uiViolet, width: CGFloat(s.penSize))
            canvas.isUserInteractionEnabled = true
        case .eraser:
            canvas.tool = PKEraserTool(s.eraserMode == .whole ? .vector : .bitmap)
            canvas.isUserInteractionEnabled = true
        default:
            canvas.isUserInteractionEnabled = false
        }
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !loading, session.aiMode else { return }
        session.aiInk.commit(pageId: pageId, drawing: canvasView.drawing)
    }

    /// Adds a wavy violet stroke across the page and reports it the way a drawn stroke is reported.
    func seedTestStroke() {
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let width = CGFloat(session.settings.penSize)
        let count = 40
        let points = (0..<count).map { i -> PKStrokePoint in
            let t = CGFloat(i) / CGFloat(count - 1)
            let location = CGPoint(x: size.width * (0.15 + 0.7 * t), y: size.height * 0.25 + 40 * sin(t * 2 * .pi))
            return PKStrokePoint(location: location, timeOffset: TimeInterval(i) * 0.01,
                                 size: CGSize(width: width, height: width), opacity: 1, force: 1,
                                 azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: AITheme.uiViolet),
                              path: PKStrokePath(controlPoints: points, creationDate: Date()))
        var drawing = canvas.drawing
        drawing.strokes.append(stroke)
        canvas.drawing = drawing
        canvasViewDrawingDidChange(canvas) // the store ignores the echo if PencilKit also reports it
    }
}
