import XCTest
@testable import DubNotes

final class NotebookDocumentTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false // later lines index into results; stop at the first failure instead of trapping
    }

    // MARK: Trailing blank page

    func testTrailingBlankIsAddedWhenTheLastPageHasContent() {
        let doc = Make.document(pages: 2, fillLast: true)
        XCTAssertTrue(doc.enforceTrailingBlank())
        XCTAssertEqual(doc.pages.count, 3)
        XCTAssertTrue(doc.isBlank(doc.pages[2].id))
    }

    func testTrailingBlankIsNotDuplicated() {
        let doc = Make.document(pages: 3) // last page is blank already
        XCTAssertFalse(doc.enforceTrailingBlank())
        XCTAssertEqual(doc.pages.count, 3)
    }

    func testTrailingBlankIsNeverRemoved() {
        let doc = Make.document(pages: 3)
        doc.removeItems(on: "p1", ids: ["s1"]) // page 2 is now blank as well
        XCTAssertFalse(doc.enforceTrailingBlank())
        XCTAssertEqual(doc.pages.count, 3)
    }

    func testAnEmptyNotebookGetsAPage() {
        let doc = NotebookDocument(notebook: Make.notebook(), pages: [])
        XCTAssertTrue(doc.enforceTrailingBlank())
        XCTAssertEqual(doc.pages.count, 1)
        XCTAssertEqual(doc.pages[0].index, 0)
    }

    func testABackgroundMakesAPageNonBlank() {
        let doc = Make.document(pages: 2)
        XCTAssertTrue(doc.isBlank("p1"))
        doc.setBackground("p1", .pdf(assetId: "a", page: 1))
        XCTAssertFalse(doc.isBlank("p1"))
        XCTAssertTrue(doc.enforceTrailingBlank())
    }

    func testContentPagesAndLibraryCountIgnoreTheTrailingBlank() {
        let doc = Make.document(pages: 3)
        XCTAssertEqual(doc.contentPages.map(\.id), ["p0", "p1"])
        XCTAssertEqual(doc.contentPageCount, 2)
        let single = NotebookDocument(notebook: Make.notebook(), pages: [Make.page("only")])
        XCTAssertEqual(single.contentPageCount, 1)
        XCTAssertEqual(single.manifest().contentPageCount, 1)
    }

    // MARK: Insert, delete, renumber

    func testAddedPageCopiesThePaperOfThePageBeforeIt() {
        let doc = NotebookDocument(notebook: Make.notebook(), pages: [
            Make.page("a", index: 0, paper: Paper(template: .grid, spacing: .wide, color: .dark)),
            Make.page("b", index: 1),
        ])
        let inserted = doc.addPage(at: 1)
        XCTAssertEqual(inserted.paper, Paper(template: .grid, spacing: .wide, color: .dark))
        XCTAssertEqual(doc.pages.map(\.id), ["a", inserted.id, "b"])
        XCTAssertEqual(doc.pages.map(\.index), [0, 1, 2])
    }

    func testDeleteRenumbersAndDropsTheContent() {
        let doc = Make.document(pages: 3)
        doc.deletePage("p0")
        XCTAssertEqual(doc.pages.map(\.id), ["p1", "p2"])
        XCTAssertEqual(doc.pages.map(\.index), [0, 1])
        XCTAssertTrue(doc.strokes(of: "p0").isEmpty)
        XCTAssertTrue(doc.deletedPages.contains("p0"))
    }

    func testDeletingSeveralPagesAtOnce() {
        let doc = Make.document(pages: 4)
        doc.deletePages(["p0", "p2", "nope"])
        XCTAssertEqual(doc.pages.map(\.id), ["p1", "p3"])
        XCTAssertEqual(doc.pages.map(\.index), [0, 1])
    }

    func testReorderIgnoresUnknownIdsAndKeepsUnnamedPagesAfter() {
        let doc = Make.document(pages: 4)
        XCTAssertTrue(doc.reorderPages(["p2", "ghost", "p0"]))
        XCTAssertEqual(doc.pages.map(\.id), ["p2", "p0", "p1", "p3"])
        XCTAssertEqual(doc.pages.map(\.index), [0, 1, 2, 3])
        XCTAssertFalse(doc.reorderPages(["p2", "p0", "p1", "p3"])) // already in that order
        XCTAssertFalse(doc.reorderPages(["ghost"]))
    }

    func testMovePageToAnIndex() {
        let doc = Make.document(pages: 4)
        XCTAssertTrue(doc.movePage("p0", to: 2))
        XCTAssertEqual(doc.pages.map(\.id), ["p1", "p2", "p0", "p3"])
        XCTAssertFalse(doc.movePage("p0", to: 2))
        XCTAssertTrue(doc.movePage("p3", to: -5)) // clamped to the start
        XCTAssertEqual(doc.pages.first?.id, "p3")
    }

    // MARK: Duplicate

    func testDuplicateKeepsPaperBackgroundSizeAndContentUnderNewIds() throws {
        let doc = Make.document(pages: 2)
        doc.setPageSize("p0", w: 612, h: 792)
        doc.setBackground("p0", .pdf(assetId: "asset", page: 3))
        doc.addElement(Make.text("t0", page: "p0", at: 5))
        let copy = try XCTUnwrap(doc.duplicatePage("p0"))
        XCTAssertEqual(copy.index, 1)
        XCTAssertEqual(copy.w, 612)
        XCTAssertEqual(copy.background, .pdf(assetId: "asset", page: 3))
        XCTAssertEqual(doc.pages.map(\.index), [0, 1, 2])
        let items = doc.items(of: copy.id)
        XCTAssertEqual(items.count, 2)
        let originalIds = Set(doc.items(of: "p0").map(\.id))
        XCTAssertTrue(items.allSatisfy { !originalIds.contains($0.id) && $0.pageId == copy.id })
        // z-order survives: the stroke stays under the text box
        XCTAssertTrue(items[0].isStroke)
        XCTAssertLessThan(items[0].createdAt, items[1].createdAt)
    }

    // MARK: Paper

    func testPaperScope() {
        let doc = Make.document(pages: 3)
        let grid = Paper(template: .grid, spacing: .narrow, color: .cream)
        doc.setPaper("p1", paper: grid, allPages: false)
        XCTAssertEqual(doc.pages.map(\.paper), [.default, grid, .default])
        doc.setPaper("p1", paper: grid, allPages: true)
        XCTAssertEqual(doc.pages.map(\.paper), [grid, grid, grid])
    }

    // MARK: Items

    func testItemsInterleaveByCreationTime() {
        let doc = NotebookDocument(notebook: Make.notebook(), pages: [Make.page("p1")])
        doc.addStroke(Make.stroke("s2", at: 30))
        doc.addElement(Make.text("t1", at: 20))
        doc.addStroke(Make.stroke("s1", at: 10))
        XCTAssertEqual(doc.items(of: "p1").map(\.id), ["s1", "t1", "s2"])
    }

    func testReplaceKeepsTheSlotAndIgnoresUnknownIds() {
        let doc = NotebookDocument(notebook: Make.notebook(), pages: [Make.page("p1")])
        doc.addElement(Make.text("t1", x: 0))
        doc.replaceItems(on: "p1", with: [.element(Make.text("t1", x: 99)), .element(Make.text("zzz"))])
        XCTAssertEqual(doc.elements(of: "p1").count, 1)
        XCTAssertEqual(doc.elements(of: "p1")[0].x, 99)
    }

    func testRemoveReturnsWhatWasRemoved() {
        let doc = Make.document(pages: 2)
        let removed = doc.removeItems(on: "p0", ids: ["s0", "missing"])
        XCTAssertEqual(removed.map(\.id), ["s0"])
        XCTAssertTrue(doc.removeItems(on: "p0", ids: ["s0"]).isEmpty)
    }

    func testItemCountAndBoardManifest() {
        let doc = Make.document(pages: 3)
        doc.addElement(Make.tape("tp", page: "p0"))
        XCTAssertEqual(doc.itemCount, 3)
        let m = doc.manifest()
        XCTAssertEqual(m.itemCount, 3)
        XCTAssertTrue(m.lastPageBlank)
        XCTAssertEqual(m.contentPageCount, 2)
    }

    // MARK: Dirty tracking

    func testDirtyTrackingNamesOnlyWhatChanged() {
        let doc = Make.document(pages: 3)
        doc.clearDirty()
        doc.addStroke(Make.stroke("new", page: "p1"))
        XCTAssertEqual(doc.dirtyPages, ["p1"])
        XCTAssertTrue(doc.manifestDirty)
        doc.clearDirty()
        XCTAssertTrue(doc.dirtyPages.isEmpty)
        XCTAssertFalse(doc.manifestDirty)
    }

    func testChangeCallbackFires() {
        let doc = Make.document(pages: 2)
        var calls = 0
        doc.onChange = { calls += 1 }
        doc.addStroke(Make.stroke("x"))
        doc.rename("Renamed")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(doc.notebook.name, "Renamed")
        doc.rename("   ")
        XCTAssertEqual(doc.notebook.name, "Renamed") // blank names are ignored
    }

    func testDeletedThenReinsertedPageIsNotDeleted() {
        let doc = Make.document(pages: 2)
        let page = doc.page("p0")!
        doc.deletePage("p0")
        XCTAssertTrue(doc.deletedPages.contains("p0"))
        doc.insertPage(page, at: 0)
        XCTAssertFalse(doc.deletedPages.contains("p0"))
        XCTAssertTrue(doc.dirtyPages.contains("p0"))
    }
}
