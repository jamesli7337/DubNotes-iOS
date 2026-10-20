import Foundation

/// One notebook held in memory while it is open: its pages in order, plus each page's strokes and elements.
/// Page rules follow store.ts (trailing blank page, insert/delete renumbering, duplicate, paper scope).
/// Every mutation records what changed so the autosaver writes only dirty files.
final class NotebookDocument {
    private(set) var notebook: Notebook
    private(set) var pages: [Page]
    private var strokesByPage: [String: [Stroke]] = [:]
    private var elementsByPage: [String: [PageElement]] = [:]
    private var extentCache: PageRect?

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

    func page(_ id: String) -> Page? {
        if isBoardSurface(id) { return boardSurfacePage() }
        return pages.first { $0.id == id }
    }

    func strokes(of pageId: String) -> [Stroke] {
        if isBoardSurface(pageId) { return strokesByPage.values.flatMap { $0 }.sorted { Self.zOrder($0.createdAt, $0.id, $1.createdAt, $1.id) } }
        return strokesByPage[pageId] ?? []
    }

    func elements(of pageId: String) -> [PageElement] {
        if isBoardSurface(pageId) { return elementsByPage.values.flatMap { $0 }.sorted { Self.zOrder($0.createdAt, $0.id, $1.createdAt, $1.id) } }
        return elementsByPage[pageId] ?? []
    }

    private static func zOrder(_ ta: Double, _ ia: String, _ tb: Double, _ ib: String) -> Bool {
        ta != tb ? ta < tb : ia < ib
    }

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

    /// Paper change for one page, or every page when `allPages`. A board has one paper, so it always applies to
    /// every chunk (and the origin chunk is created if the board has none yet).
    func setPaper(_ pageId: String, paper: Paper, allPages: Bool) {
        guard page(pageId) != nil else { return }
        let all = allPages || isBoard
        if isBoard { ensureChunk(col: 0, row: 0) }
        let now = Self.now()
        for i in pages.indices where all || pages[i].id == pageId {
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
        guard !isBoard else { return } // a board's chunks have no order; their index stays 0
        for i in pages.indices where pages[i].index != i {
            pages[i].index = i
            markPage(pages[i].id)
        }
    }

    // MARK: Items

    func addStroke(_ stroke: Stroke) {
        var s = stroke
        if isBoard { s.pageId = boardChunk(for: .stroke(s)) }
        strokesByPage[s.pageId, default: []].append(s)
        strokesByPage[s.pageId]?.sort { $0.createdAt < $1.createdAt }
        markPage(s.pageId)
        itemsChanged()
        touch()
    }

    func addElement(_ element: PageElement) {
        var e = element
        if isBoard { e.pageId = boardChunk(for: .element(e)) }
        elementsByPage[e.pageId, default: []].append(e)
        elementsByPage[e.pageId]?.sort { $0.createdAt < $1.createdAt }
        markPage(e.pageId)
        itemsChanged()
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
        // on a board's surface the items sit in whichever chunk holds them
        let holders = isBoardSurface(pageId) ? Array(Set(strokesByPage.keys).union(elementsByPage.keys)) : [pageId]
        var removed: [PageItem] = []
        for holder in holders {
            var here = false
            if let arr = strokesByPage[holder] {
                let gone = arr.filter { ids.contains($0.id) }
                if !gone.isEmpty {
                    removed += gone.map(PageItem.stroke)
                    strokesByPage[holder] = arr.filter { !ids.contains($0.id) }
                    here = true
                }
            }
            if let arr = elementsByPage[holder] {
                let gone = arr.filter { ids.contains($0.id) }
                if !gone.isEmpty {
                    removed += gone.map(PageItem.element)
                    elementsByPage[holder] = arr.filter { !ids.contains($0.id) }
                    here = true
                }
            }
            if here { markPage(holder) }
        }
        if !removed.isEmpty {
            itemsChanged()
            touch()
        }
        return removed
    }

    /// Swaps items in place by id, keeping z-order (and, on a board, the chunk each one is stored in). Unknown ids
    /// are ignored.
    func replaceItems(on pageId: String, with items: [PageItem]) {
        let surface = isBoardSurface(pageId)
        var touched = false
        for it in items {
            let holders = surface ? Array(Set(strokesByPage.keys).union(elementsByPage.keys)) : [pageId]
            switch it {
            case .stroke(var s):
                for holder in holders {
                    guard let i = strokesByPage[holder]?.firstIndex(where: { $0.id == s.id }) else { continue }
                    if surface { s.pageId = holder }
                    strokesByPage[holder]?[i] = s
                    markPage(holder)
                    touched = true
                    break
                }
            case .element(var e):
                for holder in holders {
                    guard let i = elementsByPage[holder]?.firstIndex(where: { $0.id == e.id }) else { continue }
                    if surface { e.pageId = holder }
                    elementsByPage[holder]?[i] = e
                    markPage(holder)
                    touched = true
                    break
                }
            }
        }
        if touched {
            itemsChanged()
            touch()
        }
    }

    /// Replaces a page's whole stroke list (used when the ink canvas reports a new drawing).
    func setStrokes(_ strokes: [Stroke], on pageId: String) {
        strokesByPage[pageId] = strokes.sorted { $0.createdAt < $1.createdAt }
        markPage(pageId)
        itemsChanged()
        touch()
    }

    // MARK: Board

    /// Cell size of a board's storage grid, in board units.
    static let boardChunkSize = 2048.0
    /// Room kept around the content (and the origin chunk) when sizing the board's extent.
    static let boardPadding = 4096.0

    var isBoard: Bool { notebook.isBoard }

    /// The id the board's single virtual page answers to. Reading it returns every chunk's items combined; adding
    /// to it files each item under the chunk its bounding box starts in. It has no chunk id's comma, so it can
    /// never collide with one, and it is never stored.
    var boardSurfaceId: String { "\(notebook.id):board" }

    func isBoardSurface(_ pageId: String) -> Bool { isBoard && pageId == boardSurfaceId }

    static func chunkId(notebookId: String, col: Int, row: Int) -> String { "\(notebookId):\(col),\(row)" }

    /// The cell a chunk id names (`<notebookId>:<col>,<row>`), or nil when `pageId` is not one of this board's.
    func chunkCell(of pageId: String) -> (col: Int, row: Int)? {
        let prefix = "\(notebook.id):"
        guard pageId.hasPrefix(prefix) else { return nil }
        let parts = pageId.dropFirst(prefix.count).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2, let col = Int(parts[0]), let row = Int(parts[1]) else { return nil }
        return (col, row)
    }

    /// The chunk a point falls in.
    static func chunkCell(x: Double, y: Double) -> (col: Int, row: Int) {
        (Int((x / boardChunkSize).rounded(.down)), Int((y / boardChunkSize).rounded(.down)))
    }

    /// Finds a chunk record, creating it (inheriting the board's paper) when it doesn't exist yet.
    @discardableResult
    func ensureChunk(col: Int, row: Int) -> Page {
        let id = Self.chunkId(notebookId: notebook.id, col: col, row: row)
        if let existing = pages.first(where: { $0.id == id }) { return existing }
        let now = Self.now()
        let chunk = Page(id: id, notebookId: notebook.id, index: 0, paper: boardPaper, background: nil, w: nil, h: nil,
                         col: col, row: row, createdAt: now, updatedAt: now)
        pages.append(chunk)
        markPage(id)
        manifestDirty = true
        return chunk
    }

    /// Where an item is filed. One that already carries a real chunk id keeps it (undo and redo hand back items
    /// with the id they were stored under); anything else goes to the chunk its bounding-box origin falls in.
    private func boardChunk(for item: PageItem) -> String {
        if let cell = chunkCell(of: item.pageId) { return ensureChunk(col: cell.col, row: cell.row).id }
        let b = Geometry.itemBounds(item)
        let cell = Self.chunkCell(x: b.x, y: b.y)
        return ensureChunk(col: cell.col, row: cell.row).id
    }

    /// The board's paper, held by its origin chunk `<id>:0,0`.
    var boardPaper: Paper {
        let origin = Self.chunkId(notebookId: notebook.id, col: 0, row: 0)
        return pages.first { $0.id == origin }?.paper ?? pages.first?.paper ?? .default
    }

    /// Every item's bounds plus the origin chunk, padded and snapped outward to the chunk grid.
    var boardExtent: PageRect {
        if let cached = extentCache { return cached }
        let c = Self.boardChunkSize
        var rects = [PageRect(x: 0, y: 0, w: c, h: c)]
        for list in strokesByPage.values { for s in list { rects.append(Geometry.itemBounds(.stroke(s))) } }
        for list in elementsByPage.values { for e in list { rects.append(Geometry.itemBounds(.element(e))) } }
        let u = Geometry.unionRects(rects) ?? PageRect(x: 0, y: 0, w: c, h: c)
        let pad = Self.boardPadding
        let x0 = ((u.x - pad) / c).rounded(.down) * c
        let y0 = ((u.y - pad) / c).rounded(.down) * c
        let x1 = ((u.x + u.w + pad) / c).rounded(.up) * c
        let y1 = ((u.y + u.h + pad) / c).rounded(.up) * c
        let extent = PageRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
        extentCache = extent
        return extent
    }

    /// The board as one page: board coordinates start at its origin, it is as big as the extent.
    private func boardSurfacePage() -> Page {
        let e = boardExtent
        let originId = Self.chunkId(notebookId: notebook.id, col: 0, row: 0)
        let origin = pages.first { $0.id == originId }
        return Page(id: boardSurfaceId, notebookId: notebook.id, index: 0, paper: boardPaper, background: nil,
                    w: e.w, h: e.h, col: nil, row: nil, createdAt: origin?.createdAt ?? 0, updatedAt: origin?.updatedAt ?? 0,
                    originX: e.x, originY: e.y)
    }

    private func itemsChanged() { extentCache = nil }

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
