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

/// In-memory library, seeded from the bundled sample backup. Nothing is persisted yet.
/// Folder, divider and ordering rules follow the web store (src/store.ts).
@Observable
final class LibraryStore {
    var notebooks: [Notebook] = []
    var folders: [Folder] = []
    var dividers: [Divider] = []
    var pages: [Page] = []
    var loadError: String?
    private var itemCounts: [String: Int] = [:]

    init() {
        guard let url = Bundle.main.url(forResource: "backup-sample", withExtension: "json") else {
            loadError = "backup-sample.json is missing from the app bundle."
            return
        }
        do {
            let backup = try BackupCodec.decode(Data(contentsOf: url)).backup
            notebooks = backup.notebooks
            folders = backup.folders
            dividers = backup.dividers
            pages = backup.pages
            for stroke in backup.strokes { itemCounts[stroke.notebookId, default: 0] += 1 }
            for element in backup.elements { itemCounts[element.notebookId, default: 0] += 1 }
        } catch {
            loadError = error.localizedDescription
        }
    }

    private static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    // MARK: Notebooks

    func notebook(_ id: String) -> Notebook? { notebooks.first { $0.id == id } }

    /// New notebooks go to the top of their folder's list. `paper` becomes the starting page's
    /// paper (a board keeps it on its origin chunk, as the web does).
    @discardableResult
    func createNotebook(name: String, folderId: String?, paper: Paper, kind: Notebook.Kind) -> Notebook {
        let now = Self.now()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = kind == .board ? "Untitled board" : "Untitled notebook"
        let nb = Notebook(id: UUID().uuidString, name: trimmed.isEmpty ? fallback : trimmed,
                          kind: kind == .board ? .board : nil, folderId: folderId,
                          order: topOrder(folderId), createdAt: now, updatedAt: now)
        notebooks.append(nb)
        if kind == .board {
            pages.append(Page(id: "\(nb.id):0,0", notebookId: nb.id, index: 0, paper: paper,
                              col: 0, row: 0, createdAt: now, updatedAt: now))
        } else {
            pages.append(Page(id: UUID().uuidString, notebookId: nb.id, index: 0, paper: paper,
                              createdAt: now, updatedAt: now))
        }
        return nb
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].name = trimmed
    }

    func delete(_ id: String) {
        notebooks.removeAll { $0.id == id }
        pages.removeAll { $0.notebookId == id }
        itemCounts[id] = nil
    }

    /// Moves a notebook to another folder (top of that folder's list).
    func moveNotebook(_ id: String, to folderId: String?) {
        guard let i = notebooks.firstIndex(where: { $0.id == id }), notebooks[i].folderId != folderId else { return }
        notebooks[i].folderId = folderId
        notebooks[i].order = topOrder(folderId)
    }

    /// Top-right badge text: page count, or item count for a board.
    func sizeLabel(for nb: Notebook) -> String {
        if nb.isBoard {
            let n = itemCounts[nb.id, default: 0]
            return n == 0 ? "Empty" : "\(n) item\(n == 1 ? "" : "s")"
        }
        let n = max(pages.filter { $0.notebookId == nb.id }.count, 1)
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
        return f
    }

    func renameFolder(_ id: String, to name: String) {
        guard let i = folders.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { folders[i].name = trimmed }
        folders[i].updatedAt = Self.now()
    }

    /// Removes a folder; everything in it (notebooks, dividers, subfolders) moves up to its parent.
    func deleteFolder(_ id: String) {
        guard let f = folder(id) else { return }
        let parent = f.parentId
        for i in notebooks.indices where notebooks[i].folderId == id { notebooks[i].folderId = parent }
        for i in dividers.indices where dividers[i].folderId == id { dividers[i].folderId = parent }
        for i in folders.indices where folders[i].parentId == id { folders[i].parentId = parent }
        folders.removeAll { $0.id == id }
        renumber(parent)
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
    }

    func renameDivider(_ id: String, to label: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = dividers.firstIndex(where: { $0.id == id }) else { return }
        dividers[i].label = trimmed
    }

    func deleteDivider(_ id: String) {
        dividers.removeAll { $0.id == id }
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
        } else if let i = dividers.firstIndex(where: { $0.id == id }) {
            dividers[i].order = order
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
}
