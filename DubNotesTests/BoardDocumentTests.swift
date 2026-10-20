import XCTest
@testable import DubNotes

/// A board's items live in storage chunks keyed by the bounding-box origin; the document answers for the whole
/// board through one surface id. These cover the routing, the undo round trip and the extent.
final class BoardDocumentTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private let nb = "nb1"

    private func board() -> NotebookDocument {
        let notebook = Notebook(id: nb, name: "Board", kind: .board, createdAt: 1000, updatedAt: 1000)
        let origin = Page(id: "\(nb):0,0", notebookId: nb, index: 0, paper: .default, col: 0, row: 0,
                          createdAt: 1000, updatedAt: 1000)
        return NotebookDocument(notebook: notebook, pages: [origin])
    }

    /// A stroke filed under the surface, running (x, y) → (x + 100, y).
    private func stroke(_ id: String, _ doc: NotebookDocument, x: Double, y: Double, at: Double = 1) -> Stroke {
        Make.stroke(id, page: doc.boardSurfaceId, nb: nb, points: [(x, y), (x + 100, y)], size: 2, at: at)
    }

    // MARK: Routing

    func testItemsAreFiledByTheirBoundingBoxOrigin() throws {
        let doc = board()
        doc.addStroke(stroke("a", doc, x: 100, y: 100))
        doc.addStroke(stroke("b", doc, x: 3000, y: -500))
        doc.addElement(Make.text("t", page: doc.boardSurfaceId, nb: nb, x: -5000, y: 5000))
        XCTAssertEqual(doc.strokes(of: "nb1:0,0").map(\.id), ["a"])
        XCTAssertEqual(doc.strokes(of: "nb1:1,-1").map(\.id), ["b"])
        XCTAssertEqual(doc.elements(of: "nb1:-3,2").map(\.id), ["t"])
        XCTAssertEqual(try item(doc.strokes(of: "nb1:1,-1"), 0).pageId, "nb1:1,-1")
    }

    func testChunksAreCreatedOnDemandWithTheBoardPaper() throws {
        let grid = Paper(template: .grid, spacing: .wide, color: .cream)
        let doc = board()
        doc.setPaper(doc.boardSurfaceId, paper: grid, allPages: true)
        XCTAssertEqual(doc.pages.count, 1)
        doc.addStroke(stroke("far", doc, x: 9000, y: 9000))
        let chunk = try XCTUnwrap(doc.page("nb1:4,4"))
        XCTAssertEqual(doc.pages.count, 2)
        XCTAssertEqual(chunk.paper, grid)
        XCTAssertEqual(chunk.index, 0)
        XCTAssertEqual(chunk.col, 4)
        XCTAssertEqual(chunk.row, 4)
        XCTAssertTrue(doc.dirtyPages.contains("nb1:4,4"))
        XCTAssertTrue(doc.manifestDirty)
        XCTAssertEqual(doc.pages.map(\.index), [0, 0])
    }

    func testReadingTheSurfaceCombinesEveryChunkInZOrder() {
        let doc = board()
        doc.addStroke(stroke("late", doc, x: 5000, y: 0, at: 30))
        doc.addElement(Make.text("mid", page: doc.boardSurfaceId, nb: nb, x: -3000, y: 0, at: 20))
        doc.addStroke(stroke("early", doc, x: 100, y: 100, at: 10))
        XCTAssertEqual(doc.items(of: doc.boardSurfaceId).map(\.id), ["early", "mid", "late"])
        XCTAssertEqual(doc.strokes(of: doc.boardSurfaceId).map(\.id), ["early", "late"])
        XCTAssertEqual(doc.elements(of: doc.boardSurfaceId).map(\.id), ["mid"])
        XCTAssertEqual(doc.item("mid", on: doc.boardSurfaceId)?.id, "mid")
        XCTAssertEqual(doc.itemCount, 3)
    }

    func testAnItemWithARealChunkIdKeepsIt() {
        let doc = board()
        let s = Make.stroke("kept", page: "nb1:2,2", nb: nb, points: [(100, 100), (200, 100)])
        doc.addStroke(s) // sits in cell 0,0 by its bounds, but it says it was stored in 2,2
        XCTAssertEqual(doc.strokes(of: "nb1:2,2").map(\.id), ["kept"])
        XCTAssertTrue(doc.strokes(of: "nb1:0,0").isEmpty)
        XCTAssertEqual(doc.strokes(of: doc.boardSurfaceId).map(\.id), ["kept"])
    }

    func testAChunkIdFromAnotherNotebookIsNotTrusted() {
        let doc = board()
        doc.addStroke(Make.stroke("x", page: "other:3,3", nb: nb, points: [(100, 100), (200, 100)]))
        XCTAssertEqual(doc.strokes(of: "nb1:0,0").map(\.id), ["x"])
        XCTAssertNil(doc.page("other:3,3"))
    }

    func testAStrokeCrossingAChunkEdgeStaysWholeInOneChunk() throws {
        let doc = board()
        // starts in cell 0 and runs across x = 2048
        let s = Make.stroke("cross", page: doc.boardSurfaceId, nb: nb, points: [(2000, 100), (2100, 100), (2200, 140)], size: 2)
        doc.addStroke(s)
        XCTAssertEqual(doc.strokes(of: "nb1:0,0").map(\.id), ["cross"])
        XCTAssertNil(doc.page("nb1:1,0"), "the far side of the edge gets no chunk of its own")
        let stored = try item(doc.strokes(of: doc.boardSurfaceId), 0)
        XCTAssertEqual(stored.points.count, 3)
        // the chunk does not bound the item: its bounds run past the edge
        let b = Geometry.itemBounds(.stroke(stored))
        XCTAssertLessThan(b.x, 2048)
        XCTAssertGreaterThan(b.x + b.w, 2048)
        XCTAssertNotNil(doc.item("cross", on: doc.boardSurfaceId))
    }

    // MARK: Remove, replace, undo

    func testRemoveFindsTheItemInWhicheverChunkHoldsIt() throws {
        let doc = board()
        doc.addStroke(stroke("a", doc, x: 100, y: 100))
        doc.addStroke(stroke("b", doc, x: 6000, y: 100))
        let removed = doc.removeItems(on: doc.boardSurfaceId, ids: ["b", "missing"])
        XCTAssertEqual(removed.map(\.id), ["b"])
        XCTAssertEqual(try item(removed, 0).pageId, "nb1:2,0")
        XCTAssertEqual(doc.strokes(of: doc.boardSurfaceId).map(\.id), ["a"])
        XCTAssertTrue(doc.removeItems(on: doc.boardSurfaceId, ids: ["b"]).isEmpty)
        XCTAssertTrue(doc.dirtyPages.contains("nb1:2,0"))
    }

    func testReplaceKeepsTheOriginalChunkWhenAnItemMoves() throws {
        let doc = board()
        doc.addStroke(stroke("a", doc, x: 100, y: 100))
        let before = try item(doc.items(of: doc.boardSurfaceId), 0)
        let after = Geometry.translateItems([before], dx: 9000, dy: 9000)
        doc.replaceItems(on: doc.boardSurfaceId, with: after)
        XCTAssertEqual(doc.strokes(of: "nb1:0,0").map(\.id), ["a"], "a moved item stays in its original chunk")
        XCTAssertNil(doc.page("nb1:4,4"))
        XCTAssertEqual(try item(doc.strokes(of: doc.boardSurfaceId), 0).points.first?.x, 9100)
    }

    func testReplaceRestoresTheChunkIdEvenIfTheReplacementCarriesTheSurfaceId() throws {
        let doc = board()
        doc.addStroke(stroke("a", doc, x: 6000, y: 100))
        var edited = stroke("a", doc, x: 6000, y: 100)
        edited.color = "#ff0000"
        doc.replaceItems(on: doc.boardSurfaceId, with: [.stroke(edited)])
        let stored = try item(doc.strokes(of: "nb1:2,0"), 0)
        XCTAssertEqual(stored.pageId, "nb1:2,0")
        XCTAssertEqual(stored.color, "#ff0000")
    }

    func testRemoveReplaceAndUndoRoundTrip() throws {
        let doc = board()
        doc.addStroke(stroke("far", doc, x: 6000, y: 100, at: 1))
        let original = try item(doc.items(of: doc.boardSurfaceId), 0)
        XCTAssertEqual(original.pageId, "nb1:2,0")

        // move it (a replace), then delete it, as two undo steps
        let moved = Geometry.translateItems([original], dx: -7000, dy: 0)
        let move = EditOp.replaceItems(pageId: doc.boardSurfaceId, before: [original], after: moved)
        doc.apply(move)
        XCTAssertEqual(doc.strokes(of: "nb1:2,0").map(\.id), ["far"])
        XCTAssertEqual(try item(doc.strokes(of: doc.boardSurfaceId), 0).points.first?.x, -1000)

        let removed = doc.removeItems(on: doc.boardSurfaceId, ids: ["far"])
        let delete = EditOp.removeItems(pageId: doc.boardSurfaceId, items: removed)
        XCTAssertTrue(doc.strokes(of: doc.boardSurfaceId).isEmpty)

        doc.revert(delete) // undo the delete: the item hands back the chunk id it was stored under
        XCTAssertEqual(doc.strokes(of: "nb1:2,0").map(\.id), ["far"])
        XCTAssertNil(doc.page("nb1:-1,0"), "undo must not re-file it by its moved position")
        XCTAssertEqual(try item(doc.strokes(of: doc.boardSurfaceId), 0).points.first?.x, -1000)

        doc.apply(delete) // redo
        XCTAssertTrue(doc.strokes(of: doc.boardSurfaceId).isEmpty)
        doc.revert(delete)
        doc.revert(move) // undo the move
        XCTAssertEqual(doc.strokes(of: "nb1:2,0").map(\.id), ["far"])
        XCTAssertEqual(try item(doc.strokes(of: doc.boardSurfaceId), 0).points.first?.x, 6000)
    }

    func testUndoingAndRedoingAnAddUsesTheSameChunk() {
        let doc = board()
        let added = [PageItem.stroke(stroke("n", doc, x: 6000, y: 6000))] // filed under the surface id
        let op = EditOp.addItems(pageId: doc.boardSurfaceId, items: added)
        doc.apply(op)
        XCTAssertEqual(doc.strokes(of: "nb1:2,2").map(\.id), ["n"])
        doc.revert(op)
        XCTAssertTrue(doc.strokes(of: doc.boardSurfaceId).isEmpty)
        doc.apply(op)
        XCTAssertEqual(doc.strokes(of: "nb1:2,2").map(\.id), ["n"])
        XCTAssertEqual(doc.strokes(of: doc.boardSurfaceId).count, 1)
    }

    // MARK: Extent

    func testAnEmptyBoardIsTheOriginChunkPlusPadding() {
        let e = board().boardExtent
        XCTAssertEqual(e, PageRect(x: -4096, y: -4096, w: 10240, h: 10240))
    }

    func testTheExtentGrowsWithTheContentOnEverySideAndSnapsToTheGrid() {
        let doc = board()
        doc.addStroke(stroke("east", doc, x: 10000, y: 0))
        var e = doc.boardExtent
        XCTAssertEqual(e.x + e.w, 14336) // 10101 + 4096 = 14197, up to the next multiple of 2048
        XCTAssertEqual(e.x, -4096)

        doc.addStroke(stroke("west", doc, x: -9000, y: 0))
        e = doc.boardExtent
        XCTAssertEqual(e.x, -14336) // -9001 - 4096 = -13097, down to the next multiple of 2048
        doc.addStroke(Make.stroke("south", page: doc.boardSurfaceId, nb: nb, points: [(0, 12000), (0, 12100)], size: 2))
        XCTAssertEqual(doc.boardExtent.y + doc.boardExtent.h, 16384) // 12101 + 4096 = 16197
        for v in [doc.boardExtent.x, doc.boardExtent.y, doc.boardExtent.w, doc.boardExtent.h] {
            XCTAssertEqual(v.truncatingRemainder(dividingBy: 2048), 0)
        }
    }

    func testTheExtentFollowsEditsAndTheSurfacePageDescribesIt() throws {
        let doc = board()
        doc.addStroke(stroke("far", doc, x: 10000, y: 0))
        let grown = doc.boardExtent
        let page = try XCTUnwrap(doc.page(doc.boardSurfaceId))
        XCTAssertEqual(page.originX, grown.x)
        XCTAssertEqual(page.originY, grown.y)
        XCTAssertEqual(page.pageWidth, grown.w)
        XCTAssertEqual(page.pageHeight, grown.h)
        doc.removeItems(on: doc.boardSurfaceId, ids: ["far"])
        XCTAssertEqual(doc.boardExtent, PageRect(x: -4096, y: -4096, w: 10240, h: 10240))
        // replacing (a move) regrows it too
        doc.addStroke(stroke("s", doc, x: 100, y: 100))
        let s = try item(doc.items(of: doc.boardSurfaceId), 0)
        doc.replaceItems(on: doc.boardSurfaceId, with: Geometry.translateItems([s], dx: 20000, dy: 0))
        XCTAssertGreaterThan(doc.boardExtent.x + doc.boardExtent.w, 20000)
    }

    // MARK: Paper

    func testPaperAlwaysAppliesToEveryChunk() throws {
        let doc = board()
        doc.addStroke(stroke("a", doc, x: 6000, y: 100))
        doc.addStroke(stroke("b", doc, x: -6000, y: -6000))
        XCTAssertEqual(doc.pages.count, 3)
        let dark = Paper(template: .dot, spacing: .narrow, color: .dark)
        doc.setPaper(doc.boardSurfaceId, paper: dark, allPages: false) // the scope is ignored on a board
        XCTAssertEqual(doc.pages.map(\.paper), [dark, dark, dark])
        XCTAssertEqual(doc.boardPaper, dark)
        XCTAssertEqual(try XCTUnwrap(doc.page(doc.boardSurfaceId)).paper, dark)
        // a chunk made afterwards inherits it
        doc.addStroke(stroke("c", doc, x: 20000, y: 20000))
        XCTAssertEqual(try XCTUnwrap(doc.page("nb1:9,9")).paper, dark)
        // naming a single chunk does not narrow it either
        let light = Paper(template: .ruled, spacing: .medium, color: .white)
        doc.setPaper("nb1:2,0", paper: light, allPages: false)
        XCTAssertTrue(doc.pages.allSatisfy { $0.paper == light })
        XCTAssertEqual(doc.boardPaper, light)
    }

    func testPaperIsReadFromTheOriginChunk() throws {
        let cream = Paper(template: .grid, spacing: .medium, color: .cream)
        let notebook = Notebook(id: nb, name: "Board", kind: .board, createdAt: 1, updatedAt: 1)
        let pages = [
            Page(id: "nb1:3,3", notebookId: nb, index: 0, paper: .default, col: 3, row: 3, createdAt: 1, updatedAt: 1),
            Page(id: "nb1:0,0", notebookId: nb, index: 0, paper: cream, col: 0, row: 0, createdAt: 1, updatedAt: 1),
        ]
        let doc = NotebookDocument(notebook: notebook, pages: pages)
        XCTAssertEqual(doc.boardPaper, cream)
    }

    // MARK: Pages are untouched

    func testAPagedNotebookHasNoSurface() {
        let doc = Make.document(pages: 2)
        XCTAssertFalse(doc.isBoard)
        XCTAssertNil(doc.page("nb1:board"))
        XCTAssertFalse(doc.isBoardSurface("nb1:board"))
        doc.addStroke(Make.stroke("z", page: "p0", points: [(6000, 6000), (6100, 6000)]))
        XCTAssertEqual(doc.pages.map(\.id), ["p0", "p1"], "a page never grows chunks")
        XCTAssertEqual(doc.strokes(of: "p0").count, 2)
    }

    func testTheOriginIsNotSaved() throws {
        var page = Make.page("p")
        page.originX = 128
        page.originY = -64
        let data = try JSONEncoder().encode(page)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("origin"))
        let back = try JSONDecoder().decode(Page.self, from: data)
        XCTAssertEqual(back.originX, 0)
        XCTAssertEqual(back.originY, 0)
        XCTAssertEqual(back.id, "p")
    }

    func testChunkIdParsing() {
        let doc = board()
        XCTAssertEqual(doc.chunkCell(of: "nb1:-3,12")?.col, -3)
        XCTAssertEqual(doc.chunkCell(of: "nb1:-3,12")?.row, 12)
        XCTAssertNil(doc.chunkCell(of: "nb1:board"))
        XCTAssertNil(doc.chunkCell(of: "nb1:1,2,3"))
        XCTAssertNil(doc.chunkCell(of: "nb2:1,2"))
        XCTAssertNil(doc.chunkCell(of: "nb1:a,b"))
    }
}
