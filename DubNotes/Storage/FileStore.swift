import Foundation

/// Plain files, one folder per notebook:
///
///     <root>/library.json                      folders + dividers
///     <root>/Notebooks/<id>/notebook.json      notebook record, page records, counts
///     <root>/Notebooks/<id>/pages/<pageId>.json  that page's strokes and elements
///     <root>/Notebooks/<id>/assets/<id>.pdf    stored PDF, with <id>.json beside it
///
/// Every file is written atomically. The layout keeps one notebook inside one folder so it can move to
/// iCloud Drive later without restructuring.
final class FileStore {
    struct LibraryMeta: Codable, Equatable {
        var version = 1
        var folders: [Folder] = []
        var dividers: [Divider] = []
    }

    struct AssetMeta: Codable, Equatable {
        var id: String
        var notebookId: String
        var kind: Asset.Kind
        var name: String
        var pages: Int
    }

    let root: URL
    private let fm = FileManager.default

    init(root: URL) {
        self.root = root
    }

    /// `Documents/DubNotes`, which the Files app can see.
    static var defaultRoot: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("DubNotes", isDirectory: true)
    }

    private var libraryURL: URL { root.appendingPathComponent("library.json") }
    private var notebooksURL: URL { root.appendingPathComponent("Notebooks", isDirectory: true) }

    func notebookDir(_ id: String) -> URL { notebooksURL.appendingPathComponent(id, isDirectory: true) }
    private func manifestURL(_ id: String) -> URL { notebookDir(id).appendingPathComponent("notebook.json") }
    private func pagesDir(_ id: String) -> URL { notebookDir(id).appendingPathComponent("pages", isDirectory: true) }
    private func pageURL(_ nb: String, _ page: String) -> URL { pagesDir(nb).appendingPathComponent("\(Self.safeName(page)).json") }
    private func assetsDir(_ id: String) -> URL { notebookDir(id).appendingPathComponent("assets", isDirectory: true) }

    /// Ids become file names. Board page ids contain ':' and ',', which are legal but awkward; swap them out.
    static func safeName(_ id: String) -> String {
        String(id.map { $0 == ":" || $0 == "/" ? "_" : $0 })
    }

    // MARK: Helpers

    private func write(_ data: Data, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder().encode(value)
    }

    // MARK: Library

    func loadLibraryMeta() -> LibraryMeta {
        guard let data = try? Data(contentsOf: libraryURL),
              let meta = try? JSONDecoder().decode(LibraryMeta.self, from: data) else { return LibraryMeta() }
        return meta
    }

    func saveLibraryMeta(_ meta: LibraryMeta) throws {
        try write(try encode(meta), to: libraryURL)
    }

    /// Every notebook that has a readable manifest, plus the folder names that could not be read.
    func loadManifests() -> (manifests: [NotebookManifest], unreadable: [String]) {
        guard let names = try? fm.contentsOfDirectory(atPath: notebooksURL.path) else { return ([], []) }
        var out: [NotebookManifest] = []
        var bad: [String] = []
        for name in names.sorted() where !name.hasPrefix(".") {
            if let m = loadManifest(name) { out.append(m) } else { bad.append(name) }
        }
        return (out, bad)
    }

    func loadManifest(_ id: String) -> NotebookManifest? {
        guard let data = try? Data(contentsOf: manifestURL(id)) else { return nil }
        return try? JSONDecoder().decode(NotebookManifest.self, from: data)
    }

    func saveManifest(_ m: NotebookManifest) throws {
        try write(try encode(m), to: manifestURL(m.notebook.id))
    }

    func deleteNotebook(_ id: String) {
        try? fm.removeItem(at: notebookDir(id))
    }

    // MARK: Pages

    /// A page file that cannot be decoded is moved aside (never overwritten) and read as empty.
    func loadPageContent(notebookId: String, pageId: String) -> PageContent {
        let url = pageURL(notebookId, pageId)
        guard let data = try? Data(contentsOf: url) else { return PageContent() }
        if let c = try? JSONDecoder().decode(PageContent.self, from: data) { return c }
        let stamp = Int(Date().timeIntervalSince1970)
        try? fm.moveItem(at: url, to: url.appendingPathExtension("corrupt-\(stamp)"))
        return PageContent()
    }

    func savePageContent(notebookId: String, pageId: String, _ content: PageContent) throws {
        try write(try encode(content), to: pageURL(notebookId, pageId))
    }

    func deletePageFile(notebookId: String, pageId: String) {
        try? fm.removeItem(at: pageURL(notebookId, pageId))
    }

    // MARK: Documents

    func loadDocument(_ id: String) -> NotebookDocument? {
        guard let m = loadManifest(id) else { return nil }
        var strokes: [Stroke] = []
        var elements: [PageElement] = []
        for p in m.pages {
            let c = loadPageContent(notebookId: id, pageId: p.id)
            strokes += c.strokes
            elements += c.elements
        }
        return NotebookDocument(notebook: m.notebook, pages: m.pages, strokes: strokes, elements: elements)
    }

    /// Writes whatever the document marks dirty (page files, deletions, manifest) and clears the marks.
    func save(_ doc: NotebookDocument) throws {
        let id = doc.id
        for pid in doc.dirtyPages where doc.page(pid) != nil {
            try savePageContent(notebookId: id, pageId: pid, doc.content(of: pid))
        }
        for pid in doc.deletedPages { deletePageFile(notebookId: id, pageId: pid) }
        if doc.manifestDirty { try saveManifest(doc.manifest()) }
        doc.clearDirty()
    }

    /// Writes a whole notebook from scratch (import, new notebook).
    func writeNew(_ doc: NotebookDocument) throws {
        for p in doc.pages { try savePageContent(notebookId: doc.id, pageId: p.id, doc.content(of: p.id)) }
        try saveManifest(doc.manifest())
        doc.clearDirty()
    }

    // MARK: Assets

    func writeAsset(_ asset: Asset) throws {
        let dir = assetsDir(asset.notebookId)
        try write(asset.data, to: dir.appendingPathComponent("\(asset.id).pdf"))
        let meta = AssetMeta(id: asset.id, notebookId: asset.notebookId, kind: asset.kind, name: asset.name, pages: asset.pages)
        try write(try encode(meta), to: dir.appendingPathComponent("\(asset.id).json"))
    }

    func assetURL(notebookId: String, assetId: String) -> URL {
        assetsDir(notebookId).appendingPathComponent("\(assetId).pdf")
    }

    func readAsset(notebookId: String, assetId: String) -> Asset? {
        let dir = assetsDir(notebookId)
        guard let meta = (try? Data(contentsOf: dir.appendingPathComponent("\(assetId).json")))
                .flatMap({ try? JSONDecoder().decode(AssetMeta.self, from: $0) }),
              let data = try? Data(contentsOf: dir.appendingPathComponent("\(assetId).pdf")) else { return nil }
        return Asset(id: meta.id, notebookId: meta.notebookId, kind: meta.kind, name: meta.name, pages: meta.pages, data: data)
    }

    func assetMetas(notebookId: String) -> [AssetMeta] {
        let dir = assetsDir(notebookId)
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.sorted().compactMap { name in
            (try? Data(contentsOf: dir.appendingPathComponent(name))).flatMap { try? JSONDecoder().decode(AssetMeta.self, from: $0) }
        }
    }

    // MARK: Backup

    /// The whole library as a v11 backup, for export.
    func makeBackup(folders: [Folder], dividers: [Divider], manifests: [NotebookManifest]) -> Backup {
        var b = Backup()
        b.exportedAt = ISO8601DateFormatter().string(from: Date())
        b.folders = folders
        b.dividers = dividers
        for m in manifests {
            b.notebooks.append(m.notebook)
            b.pages += m.pages
            for p in m.pages {
                let c = loadPageContent(notebookId: m.notebook.id, pageId: p.id)
                b.strokes += c.strokes
                b.elements += c.elements
            }
            for meta in assetMetas(notebookId: m.notebook.id) {
                if let a = readAsset(notebookId: m.notebook.id, assetId: meta.id) { b.assets.append(a) }
            }
        }
        return b
    }

    /// Writes every notebook in a backup (already remapped to fresh ids) to disk and returns their manifests.
    func writeBackupNotebooks(_ backup: Backup) throws -> [NotebookManifest] {
        var out: [NotebookManifest] = []
        for nb in backup.notebooks {
            let pages = backup.pages.filter { $0.notebookId == nb.id }
            let pageIds = Set(pages.map(\.id))
            let strokes = backup.strokes.filter { pageIds.contains($0.pageId) }
            let elements = backup.elements.filter { pageIds.contains($0.pageId) }
            let doc = NotebookDocument(notebook: nb, pages: pages, strokes: strokes, elements: elements)
            try writeNew(doc)
            for a in backup.assets where a.notebookId == nb.id { try writeAsset(a) }
            out.append(doc.manifest())
        }
        return out
    }
}
