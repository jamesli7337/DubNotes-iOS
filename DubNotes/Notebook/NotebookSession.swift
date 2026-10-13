import Foundation
import Observation
import UIKit

enum GuideKind: String {
    case ruler, protractor
}

/// Tool state shared by every open notebook, persisted as it changes.
@Observable
final class ToolStore {
    static let shared = ToolStore()

    /// Written through `NotebookSession.settings`, which also saves it.
    var settings: ToolSettings

    init() {
        settings = ToolSettings.load()
    }
}

/// A selection somewhere in the notebook, as the dock and callout need to know it.
struct SelectionInfo: Equatable {
    var pageId: String
    var count: Int
    var hasPen: Bool
    var hasHighlighter: Bool
}

/// Everything behind one open notebook screen: its document, undo history, clipboard and the link to the
/// page column. Views and page canvases report edits here; it records them for undo, keeps the trailing
/// blank page, and tells the column what to repaint. Autosave rides on the document's change callback.
@Observable
final class NotebookSession {
    /// Offset applied when pasting back onto the page the items were copied from.
    static let pasteOffset = 24.0

    @ObservationIgnored let library: LibraryStore
    @ObservationIgnored let doc: NotebookDocument
    @ObservationIgnored let tools = ToolStore.shared
    @ObservationIgnored weak var column: PageColumnController?

    private(set) var history = UndoHistory()
    var currentPageId: String?
    var guideKind: GuideKind?
    var guidePageId: String?
    var selection: SelectionInfo?
    /// Bumped when the page list changes shape, so SwiftUI pieces (page manager, titles) refresh.
    private(set) var structureRevision = 0
    /// Bumped on any edit; the page manager's thumbnails watch it.
    private(set) var contentRevision = 0
    private(set) var clipboard: [PageItem] = []
    private var clipboardPageId: String?
    var title: String

    var canUndo: Bool { history.canUndo }
    var canRedo: Bool { history.canRedo }
    var settings: ToolSettings {
        get { tools.settings }
        set {
            tools.settings = newValue
            newValue.save()
        }
    }

    init?(library: LibraryStore, notebookId: String) {
        guard let doc = library.openDocument(notebookId) else { return nil }
        self.library = library
        self.doc = doc
        self.title = doc.notebook.name
        self.currentPageId = doc.pages.first?.id
        if !doc.notebook.isBoard { doc.enforceTrailingBlank() }
        var s = tools.settings
        s.resetActiveColorsToPrimary()
        settings = s
    }

    func close() {
        column?.deactivateAll()
        library.closeDocument(doc.id)
        var s = tools.settings
        s.resetActiveColorsToPrimary()
        settings = s
    }

    func rename(_ name: String) {
        doc.rename(name)
        title = doc.notebook.name
    }

    // MARK: Edits

    /// Records an op the caller has already applied to the document.
    func record(_ op: EditOp, refreshPages: Bool = true) {
        history.push(op)
        afterEdit(op.pageIds, structure: op.changesStructure, refresh: refreshPages)
    }

    private func afterEdit(_ pageIds: [String], structure: Bool, refresh: Bool = true) {
        contentRevision += 1
        var structural = structure
        if !doc.notebook.isBoard && doc.enforceTrailingBlank() { structural = true }
        if structural {
            structureRevision += 1
            column?.syncPages()
        } else if refresh {
            column?.refresh(pageIds: pageIds)
        }
    }

    /// Ink changed on a page: `removed` strokes went, `added` strokes (new ids) took their place.
    func inkEdited(pageId: String, removed: [Stroke], added: [Stroke], canvasInSync: Bool) {
        if !removed.isEmpty { doc.removeItems(on: pageId, ids: Set(removed.map(\.id))) }
        for s in added { doc.addStroke(s) }
        let r = removed.map(PageItem.stroke), a = added.map(PageItem.stroke)
        if r.isEmpty && a.isEmpty { return }
        if r.isEmpty { record(.addItems(pageId: pageId, items: a), refreshPages: !canvasInSync) }
        else if a.isEmpty { record(.removeItems(pageId: pageId, items: r), refreshPages: !canvasInSync) }
        else { record(.edit(pageId: pageId, removed: r, added: a), refreshPages: !canvasInSync) }
    }

    /// Items were added to a page (a placed shape, tape, image, text, a paste).
    func add(_ items: [PageItem], to pageId: String) {
        guard !items.isEmpty else { return }
        doc.addItems(items)
        record(.addItems(pageId: pageId, items: items))
    }

    func remove(ids: Set<String>, from pageId: String) {
        let removed = doc.removeItems(on: pageId, ids: ids)
        guard !removed.isEmpty else { return }
        record(.removeItems(pageId: pageId, items: removed))
    }

    /// Items changed in place (move, resize, recolour, text edit). `before` and `after` pair up by id.
    func replace(before: [PageItem], after: [PageItem], on pageId: String) {
        guard before != after else { return }
        doc.replaceItems(on: pageId, with: after)
        record(.replaceItems(pageId: pageId, before: before, after: after))
    }

    /// Some items went and others took their place (a snap, a split erase), as one step.
    func edit(removed: [PageItem], added: [PageItem], on pageId: String) {
        if !removed.isEmpty { doc.removeItems(on: pageId, ids: Set(removed.map(\.id))) }
        doc.addItems(added)
        if removed.isEmpty && added.isEmpty { return }
        record(.edit(pageId: pageId, removed: removed, added: added))
    }

    // MARK: Undo / redo

    func undo() {
        if column?.cancelPendingInput() == true { return }
        guard let op = history.popUndo() else { return }
        doc.revert(op)
        afterEdit(op.pageIds, structure: op.changesStructure)
        column?.clearSelectionIfStale()
    }

    func redo() {
        guard let op = history.popRedo() else { return }
        doc.apply(op)
        afterEdit(op.pageIds, structure: op.changesStructure)
        column?.clearSelectionIfStale()
    }

    // MARK: Pages

    func page(_ id: String) -> Page? { doc.page(id) }

    /// The page nearest the middle of the screen (the first page before anything has scrolled).
    var currentPage: Page? { currentPageId.flatMap { doc.page($0) } ?? doc.pages.first }

    func setPaper(_ pageId: String, paper: Paper, allPages: Bool) {
        doc.setPaper(pageId, paper: paper, allPages: allPages)
        contentRevision += 1
        column?.paperChanged()
    }

    func deletePage(_ id: String) {
        guard let d = doc.deletedPage(id) else { return }
        doc.deletePage(id)
        record(.deletePage(page: d.page, strokes: d.strokes, elements: d.elements))
    }

    func deletePages(_ ids: [String]) {
        let items = ids.compactMap { doc.deletedPage($0) }.sorted { $0.page.index < $1.page.index }
        guard !items.isEmpty else { return }
        doc.deletePages(items.map { $0.page.id })
        record(.deletePages(items: items))
    }

    func duplicatePage(_ id: String) {
        doc.duplicatePage(id)
        afterEdit([id], structure: true)
    }

    /// Reorders by id; one undo step.
    func reorder(to after: [String]) {
        let before = doc.pages.map(\.id)
        guard doc.reorderPages(after) else { return }
        record(.reorderPages(before: before, after: doc.pages.map(\.id)))
    }

    func goToPage(_ id: String) {
        column?.scrollToPage(id)
        currentPageId = id
    }

    /// Appended PDF pages come with their own asset; the column picks up the new pages.
    func pagesAdded() {
        afterEdit([], structure: true)
    }

    // MARK: Clipboard

    var hasSelection: Bool { (selection?.count ?? 0) > 0 }

    func copy(_ items: [PageItem], from pageId: String) {
        guard !items.isEmpty else { return }
        clipboard = items
        clipboardPageId = pageId
    }

    /// Items for pasting onto `pageId`: re-keyed, and nudged when it is the page they were copied from.
    /// `at` centres the combined box on that point instead.
    func pasteItems(onto pageId: String, at: Pt? = nil) -> [PageItem] {
        guard !clipboard.isEmpty else { return [] }
        var dx = 0.0, dy = 0.0
        if let at, let box = Geometry.unionRects(clipboard.map(Geometry.itemBounds)) {
            dx = at.x - (box.x + box.w / 2)
            dy = at.y - (box.y + box.h / 2)
        } else if pageId == clipboardPageId {
            dx = Self.pasteOffset; dy = Self.pasteOffset
        }
        let now = LibraryStore.now()
        let items = Self.clone(clipboard, pageId: pageId, notebookId: doc.id, dx: dx, dy: dy, startingAt: now)
        // pasting again lands the next copy one step further along
        if at == nil && dx != 0 { clipboard = items }
        return items
    }

    /// Fresh ids and sequential timestamps (so z-order survives), moved by (dx, dy).
    static func clone(_ items: [PageItem], pageId: String, notebookId: String, dx: Double, dy: Double, startingAt now: Double) -> [PageItem] {
        let moved = Geometry.translateItems(items, dx: dx, dy: dy)
        return moved.enumerated().map { i, item in
            switch item {
            case .stroke(var s):
                s.id = UUID().uuidString; s.pageId = pageId; s.notebookId = notebookId; s.createdAt = now + Double(i)
                return .stroke(s)
            case .element(var e):
                e.id = UUID().uuidString; e.pageId = pageId; e.notebookId = notebookId; e.createdAt = now + Double(i)
                return .element(e)
            }
        }
    }
}
