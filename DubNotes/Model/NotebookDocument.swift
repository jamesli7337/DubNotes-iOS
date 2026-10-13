import Foundation

/// One notebook held in memory while it is open: its pages in order, plus each page's strokes and elements.
/// Page rules follow store.ts (trailing blank page, insert/delete renumbering, duplicate, paper scope).
/// Every mutation records what changed so the autosaver writes only dirty files.
final class NotebookDocument {
    private(set) var notebook: Notebook
    private(set) var pages: [Page]
    private var strokesByPage: [String: [Stroke]] = [:]
    private var elementsByPage: [String: [PageElement]] = [:]

    /// Pages whose content (strokes/elements) or record changed since the last save.
    private(set) var dirtyPages: Set<String> = []
    /// Pages removed since the last save.
    private(set) var deletedPages: Set<String> = []
    /// The notebook record or page list changed since the last save.
    private(set) var manifestDirty = false

    /// Called after any change, so the owner can schedule an autosave.
    var onChange: (() -> Void)?

    init(notebook: Notebook, pages: [Page], strokes: [Stroke] = [], elements: [PageElement] = []) {
        self.notebook = notebook
        self.pages = pages.sorted { $0.index < $1.index }
        for s in strokes { strokesByPage[s.pageId, default: []].append(s) }
        for e in elements { elementsByPage[e.pageId, default: []].append(e) }
        for key in strokesByPage.keys { strokesByPage[key]?.sort { $0.createdAt < $1.createdAt } }
        for key in elementsByPage.keys { elementsByPage[key]?.sort { $0.createdAt < $1.createdAt } }
    }

    // MARK: Reading

    var id: String { notebook.id }

    func page(_ id: String) -> Page? { pages.first { $0.id == id } }

    func strokes(of pageId: String) -> [Stroke] { strokesByPage[pageId] ?? [] }

    func elements(of pageId: String) -> [PageElement] { elementsByPage[pageId] ?? [] }

    /// Everything on a page in z-order: strokes and elements interleaved by `createdAt`.
    func items(of pageId: String) -> [PageItem] {
        let s = strokes(of: pageId).map(PageItem.stroke)
        let e = elements(of: pageId).map(PageItem.element)
        return (s + e).sorted { $0.createdAt < $1.createdAt }
    }

    func item(_ id: String, on pageId: String) -> PageItem? {
        items(of: pageId).first { $0.id == id }
    }

    /// A page with no committed content: no strokes, no elements, no background.
    func isBlank(_ pageId: String) -> Bool {
        strokes(of: pageId).isEmpty && elements(of: pageId).isEmpty && page(pageId)?.background == nil
    }

    /// Every page except the automatic trailing blank one (when there is more than one page).
    var contentPages: [Page] {
        if pages.count > 1, let last = pages.last, isBlank(last.id) { return Array(pages.dropLast()) }
        return pages
    }

    /// Page count shown on a library card (always at least 1).
    var contentPageCount: Int { max(contentPages.count, 1) }

    var itemCount: Int {
        pages.reduce(0) { $0 + strokes(of: $1.id).count + elements(of: $1.id).count }
    }

    // MARK: Change tracking

    private static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    private func touch() {
        notebook.updatedAt = Self.now()
        manifestDirty = true
        onChange?()
    }

    private func markPage(_ id: String) {
        dirtyPages.insert(id)
        deletedPages.remove(id)
    }

    /// Called by the saver once everything dirty has been written.
    func clearDirty() {
        dirtyPages.removeAll()
        deletedPages.removeAll()
        manifestDirty = false
    }

    func rename(_ name: String) {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        notebook.name = t
        touch()
    }

    func setNotebook(_ nb: Notebook) {
        notebook = nb
        manifestDirty = true
        onChange?()
    }

    // MARK: Pages

    /// Adds a page at `at` (default: the end). Its paper is copied from the page it follows.
    @discardableResult
    func addPage(at: Int? = nil) -> Page {
        let index = min(max(at ?? pages.count, 0), pages.count)
        let prev = index > 0 ? pages[index - 1] : nil
        let now = Self.now()
        let page = Page(id: UUID().uuidString, notebookId: notebook.id, index: index,
                        paper: prev?.paper ?? Paper.default, background: nil, w: nil, h: nil, col: nil, row: nil,
                        createdAt: now, updatedAt: now)
        insertPage(page, at: index)
        return page
    }

    /// Re-inserts a page object (keeping its id) at a position; used by undo/redo.
    func insertPage(_ page: Page, at index: Int) {
        var p = page
        pages.removeAll { $0.id == p.id }
        let i = min(max(index, 0), pages.count)
        p.index = i
        pages.insert(p, at: i)
        reindex()
        markPage(p.id)
        touch()
    }

    func deletePage(_ id: String) { deletePages([id]) }

    func deletePages(_ ids: [String]) {
        let gone = Set(ids).intersection(pages.map(\.id))
        guard !gone.isEmpty else { return }
        for id in gone {
            strokesByPage[id] = nil
            elementsByPage[id] = nil
            dirtyPages.remove(id)
            deletedPages.insert(id)
        }
        pages.removeAll { gone.contains($0.id) }
        reindex()
        touch()
    }

    /// Applies a new page order. Ids that no longer exist are ignored; pages it doesn't name keep their
    /// relative order after it. Returns false when nothing changed.
    @discardableResult
    func reorderPages(_ order: [String]) -> Bool {
        var listed = Set<String>()
        var next: [Page] = []
        for id in order {
            if let p = page(id), !listed.contains(id) {
                listed.insert(id)
                next.append(p)
            }
        }
        guard !next.isEmpty else { return false }
        let rest = pages.filter { !listed.contains($0.id) }
        let all = next + rest
        if all.map(\.id) == pages.map(\.id) { return false }
        pages = all
        reindex()
        touch()
        return true
    }

    /// Moves a page to an arbitrary position (drag reorder). False when it is already there.
    @discardableResult
    func movePage(_ id: String, to index: Int) -> Bool {
        guard let from = pages.firstIndex(where: { $0.id == id }) else { return false }
        let target = min(max(index, 0), pages.count - 1)
        if target == from { return false }
        var order = pages.map(\.id)
        let moved = order.remove(at: from)
        order.insert(moved, at: target)
        return reorderPages(order)
    }

    /// Duplicates a page (paper, background, every stroke and element, re-keyed) right after the original.
    @discardableResult
    func duplicatePage(_ id: String) -> Page? {
        guard let src = page(id) else { return nil }
        let now = Self.now()
        var copy = Page(id: UUID().uuidString, notebookId: notebook.id, index: src.index + 1, paper: src.paper,
                        background: src.background, w: src.w, h: src.h, col: nil, row: nil, createdAt: now, updatedAt: now)
        copy.index = src.index + 1
        insertPage(copy, at: copy.index)
        // createdAt is reassigned sequentially so z-order survives items sharing a millisecond
        for (i, item) in items(of: id).enumerated() {
            let at = now + Double(i)
            switch item {
            case .stroke(var s):
                s.id = UUID().uuidString; s.pageId = copy.id; s.notebookId = notebook.id; s.createdAt = at
                addStroke(s)
            case .element(var e):
                e.id = UUID().uuidString; e.pageId = copy.id; e.notebookId = notebook.id; e.createdAt = at
                addElement(e)
            }
        }
        return copy
    }

    /// Paper change for one page, or every page when `allPages`.
    func setPaper(_ pageId: String, paper: Paper, allPages: Bool) {
        guard page(pageId) != nil else { return }
        let now = Self.now()
        for i in pages.indices where allPages || pages[i].id == pageId {
            pages[i].paper = paper
            pages[i].updatedAt = now
            markPage(pages[i].id)
        }
        touch()
    }

    func setBackground(_ pageId: String, _ background: PageBackground?) {
        guard let i = pages.firstIndex(where: { $0.id == pageId }) else { return }
        pages[i].background = background
        pages[i].updatedAt = Self.now()
        markPage(pageId)
        touch()
    }

    func setPageSize(_ pageId: String, w: Double, h: Double) {
        guard let i = pages.firstIndex(where: { $0.id == pageId }) else { return }
        pages[i].w = w
        pages[i].h = h
        pages[i].updatedAt = Self.now()
        markPage(pageId)
        touch()
    }

    /// Keeps a blank page at the end: appends one if the last page has content (or there are none). It never
    /// removes pages. Returns true when a page was added; never recorded as an undo step.
    @discardableResult
    func enforceTrailingBlank() -> Bool {
        if pages.isEmpty || !isBlank(pages[pages.count - 1].id) {
            addPage()
            return true
        }
        return false
    }

    private func reindex() {
        for i in pages.indices where pages[i].index != i {
            pages[i].index = i
            markPage(pages[i].id)
        }
    }

    // MARK: Items

    func addStroke(_ s: Stroke) {
        strokesByPage[s.pageId, default: []].append(s)
        strokesByPage[s.pageId]?.sort { $0.createdAt < $1.createdAt }
        markPage(s.pageId)
        touch()
    }

    func addElement(_ e: PageElement) {
        elementsByPage[e.pageId, default: []].append(e)
        elementsByPage[e.pageId]?.sort { $0.createdAt < $1.createdAt }
        markPage(e.pageId)
        touch()
    }

    func addItems(_ items: [PageItem]) {
        for it in items {
            switch it {
            case .stroke(let s): addStroke(s)
            case .element(let e): addElement(e)
            }
        }
    }

    /// Removes by id from one page and returns what was removed.
    @discardableResult
    func removeItems(on pageId: String, ids: Set<String>) -> [PageItem] {
        var removed: [PageItem] = []
        if let arr = strokesByPage[pageId] {
            removed += arr.filter { ids.contains($0.id) }.map(PageItem.stroke)
            strokesByPage[pageId] = arr.filter { !ids.contains($0.id) }
        }
        if let arr = elementsByPage[pageId] {
            removed += arr.filter { ids.contains($0.id) }.map(PageItem.element)
            elementsByPage[pageId] = arr.filter { !ids.contains($0.id) }
        }
        if !removed.isEmpty {
            markPage(pageId)
            touch()
        }
        return removed
    }

    /// Swaps items in place by id, keeping z-order. Unknown ids are ignored.
    func replaceItems(on pageId: String, with items: [PageItem]) {
        var touched = false
        for it in items {
            switch it {
            case .stroke(let s):
                if let i = strokesByPage[pageId]?.firstIndex(where: { $0.id == s.id }) {
                    strokesByPage[pageId]?[i] = s
                    touched = true
                }
            case .element(let e):
                if let i = elementsByPage[pageId]?.firstIndex(where: { $0.id == e.id }) {
                    elementsByPage[pageId]?[i] = e
                    touched = true
                }
            }
        }
        if touched {
            markPage(pageId)
            touch()
        }
    }

    /// Replaces a page's whole stroke list (used when the ink canvas reports a new drawing).
    func setStrokes(_ strokes: [Stroke], on pageId: String) {
        strokesByPage[pageId] = strokes.sorted { $0.createdAt < $1.createdAt }
        markPage(pageId)
        touch()
    }

    // MARK: Snapshots for saving

    func content(of pageId: String) -> PageContent {
        PageContent(strokes: strokes(of: pageId), elements: elements(of: pageId))
    }

    func manifest() -> NotebookManifest {
        let last = pages.last
        return NotebookManifest(notebook: notebook, pages: pages,
                                lastPageBlank: last.map { isBlank($0.id) } ?? true,
                                itemCount: itemCount)
    }
}

/// What lives in one page file besides the `Page` record itself.
struct PageContent: Codable, Equatable {
    var strokes: [Stroke] = []
    var elements: [PageElement] = []
}

/// `notebook.json`: the notebook record, every `Page` record (small: no strokes), and the counts the library
/// shows without opening any page file.
struct NotebookManifest: Codable, Equatable {
    var notebook: Notebook
    var pages: [Page]
    var lastPageBlank: Bool
    var itemCount: Int

    /// Page count shown on a library card (excluding the automatic trailing blank page, at least 1).
    var contentPageCount: Int {
        var n = pages.count
        if n > 1 && lastPageBlank { n -= 1 }
        return max(n, 1)
    }
}
