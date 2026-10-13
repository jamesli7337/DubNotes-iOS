import Foundation

/// One undoable user action. Page add (the automatic trailing blank) is never recorded.
enum EditOp: Equatable {
    case addItems(pageId: String, items: [PageItem])
    case removeItems(pageId: String, items: [PageItem])
    case replaceItems(pageId: String, before: [PageItem], after: [PageItem])
    /// Some items went away and others (with different ids) took their place: partial erase, shape snap.
    case edit(pageId: String, removed: [PageItem], added: [PageItem])
    case deletePage(page: Page, strokes: [Stroke], elements: [PageElement])
    /// Page manager multi-select delete; `items` in ascending original index.
    case deletePages(items: [DeletedPage])
    case reorderPages(before: [String], after: [String])

    struct DeletedPage: Equatable {
        var page: Page
        var strokes: [Stroke]
        var elements: [PageElement]
    }

    /// Every page whose content the op touches, so views can repaint just those.
    var pageIds: [String] {
        switch self {
        case .addItems(let p, _), .removeItems(let p, _), .replaceItems(let p, _, _), .edit(let p, _, _):
            return [p]
        case .deletePage(let page, _, _):
            return [page.id]
        case .deletePages(let items):
            return items.map { $0.page.id }
        case .reorderPages(_, let after):
            return after
        }
    }

    /// True when applying the op changes the page list rather than one page's content.
    var changesStructure: Bool {
        switch self {
        case .deletePage, .deletePages, .reorderPages: return true
        default: return false
        }
    }
}

extension NotebookDocument {
    /// Re-applies `op` going forward (redo / the original edit).
    func apply(_ op: EditOp) {
        switch op {
        case .addItems(_, let items):
            addItems(items)
        case .removeItems(let pageId, let items):
            removeItems(on: pageId, ids: Set(items.map(\.id)))
        case .replaceItems(let pageId, _, let after):
            replaceItems(on: pageId, with: after)
        case .edit(let pageId, let removed, let added):
            removeItems(on: pageId, ids: Set(removed.map(\.id)))
            addItems(added)
        case .deletePage(let page, _, _):
            deletePage(page.id)
        case .deletePages(let items):
            deletePages(items.map { $0.page.id })
        case .reorderPages(_, let after):
            reorderPages(after)
        }
    }

    /// Reverses `op` (undo).
    func revert(_ op: EditOp) {
        switch op {
        case .addItems(let pageId, let items):
            removeItems(on: pageId, ids: Set(items.map(\.id)))
        case .removeItems(_, let items):
            addItems(items)
        case .replaceItems(let pageId, let before, _):
            replaceItems(on: pageId, with: before)
        case .edit(let pageId, let removed, let added):
            removeItems(on: pageId, ids: Set(added.map(\.id)))
            addItems(removed)
        case .deletePage(let page, let strokes, let elements):
            restore(page: page, strokes: strokes, elements: elements)
        case .deletePages(let items):
            for it in items { restore(page: it.page, strokes: it.strokes, elements: it.elements) }
        case .reorderPages(let before, _):
            reorderPages(before)
        }
    }

    private func restore(page: Page, strokes: [Stroke], elements: [PageElement]) {
        insertPage(page, at: page.index)
        for s in strokes { addStroke(s) }
        for e in elements { addElement(e) }
    }

    /// Captures a page's content for an undoable delete.
    func deletedPage(_ id: String) -> EditOp.DeletedPage? {
        guard let p = page(id) else { return nil }
        return EditOp.DeletedPage(page: p, strokes: strokes(of: id), elements: elements(of: id))
    }
}

/// Per-notebook undo/redo stacks: one step per user action, capped at 200.
struct UndoHistory {
    static let limit = 200
    private(set) var undoStack: [EditOp] = []
    private(set) var redoStack: [EditOp] = []

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records a fresh edit; a new edit clears the redo stack.
    mutating func push(_ op: EditOp) {
        undoStack.append(op)
        if undoStack.count > Self.limit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    mutating func popUndo() -> EditOp? {
        guard let op = undoStack.popLast() else { return nil }
        redoStack.append(op)
        return op
    }

    mutating func popRedo() -> EditOp? {
        guard let op = redoStack.popLast() else { return nil }
        undoStack.append(op)
        return op
    }

    mutating func clear() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
