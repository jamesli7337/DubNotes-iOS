import SwiftUI
import UIKit

/// Export to PDF, PNG and JPEG. The PDF is Letter width for the default page (820 units → 612 pt) with every
/// page keeping its own aspect; ink is PencilKit's own rendering so it matches the screen.
enum Exporter {
    enum Format {
        case pdf
        case png
        case jpeg

        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .png: return "png"
            case .jpeg: return "jpg"
            }
        }
    }

    /// A string safe to use as a file name.
    static func safeFileName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = name.components(separatedBy: bad).joined(separator: "-")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "notebook" : cleaned
    }

    /// Raster density for ink inside a PDF page, in pixels per page unit.
    static let pdfInkUnit = 2.5

    static func source(_ page: Page, in doc: NotebookDocument) -> PageRenderer.Source {
        PageRenderer.Source(page: page, strokes: doc.strokes(of: page.id), elements: doc.elements(of: page.id))
    }

    /// A PDF of the given pages, in order.
    static func pdfData(sources: [PageRenderer.Source], title: String) -> Data {
        let s = CGFloat(PageSizing.pdfScale)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: title, kCGPDFContextCreator as String: "DubNotes"]
        let first = sources.first?.page
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(first?.pageWidth ?? PageUnits.width) * s,
                            height: CGFloat(first?.pageHeight ?? PageUnits.height) * s)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds, format: format)
        return renderer.pdfData { ctx in
            for src in sources {
                let pageBounds = CGRect(x: 0, y: 0, width: CGFloat(src.page.pageWidth) * s, height: CGFloat(src.page.pageHeight) * s)
                ctx.beginPage(withBounds: pageBounds, pageInfo: [:])
                let cg = ctx.cgContext
                cg.saveGState()
                cg.scaleBy(x: s, y: s)
                PageRenderer.draw(src, in: cg, unit: pdfInkUnit)
                cg.restoreGState()
            }
        }
    }

    /// One page as PNG or JPEG at 2×.
    static func imageData(_ src: PageRenderer.Source, format: Format) -> Data? {
        let image = PageRenderer.image(src, scale: 2)
        return format == .png ? image.pngData() : image.jpegData(compressionQuality: 0.92)
    }

    /// Writes the export to a temporary file and returns it, ready for the share sheet.
    static func export(sources: [PageRenderer.Source], title: String, format: Format, fileName: String) throws -> URL {
        let data: Data
        switch format {
        case .pdf:
            data = pdfData(sources: sources, title: title)
        case .png, .jpeg:
            guard let src = sources.first, let d = imageData(src, format: format) else {
                throw CocoaError(.fileWriteUnknown)
            }
            data = d
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DubNotesExport-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(safeFileName(fileName)).\(format.fileExtension)")
        try data.write(to: url, options: .atomic)
        return url
    }
}

/// The system share sheet, which is also how an export reaches Files.
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
