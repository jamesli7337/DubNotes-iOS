import PencilKit
import UIKit

/// Paints a whole page exactly as the notebook shows it — paper, background, then strokes and elements in
/// z-order — for thumbnails, the split pane and export. Ink is drawn by PencilKit so it matches the canvas.
enum PageRenderer {
    /// Everything needed to draw one page.
    struct Source {
        var page: Page
        var strokes: [Stroke]
        var elements: [PageElement]
    }

    /// Draws into `ctx` in page units (the caller has already scaled). `unit` is device pixels per page unit.
    /// `region` limits ink rasterisation to a vertical slice; `tapePeeled` draws those tapes see-through.
    static func draw(_ src: Source, in ctx: CGContext, unit: Double, tapePeeled: Set<String> = [],
                     waitForPDF: Bool = true) {
        let page = src.page
        let w = page.pageWidth, h = page.pageHeight
        PaperRenderer.drawTemplate(page.paper, in: ctx, width: w, height: h, unit: unit)
        if let bg = page.background {
            var image: UIImage?
            var failed = false
            if case .pdf(let assetId, let n) = bg {
                let px = PaperRenderer.backgroundPixelWidth(pageWidth: w, unit: unit)
                image = PDFAssets.shared.cachedImage(assetId: assetId, page: n, pixelWidth: px)
                if image == nil && waitForPDF {
                    image = PDFAssets.shared.renderSync(notebookId: page.notebookId, assetId: assetId, page: n, pixelWidth: px)
                }
                failed = image == nil && PDFAssets.shared.isFailed(assetId: assetId, page: n)
            }
            PaperRenderer.drawBackground(page, in: ctx, pdfImage: image, pdfFailed: failed)
        }

        // z-order: strokes and elements interleaved by createdAt; each run of strokes is one PencilKit raster
        var items: [PageItem] = src.strokes.map(PageItem.stroke) + src.elements.map(PageItem.element)
        items.sort { $0.createdAt < $1.createdAt }
        var run: [Stroke] = []
        func flush() {
            guard !run.isEmpty else { return }
            drawInk(run, paper: page.paper, bounds: CGRect(x: 0, y: 0, width: w, height: h), unit: unit, in: ctx)
            run = []
        }
        for item in items {
            switch item {
            case .stroke(let s):
                run.append(s)
            case .element(let e):
                flush()
                ElementRenderer.draw(e, in: ctx, paper: page.paper, peeled: tapePeeled.contains(e.id))
            }
        }
        flush()
    }

    /// Rasterises strokes with PencilKit and draws the result at page position.
    static func drawInk(_ strokes: [Stroke], paper: Paper, bounds: CGRect, unit: Double, in ctx: CGContext) {
        let drawing = StrokeConverter.drawing(strokes, paper: paper)
        let area = drawing.bounds.intersection(bounds)
        guard !area.isNull, area.width > 0, area.height > 0 else { return }
        let padded = area.insetBy(dx: -4, dy: -4).intersection(bounds)
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: padded, scale: CGFloat(max(unit, 1)))
        }
        guard let img = image else { return }
        UIGraphicsPushContext(ctx)
        img.draw(in: padded)
        UIGraphicsPopContext()
    }

    /// A page as an image at `scale` pixels per page unit, optionally cropped to a vertical slice.
    static func image(_ src: Source, scale: Double, region: ClosedRange<Double>? = nil, opaque: Bool = true) -> UIImage {
        let w = src.page.pageWidth, h = src.page.pageHeight
        let top = region.map { min(max($0.lowerBound, 0), h) } ?? 0
        let bottom = region.map { min(max($0.upperBound, top), h) } ?? h
        let size = CGSize(width: w * scale, height: (bottom - top) * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = opaque
        return UIGraphicsImageRenderer(size: size, format: format).image { r in
            let ctx = r.cgContext
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            ctx.translateBy(x: 0, y: CGFloat(-top))
            draw(src, in: ctx, unit: scale)
        }
    }

    /// A small preview of a page, framed by a hairline so an empty page still reads as a page.
    static func thumbnail(_ src: Source, width: Double) -> UIImage {
        let scale = width / src.page.pageWidth
        let w = src.page.pageWidth, h = src.page.pageHeight
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: h * scale), format: format).image { r in
            let ctx = r.cgContext
            ctx.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            draw(src, in: ctx, unit: scale)
            ctx.setStrokeColor(UIColor(PaperStyle.thumbFrame(src.page.paper)).cgColor)
            ctx.setLineWidth(2)
            ctx.stroke(CGRect(x: 1, y: 1, width: w - 2, height: h - 2))
        }
    }
}

/// Library thumbnails: the first page of a notebook, rendered off the main thread and cached.
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, UIImage>()
    private let queue = DispatchQueue(label: "dubnotes.thumbs", qos: .utility)

    private init() { cache.countLimit = 60 }

    func cached(key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func load(files: FileStore, page: Page, key: String, width: Double, completion: @escaping (UIImage) -> Void) {
        if let hit = cached(key: key) {
            completion(hit)
            return
        }
        queue.async { [weak self] in
            let content = files.loadPageContent(notebookId: page.notebookId, pageId: page.id)
            let image = PageRenderer.thumbnail(PageRenderer.Source(page: page, strokes: content.strokes, elements: content.elements),
                                               width: width)
            self?.cache.setObject(image, forKey: key as NSString)
            DispatchQueue.main.async { completion(image) }
        }
    }
}
