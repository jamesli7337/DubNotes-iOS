import Foundation
import Observation

/// A notebook or a divider in one folder's manual order (they share a single `order` sequence).
enum FolderItem: Identifiable {
    case notebook(Notebook)
    case divider(Divider)

    var id: String {
        switch self {
        case .notebook(let nb): return nb.id
        case .divider(let d): return d.id
        }
    }

    var order: Double {
        switch self {
        case .notebook(let nb): return nb.order
        case .divider(let d): return d.order
        }
    }

    var createdAt: Double {
        switch self {
        case .notebook(let nb): return nb.createdAt
        case .divider(let d): return d.createdAt
        }
    }
}

/// The library: folders, dividers and every notebook's record, loaded from disk at launch and autosaved.
/// Folder, divider and ordering rules follow the web store (src/store.ts). A notebook's pages are not held
/// here; `openDocument` loads one when it is opened and `closeDocument` folds its changes back.
@Observable
final class LibraryStore {
    var notebooks: [Notebook] = []
    var folders: [Folder] = []
    var dividers: [Divider] = []
    /// Shown instead of the library when loading fails outright; also carries save problems.
    var loadError: String?
    var saveError: String?
    /// Bumped whenever a notebook's content changed, so thumbnails know to redraw.
    var contentRevision = 0

    @ObservationIgnored private var manifests: [String: NotebookManifest] = [:]
    @ObservationIgnored private var openDocuments: [String: NotebookDocument] = [:]
    @ObservationIgnored private var metaDirty = false
    @ObservationIgnored private var dirtyManifests = Set<String>()
    @ObservationIgnored private var pending: DispatchWorkItem?
    let files: FileStore

    /// Autosave delay after the last change, as in the web store.
    static let saveDelay = 0.7

    init(files: FileStore = FileStore(root: FileStore.defaultRoot)) {
        self.files = files
        PDFAssets.shared.files = files
        load()
    }

    private func load() {
        let meta = files.loadLibraryMeta()
        folders = meta.folders
        dividers = meta.dividers
        let (loaded, unreadable) = files.loadManifests()
        for m in loaded {
            manifests[m.notebook.id] = m
            notebooks.append(m.notebook)
        }
        if !unreadable.isEmpty {
            let count: Int = unreadable.count
            let plural: String = count == 1 ? "" : "s"
            let verb: String = count == 1 ? "was" : "were"
            loadError = String(count) + " notebook folder" + plural + " could not be read and " + verb + " left untouched."
            // an unreadable notebook must not hide the readable ones
            if !notebooks.isEmpty { loadError = nil }
        }
    }

    static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    // MARK: Saving

    private func scheduleSave() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushNow() }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: item)
    }

    /// Writes everything dirty right now. Called on a timer after changes and when the app backgrounds.
    func flushNow() {
        pending?.cancel()
        pending = nil
        do {
            if metaDirty {
                try files.saveLibraryMeta(FileStore.LibraryMeta(folders: folders, dividers: dividers))
                metaDirty = false
            }
            for id in dirtyManifests where openDocuments[id] == nil {
                if let m = manifests[id] { try files.saveManifest(m) }
            }
            dirtyManifests = dirtyManifests.filter { openDocuments[$0] != nil }
            for doc in openDocuments.values { try files.save(doc) }
            saveError = nil
        } catch {
            saveError = "Could not save: \(error.localizedDescription)"
            scheduleSave() // keep trying; nothing is cleared until a write succeeds
        }
    }

    private func markMeta() {
        metaDirty = true
        scheduleSave()
    }

    private func markNotebook(_ id: String) {
        if let i = notebooks.firstIndex(where: { $0.id == id }) { manifests[id]?.notebook = notebooks[i] }
        dirtyManifests.insert(id)
        scheduleSave()
    }

    // MARK: Open notebooks

    /// Loads a notebook for editing. The document autosaves through this store.
    func openDocument(_ id: String) -> NotebookDocument? {
        if let d = openDocuments[id] { return d }
        guard let doc = files.loadDocument(id) else { return nil }
        doc.onChange = { [weak self] in self?.scheduleSave() }
        openDocuments[id] = doc
        return doc
    }

    /// Flushes and folds an edited document's record and counts back into the library.
    func closeDocument(_ id: String) {
        guard let doc = openDocuments[id] else { return }
        flushNow()
        openDocuments[id] = nil
        adopt(doc)
    }

    private func adopt(_ doc: NotebookDocument) {
        manifests[doc.id] = doc.manifest()
        if let i = notebooks.firstIndex(where: { $0.id == doc.id }) { notebooks[i] = doc.notebook }
        contentRevision += 1
    }

    // MARK: Notebooks

    func notebook(_ id: String) -> Notebook? { notebooks.first { $0.id == id } }

    /// Every notebook, most recently edited first — the "Continue work" card shows the first.
    var recent: [Notebook] { notebooks.sorted { $0.updatedAt > $1.updatedAt } }

    func manifest(_ id: String) -> NotebookManifest? { manifests[id] }

    /// The first page's record, for the card thumbnail.
    func firstPage(of id: String) -> Page? { manifests[id]?.pages.first }

    /// New notebooks go to the top of their folder's list. `paper` becomes the starting page's paper (a board
    /// keeps it on its origin chunk, as the web does).
    @discardableResult
    func createNotebook(name: String, folderId: String?, paper: Paper, kind: Notebook.Kind) -> Notebook {
        let now = Self.now()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = kind == .board ? "Untitled board" : "Untitled notebook"
        let nb = Notebook(id: UUID().uuidString, name: trimmed.isEmpty ? fallback : trimmed,
                          kind: kind == .board ? .board : nil, folderId: folderId,
                          order: topOrder(folderId), createdAt: now, updatedAt: now)
        let page: Page
        if kind == .board {
            page = Page(id: "\(nb.id):0,0", notebookId: nb.id, index: 0, paper: paper, col: 0, row: 0, createdAt: now, updatedAt: now)
        } else {
            page = Page(id: UUID().uuidString, notebookId: nb.id, index: 0, paper: paper, createdAt: now, updatedAt: now)
        }
        let doc = NotebookDocument(notebook: nb, pages: [page])
        notebooks.append(nb)
        manifests[nb.id] = doc.manifest()
        dirtyManifests.insert(nb.id)
        scheduleSave()
        return nb
    }

    /// Adds a finished notebook (a PDF import) at the top of a folder and writes it to disk.
    @discardableResult
    func addNotebook(_ doc: NotebookDocument, assets: [Asset], folderId: String?) throws -> Notebook {
        var nb = doc.notebook
        nb.folderId = folderId
        nb.order = topOrder(folderId)
        doc.setNotebook(nb)
        try files.writeNew(doc)
        for a in assets { try files.writeAsset(a) }
        notebooks.append(doc.notebook)
        manifests[doc.id] = doc.manifest()
        return doc.notebook
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].name = trimmed
        markNotebook(id)
    }

    func setCover(_ id: String, _ cover: Notebook.Cover?) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].cover = cover
        notebooks[i].updatedAt = Self.now()
        markNotebook(id)
    }

    func delete(_ id: String) {
        notebooks.removeAll { $0.id == id }
        manifests[id] = nil
        openDocuments[id] = nil
        dirtyManifests.remove(id)
        files.deleteNotebook(id)
    }

    /// Moves a notebook to another folder (top of that folder's list).
    func moveNotebook(_ id: String, to folderId: String?) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }), notebooks[i].folderId != folderId else { return }
        notebooks[i].folderId = folderId
        notebooks[i].order = topOrder(folderId)
        markNotebook(id)
    }

    /// Top-right badge text: page count, or item count for a board.
    func sizeLabel(for nb: Notebook) -> String {
        guard let m = manifests[nb.id] else { return "1 page" }
        if nb.isBoard {
            let n = m.itemCount
            return n == 0 ? "Empty" : "\(n) item\(n == 1 ? "" : "s")"
        }
        let n = m.contentPageCount
        return "\(n) page\(n == 1 ? "" : "s")"
    }

    // MARK: Folders

    func folder(_ id: String) -> Folder? { folders.first { $0.id == id } }

    /// Direct subfolders, by name.
    func folderList(_ parentId: String?) -> [Folder] {
        folders.filter { $0.parentId == parentId }
            .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Root → … → the folder itself.
    func folderPath(_ id: String?) -> [Folder] {
        var path: [Folder] = []
        var cur = id.flatMap(folder)
        while let f = cur {
            path.insert(f, at: 0)
            cur = f.parentId.flatMap(folder)
        }
        return path
    }

    /// Number of notebooks in a folder and all of its subfolders.
    func notebookCount(_ folderId: String?) -> Int {
        notebooks.filter { $0.folderId == folderId }.count
            + folderList(folderId).reduce(0) { $0 + notebookCount($1.id) }
    }

    @discardableResult
    func createFolder(name: String, parentId: String?) -> Folder {
        let now = Self.now()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let f = Folder(id: UUID().uuidString, name: trimmed.isEmpty ? "Untitled folder" : trimmed,
                       parentId: parentId, createdAt: now, updatedAt: now)
        folders.append(f)
        markMeta()
        return f
    }

    func renameFolder(_ id: String, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { folders[i].name = trimmed }
        folders[i].updatedAt = Self.now()
        markMeta()
    }

    /// Removes a folder; everything in it (notebooks, dividers, subfolders) moves up to its parent.
    func deleteFolder(_ id: String) {
        guard let f = folder(id) else { return }
        let parent = f.parentId
        for i in notebooks.indices where notebooks[i].folderId == id {
            notebooks[i].folderId = parent
            markNotebook(notebooks[i].id)
        }
        for i in dividers.indices where dividers[i].folderId == id { dividers[i].folderId = parent }
        for i in folders.indices where folders[i].parentId == id { folders[i].parentId = parent }
        folders.removeAll { $0.id == id }
        renumber(parent)
        markMeta()
    }

    // MARK: Folder list order

    /// Notebooks and dividers of one folder, in manual order.
    func folderItems(_ folderId: String?) -> [FolderItem] {
        let items = notebooks.filter { $0.folderId == folderId }.map(FolderItem.notebook)
            + dividers.filter { $0.folderId == folderId }.map(FolderItem.divider)
        return items.sorted { $0.order != $1.order ? $0.order < $1.order : $0.createdAt < $1.createdAt }
    }

    /// Adds a labelled divider at the end of a folder's list, or just above a notebook.
    func createDivider(folderId: String?, label: String, aboveNotebookId: String? = nil) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let last = folderItems(folderId).last?.order ?? -1
        let order = aboveNotebookId.flatMap(notebook).map { $0.order - 0.5 } ?? (last + 1)
        dividers.append(Divider(id: UUID().uuidString, folderId: folderId,
                                label: trimmed.isEmpty ? "Divider" : trimmed,
                                order: order, createdAt: Self.now()))
        renumber(folderId)
        markMeta()
    }

    func renameDivider(_ id: String, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = dividers.firstIndex(where: { $0.id == id }) else { return }
        dividers[i].label = trimmed
        markMeta()
    }

    func deleteDivider(_ id: String) {
        dividers.removeAll { $0.id == id }
        markMeta()
    }

    /// Swaps a notebook or divider with its neighbour in the folder list (`dir` -1 = up, 1 = down).
    func moveItem(_ id: String, by dir: Int) {
        let folderId = notebook(id)?.folderId ?? dividers.first { $0.id == id }?.folderId
        let items = folderItems(folderId)
        guard let i = items.firstIndex(where: { $0.id == id }), items.indices.contains(i + dir) else { return }
        let (a, b) = (items[i], items[i + dir])
        setOrder(a.id, b.order)
        setOrder(b.id, a.order)
        renumber(folderId)
    }

    private func setOrder(_ id: String, _ order: Double) {
        if let i = notebooks.firstIndex(where: { $0.id == id }) {
            notebooks[i].order = order
            markNotebook(id)
        } else if let i = dividers.firstIndex(where: { $0.id == id }) {
            dividers[i].order = order
            markMeta()
        }
    }

    /// The order value that puts a new item at the top of a folder's list.
    private func topOrder(_ folderId: String?) -> Double {
        (folderItems(folderId).first?.order ?? 1) - 1
    }

    /// Re-assigns 0, 1, 2… down a folder's list so fractional / negative orders don't accumulate.
    private func renumber(_ folderId: String?) {
        for (n, item) in folderItems(folderId).enumerated() where item.order != Double(n) {
            setOrder(item.id, Double(n))
        }
    }

    // MARK: Backup

    struct ImportSummary: Equatable {
        var notebooks: Int
        var folders: Int
        var warnings: [String]
    }

    /// Restores a backup file as new copies next to what is already here; nothing existing is touched.
    @discardableResult
    func importBackup(_ data: Data) throws -> ImportSummary {
        let decoded = try BackupCodec.decode(data)
        var result = BackupImporter.makeCopies(of: decoded.backup)
        let rootBase = (folderItems(nil).last?.order ?? -1) + 1
        // imported root-level items go after what is already at the root, keeping their own relative order
        let rootNotebooks = result.backup.notebooks.indices.filter { result.backup.notebooks[$0].folderId == nil }
        let rootDividers = result.backup.dividers.indices.filter { result.backup.dividers[$0].folderId == nil }
        let rootOrders = (rootNotebooks.map { result.backup.notebooks[$0].order } + rootDividers.map { result.backup.dividers[$0].order }).sorted()
        func shifted(_ order: Double) -> Double {
            rootBase + Double(rootOrders.firstIndex(of: order) ?? 0)
        }
        for i in rootNotebooks { result.backup.notebooks[i].order = shifted(result.backup.notebooks[i].order) }
        for i in rootDividers { result.backup.dividers[i].order = shifted(result.backup.dividers[i].order) }

        let written = try files.writeBackupNotebooks(result.backup)
        for m in written {
            manifests[m.notebook.id] = m
            notebooks.append(m.notebook)
        }
        folders += result.backup.folders
        dividers += result.backup.dividers
        markMeta()
        contentRevision += 1
        return ImportSummary(notebooks: written.count, folders: result.backup.folders.count,
                             warnings: decoded.warnings + result.warnings)
    }

    /// The whole library as a backup file's bytes.
    func exportBackup() throws -> Data {
        flushNow()
        let all = notebooks.compactMap { manifests[$0.id] }
        return try BackupCodec.encode(files.makeBackup(folders: folders, dividers: dividers, manifests: all))
    }
}
