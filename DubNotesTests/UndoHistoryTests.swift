import XCTest
@testable import DubNotes

final class UndoHistoryTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false // later lines index into results; stop at the first failure instead of trapping
    }

    func testPushClearsRedoAndPopsMoveBetweenStacks() {
        var h = UndoHistory()
        let a = EditOp.addItems(pageId: "p", items: [])
        let b = EditOp.removeItems(pageId: "p", items: [])
        h.push(a)
        h.push(b)
        XCTAssertTrue(h.canUndo)
        XCTAssertFalse(h.canRedo)
        XCTAssertEqual(h.popUndo(), b)
        XCTAssertTrue(h.canRedo)
        h.push(a) // a fresh edit forgets the undone one
        XCTAssertFalse(h.canRedo)
        XCTAssertEqual(h.popUndo(), a)
        XCTAssertEqual(h.popRedo(), a)
        XCTAssertNil(h.popRedo())
    }

    func testTheStackIsCapped() {
        var h = UndoHistory()
        for i in 0..<(UndoHistory.limit + 25) { h.push(.addItems(pageId: "p\(i)", items: [])) }
        XCTAssertEqual(h.undoStack.count, UndoHistory.limit)
        XCTAssertEqual(h.undoStack.first, .addItems(pageId: "p25", items: [])) // the oldest 25 fell off
    }

    func testAddAndUndoAndRedo() {
        let doc = Make.document(pages: 2)
        let s = PageItem.stroke(Make.stroke("new", page: "p1"))
        doc.addItems([s])
        let op = EditOp.addItems(pageId: "p1", items: [s])
        doc.revert(op)
        XCTAssertTrue(doc.strokes(of: "p1").isEmpty)
        doc.apply(op)
        XCTAssertEqual(doc.strokes(of: "p1").map(\.id), ["new"])
    }

    func testReplaceRoundTrip() throws {
        let doc = Make.document(pages: 2)
        let before = PageItem.element(Make.text("t", x: 0))
        let after = PageItem.element(Make.text("t", x: 50))
        doc.addItems([before])
        doc.replaceItems(on: "p1", with: [after])
        let op = EditOp.replaceItems(pageId: "p1", before: [before], after: [after])
        doc.revert(op)
        XCTAssertEqual(try item(doc.elements(of: "p1"), 0).x, 0)
        doc.apply(op)
        XCTAssertEqual(try item(doc.elements(of: "p1"), 0).x, 50)
    }

    func testEditSwapsRemovedAndAdded() throws {
        let doc = Make.document(pages: 2)
        let old = PageItem.stroke(try item(doc.strokes(of: "p0"), 0))
        let piece1 = PageItem.stroke(Make.stroke("a", page: "p0", points: [(0, 0), (3, 0)]))
        let piece2 = PageItem.stroke(Make.stroke("b", page: "p0", points: [(6, 0), (10, 0)]))
        let op = EditOp.edit(pageId: "p0", removed: [old], added: [piece1, piece2])
        doc.apply(op)
        XCTAssertEqual(Set(doc.strokes(of: "p0").map(\.id)), ["a", "b"])
        doc.revert(op)
        XCTAssertEqual(doc.strokes(of: "p0").map(\.id), ["s0"])
    }

    func testDeletePageComesBackWhereItWasWithItsContent() throws {
        let doc = Make.document(pages: 3)
        doc.addElement(Make.text("t", page: "p1"))
        let captured = try XCTUnwrap(doc.deletedPage("p1"))
        doc.deletePage("p1")
        let op = EditOp.deletePage(page: captured.page, strokes: captured.strokes, elements: captured.elements)
        XCTAssertEqual(doc.pages.map(\.id), ["p0", "p2"])
        doc.revert(op)
        XCTAssertEqual(doc.pages.map(\.id), ["p0", "p1", "p2"])
        XCTAssertEqual(doc.pages.map(\.index), [0, 1, 2])
        XCTAssertEqual(doc.items(of: "p1").count, 2)
        doc.apply(op)
        XCTAssertEqual(doc.pages.map(\.id), ["p0", "p2"])
    }

    func testDeletePagesRestoreInAscendingOrder() throws {
        let doc = Make.document(pages: 4)
        let items = ["p0", "p2"].compactMap { doc.deletedPage($0) }
        doc.deletePages(["p0", "p2"])
        let op = EditOp.deletePages(items: items)
        XCTAssertEqual(doc.pages.map(\.id), ["p1", "p3"])
        doc.revert(op)
        XCTAssertEqual(doc.pages.map(\.id), ["p0", "p1", "p2", "p3"])
        XCTAssertEqual(doc.strokes(of: "p0").count, 1)
        XCTAssertEqual(doc.strokes(of: "p2").count, 1)
    }

    func testReorderRoundTrip() {
        let doc = Make.document(pages: 3)
        let before = doc.pages.map(\.id)
        doc.reorderPages(["p2", "p1", "p0"])
        let op = EditOp.reorderPages(before: before, after: doc.pages.map(\.id))
        doc.revert(op)
        XCTAssertEqual(doc.pages.map(\.id), before)
        doc.apply(op)
        XCTAssertEqual(doc.pages.map(\.id), ["p2", "p1", "p0"])
    }

    func testWhichPagesAnOpTouchesAndWhetherItIsStructural() {
        XCTAssertEqual(EditOp.addItems(pageId: "x", items: []).pageIds, ["x"])
        XCTAssertEqual(EditOp.reorderPages(before: ["a", "b"], after: ["b", "a"]).pageIds, ["b", "a"])
        XCTAssertFalse(EditOp.edit(pageId: "x", removed: [], added: []).changesStructure)
        XCTAssertTrue(EditOp.reorderPages(before: [], after: []).changesStructure)
        XCTAssertTrue(EditOp.deletePages(items: []).changesStructure)
    }
}
