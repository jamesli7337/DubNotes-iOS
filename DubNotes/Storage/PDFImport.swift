import Foundation
import UniformTypeIdentifiers
import SwiftUI

enum PDFImportError: LocalizedError {
    case unreadable

    var errorDescription: String? { "That file could not be read as a PDF." }
}

/// A PDF comes in as pages: the file is stored once as an asset and each page points at it with
/// `background {assetId, page}`, rendered on demand. Nothing is rasterised at import time.
enum PDFImport {
    /// Page sizes (page units) for each PDF page, validating the file on the way.
    static func pageSizes(of data: Data) throws -> [(w: Double, h: Double)] {
        guard let sizes = PDFAssets.pageSizes(of: data) else { throw PDFImportError.unreadable }
        return sizes.map { PageSizing.notebookPageSize(pdfWidth: Double($0.width), pdfHeight: Double($0.height)) }
    }

    /// A new notebook with one page per PDF page. The caller stores it with `LibraryStore.addNotebook`.
    static func makeNotebook(name fileName: String, data: Data, now: Double = LibraryStore.now(),
                             progress: ((Int, Int) -> Void)? = nil) throws -> (doc: NotebookDocument, asset: Asset) {
        let sizes = try pageSizes(of: data)
        let base = (fileName as NSString).deletingPathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        let nb = Notebook(id: UUID().uuidString, name: base.isEmpty ? "Imported PDF" : base, createdAt: now, updatedAt: now)
        let asset = Asset(id: UUID().uuidString, notebookId: nb.id, name: fileName, pages: sizes.count, data: data)
        let doc = NotebookDocument(notebook: nb, pages: [])
        for (i, size) in sizes.enumerated() {
            let p = doc.addPage()
            doc.setPaper(p.id, paper: Paper(template: .blank, spacing: p.paper.spacing, color: p.paper.color), allPages: false)
            doc.setPageSize(p.id, w: size.w, h: size.h)
            doc.setBackground(p.id, .pdf(assetId: asset.id, page: i + 1))
            progress?(i + 1, sizes.count)
        }
        return (doc, asset)
    }

    /// Appends a PDF's pages to an open notebook, right after `afterIndex`. Returns the stored asset.
    @discardableResult
    static func appendPages(to doc: NotebookDocument, data: Data, name: String, afterIndex: Int, files: FileStore,
                            progress: ((Int, Int) -> Void)? = nil) throws -> Asset {
        let sizes = try pageSizes(of: data)
        let asset = Asset(id: UUID().uuidString, notebookId: doc.id, name: name, pages: sizes.count, data: data)
        try files.writeAsset(asset)
        for (i, size) in sizes.enumerated() {
            let p = doc.addPage(at: afterIndex + 1 + i)
            doc.setPaper(p.id, paper: Paper(template: .blank, spacing: p.paper.spacing, color: p.paper.color), allPages: false)
            doc.setPageSize(p.id, w: size.w, h: size.h)
            doc.setBackground(p.id, .pdf(assetId: asset.id, page: i + 1))
            progress?(i + 1, sizes.count)
        }
        return asset
    }
}

/// A backup file for `.fileExporter`.
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// `noteapp-backup-20261012-1439.json`, like the web export.
func backupFileName(now: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyyMMdd-HHmm"
    return "noteapp-backup-\(f.string(from: now))"
}

/// Reads a file a document picker returned: the URL is security-scoped, so access must be opened around the read.
func readPickedFile(_ url: URL) throws -> Data {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    return try Data(contentsOf: url)
}
