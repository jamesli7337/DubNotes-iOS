import PDFKit
import UIKit

/// Stored PDFs and their rendered pages. A page's background is `{assetId, page}`; the PDF bytes live once
/// per notebook as an asset file and pages are rendered on demand with a small LRU and a memo of pages that
/// failed (so a broken page isn't retried forever). PDFKit isn't thread-safe per document, so all PDF work
/// runs on one serial queue.
final class PDFAssets {
    static let shared = PDFAssets()

    /// Where asset files live; set once at launch from the library's `FileStore`.
    var files: FileStore?

    private let queue = DispatchQueue(label: "dubnotes.pdf", qos: .userInitiated)
    private var documents: [String: PDFDocument] = [:]
    private var documentOrder: [String] = []
    private let rendered = NSCache<NSString, UIImage>()
    private var failed = Set<String>()
    private let lock = NSLock()
    private static let maxDocuments = 4

    private init() {
        rendered.countLimit = 24
        rendered.totalCostLimit = 160_000_000 // bytes: a zoomed-in page can be tens of megabytes
    }

    private static func pageKey(_ assetId: String, _ page: Int) -> String { "\(assetId)#\(page)" }

    func isFailed(assetId: String, page: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return failed.contains(Self.pageKey(assetId, page))
    }

    /// Opens (or reuses) the document for an asset. Call only on `queue`.
    private func document(notebookId: String, assetId: String) -> PDFDocument? {
        if let d = documents[assetId] { return d }
        guard let files else { return nil }
        let url = files.assetURL(notebookId: notebookId, assetId: assetId)
        guard let d = PDFDocument(url: url) else { return nil }
        documents[assetId] = d
        documentOrder.append(assetId)
        if documentOrder.count > Self.maxDocuments {
            documents[documentOrder.removeFirst()] = nil
        }
        return d
    }

    /// A rendered page if it is already cached; otherwise nil (call `render`).
    func cachedImage(assetId: String, page: Int, pixelWidth: Int) -> UIImage? {
        rendered.object(forKey: "\(Self.pageKey(assetId, page))@\(pixelWidth)" as NSString)
    }

    /// Renders a page (1-based) at `pixelWidth` on the PDF queue and calls back on the main queue.
    func render(notebookId: String, assetId: String, page: Int, pixelWidth: Int, completion: @escaping (UIImage?) -> Void) {
        let key = Self.pageKey(assetId, page)
        let cacheKey = "\(key)@\(pixelWidth)" as NSString
        if let hit = rendered.object(forKey: cacheKey) {
            completion(hit)
            return
        }
        if isFailed(assetId: assetId, page: page) {
            completion(nil)
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let image = self.renderNow(notebookId: notebookId, assetId: assetId, page: page, pixelWidth: pixelWidth)
            if let image {
                self.rendered.setObject(image, forKey: cacheKey, cost: Int(image.size.width * image.size.height * 4))
            } else {
                self.lock.lock(); self.failed.insert(key); self.lock.unlock()
            }
            DispatchQueue.main.async { completion(image) }
        }
    }

    /// Synchronous render for exports. Runs on the PDF queue and blocks the caller until done.
    func renderSync(notebookId: String, assetId: String, page: Int, pixelWidth: Int) -> UIImage? {
        if let hit = cachedImage(assetId: assetId, page: page, pixelWidth: pixelWidth) { return hit }
        return queue.sync { renderNow(notebookId: notebookId, assetId: assetId, page: page, pixelWidth: pixelWidth) }
    }

    private func renderNow(notebookId: String, assetId: String, page: Int, pixelWidth: Int) -> UIImage? {
        guard let doc = document(notebookId: notebookId, assetId: assetId),
              page >= 1, page <= doc.pageCount, let pdfPage = doc.page(at: page - 1) else { return nil }
        let box = pdfPage.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = CGFloat(pixelWidth) / box.width
        let size = CGSize(width: CGFloat(pixelWidth), height: (box.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let cg = ctx.cgContext
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: scale, y: -scale)
            pdfPage.draw(with: .mediaBox, to: cg)
        }
        return image
    }


    /// Page count and each page's own size in PDF points, read without rendering anything.
    static func pageSizes(of data: Data) -> [CGSize]? {
        guard let doc = PDFDocument(data: data), doc.pageCount > 0 else { return nil }
        return (0..<doc.pageCount).map { i in doc.page(at: i)?.bounds(for: .mediaBox).size ?? CGSize(width: 612, height: 792) }
    }

    /// Drops the cached document and renders for an asset whose file went away.
    func release(assetId: String) {
        queue.async { [weak self] in
            self?.documents[assetId] = nil
            self?.documentOrder.removeAll { $0 == assetId }
        }
    }
}
