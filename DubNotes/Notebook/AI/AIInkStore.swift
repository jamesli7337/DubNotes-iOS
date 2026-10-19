import PencilKit

/// The ink drawn in AI mode, in memory only: one drawing per page, plus one notebook-wide undo / redo stack of
/// per-page snapshots. Nothing here reaches the document, the main undo history, the stroke reconcile path or disk.
final class AIInkStore {
    private struct Step {
        let pageId: String
        let before: PKDrawing
        let after: PKDrawing
    }

    private static let maxSteps = 100

    private var drawings: [String: PKDrawing] = [:]
    private var undoSteps: [Step] = []
    private var redoSteps: [Step] = []

    var canUndo: Bool { !undoSteps.isEmpty }
    var canRedo: Bool { !redoSteps.isEmpty }

    func drawing(for pageId: String) -> PKDrawing {
        drawings[pageId] ?? PKDrawing()
    }

    /// The user drew or erased on a page's AI canvas. A drawing equal to the stored one is an echo and is ignored.
    func commit(pageId: String, drawing: PKDrawing) {
        let before = self.drawing(for: pageId)
        guard before.dataRepresentation() != drawing.dataRepresentation() else { return }
        undoSteps.append(Step(pageId: pageId, before: before, after: drawing))
        if undoSteps.count > Self.maxSteps { undoSteps.removeFirst() }
        redoSteps.removeAll()
        drawings[pageId] = drawing
    }

    /// Returns the page whose drawing changed, so its canvas can reload.
    func undo() -> String? {
        guard let step = undoSteps.popLast() else { return nil }
        drawings[step.pageId] = step.before
        redoSteps.append(step)
        return step.pageId
    }

    func redo() -> String? {
        guard let step = redoSteps.popLast() else { return nil }
        drawings[step.pageId] = step.after
        undoSteps.append(step)
        return step.pageId
    }

    /// Drops every drawing and both stacks; returns the pages that had ink so their canvases can reload.
    func clearAll() -> [String] {
        let ids = Array(drawings.keys)
        drawings = [:]
        undoSteps = []
        redoSteps = []
        return ids
    }
}
