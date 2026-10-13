import UIKit

/// Everything under the ink: paper, the PDF / image background, then images, text and shapes.
final class BackLayerView: UIView {
    var page: Page
    var elements: [PageElement] = []
    /// Ids not drawn here: items lifted off the page during a drag, or a text box being edited.
    var hiddenIds: Set<String> = []
    private var pdfImage: UIImage?
    private var pdfRequestedWidth = 0

    init(page: Page) {
        self.page = page
        super.init(frame: CGRect(x: 0, y: 0, width: page.pageWidth, height: page.pageHeight))
        isOpaque = true
        contentMode = .redraw
        backgroundColor = UIColor.fromHex(PaperStyle.ink(page.paper.color).bg)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func update(page: Page, elements: [PageElement]) {
        self.page = page
        self.elements = elements
        backgroundColor = UIColor.fromHex(PaperStyle.ink(page.paper.color).bg)
        pdfImage = nil
        pdfRequestedWidth = 0
        setNeedsDisplay()
    }

    private var unit: Double { max(Double(contentScaleFactor), 1) }

    /// Starts rendering the background PDF page at the resolution the current zoom needs.
    private func requestBackground() {
        guard case .pdf(let assetId, let n)? = page.background else { return }
        let px = PaperRenderer.backgroundPixelWidth(pageWidth: page.pageWidth, unit: unit)
        if px == pdfRequestedWidth { return }
        pdfRequestedWidth = px
        if let hit = PDFAssets.shared.cachedImage(assetId: assetId, page: n, pixelWidth: px) {
            pdfImage = hit
            return
        }
        let nb = page.notebookId
        PDFAssets.shared.render(notebookId: nb, assetId: assetId, page: n, pixelWidth: px) { [weak self] image in
            guard let self, self.pdfRequestedWidth == px else { return }
            self.pdfImage = image
            self.setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        PaperRenderer.drawTemplate(page.paper, in: ctx, width: page.pageWidth, height: page.pageHeight, unit: unit)
        if let bg = page.background {
            requestBackground()
            var failed = false
            if case .pdf(let assetId, let n) = bg { failed = PDFAssets.shared.isFailed(assetId: assetId, page: n) }
            PaperRenderer.drawBackground(page, in: ctx, pdfImage: pdfImage, pdfFailed: failed)
        }
        for e in elements where !hiddenIds.contains(e.id) && !PageView.isAboveInk(e) {
            ElementRenderer.draw(e, in: ctx, paper: page.paper)
        }
    }
}

/// Above the ink: tape, live previews (a shape or tape being dragged, the lasso outline, the laser trail),
/// the selection frame and its handles. Touches go to the owning `PageView`.
final class OverlayView: UIView {
    weak var owner: PageView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        isMultipleTouchEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let owner else { return false }
        return owner.overlayWants(Pt(Double(point.x), Double(point.y)))
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        owner?.drawOverlay(in: ctx)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let owner else { return }
        owner.overlayBegan(touch, event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let owner else { return }
        owner.overlayMoved(touch, event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let owner else { return }
        owner.overlayEnded(touch)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let owner else { return }
        owner.overlayCancelled(touch)
    }
}

/// Remembers whether an Apple Pencil has ever touched the screen. Until one has, a finger is allowed to drive
/// the shape, tape, laser and lasso tools the way a mouse does on the web.
enum PencilDetector {
    static var seen = false
    /// Called once, the first time a Pencil touches the screen.
    static var onSeen: (() -> Void)?

    static func markSeen() {
        guard !seen else { return }
        seen = true
        onSeen?()
    }
}

/// Fails immediately; exists only to notice a Pencil touch (see `PencilDetector`).
final class PencilSpy: UIGestureRecognizer {
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        PencilDetector.markSeen()
        state = .failed
    }
}
