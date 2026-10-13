import XCTest
@testable import DubNotes

final class BackupImporterTests: ScratchTestCase {
    private func copies(_ ids: [String]? = nil) throws -> (original: Backup, copy: Backup, warnings: [String]) {
        let original = try BackupCodec.decode(fixtureData()).backup
        var n = 0
        let r = BackupImporter.makeCopies(of: original, newId: {
            n += 1
            return ids.map { $0[(n - 1) % $0.count] } ?? "new-\(n)"
        })
        return (original, r.backup, r.warnings)
    }

    func testEveryRecordGetsAFreshUniqueId() throws {
        let (original, copy, _) = try copies()
        let oldIds = Set(original.notebooks.map(\.id) + original.pages.map(\.id) + original.strokes.map(\.id)
                         + original.elements.map(\.id) + original.folders.map(\.id) + original.dividers.map(\.id)
                         + original.assets.map(\.id))
        let newIds = copy.notebooks.map(\.id) + copy.folders.map(\.id) + copy.dividers.map(\.id) + copy.assets.map(\.id)
            + copy.strokes.map(\.id) + copy.elements.map(\.id)
        XCTAssertTrue(oldIds.isDisjoint(with: newIds))
        XCTAssertEqual(Set(newIds).count, newIds.count)
        XCTAssertTrue(oldIds.isDisjoint(with: copy.pages.filter { $0.col == nil }.map(\.id)))
    }

    func testCountsAndContentAreKept() throws {
        let (original, copy, warnings) = try copies()
        XCTAssertEqual(copy.notebooks.count, original.notebooks.count)
        XCTAssertEqual(copy.pages.count, original.pages.count)
        XCTAssertEqual(copy.strokes.count, original.strokes.count)
        XCTAssertEqual(copy.elements.count, original.elements.count)
        XCTAssertEqual(copy.folders.count, original.folders.count)
        XCTAssertEqual(copy.assets.map(\.data), original.assets.map(\.data))
        XCTAssertEqual(copy.strokes.map(\.points), original.strokes.map(\.points))
        XCTAssertEqual(copy.notebooks.map(\.name), original.notebooks.map(\.name))
        XCTAssertTrue(warnings.isEmpty)
    }

    func testFoldersKeepTheirTreeAndNotebooksKeepTheirFolder() throws {
        let (_, copy, _) = try copies()
        let science = try XCTUnwrap(copy.folders.first { $0.name == "Science" })
        let school = try XCTUnwrap(copy.folders.first { $0.name == "School" })
        XCTAssertEqual(science.parentId, school.id)
        XCTAssertNil(school.parentId)
        let physics = try XCTUnwrap(copy.notebooks.first { $0.name == "Physics" })
        XCTAssertEqual(physics.folderId, science.id)
        XCTAssertNil(try XCTUnwrap(copy.notebooks.first { $0.name == "Mind map" }).folderId)
    }

    func testPagesStrokesAndElementsFollowTheirNotebookAndPage() throws {
        let (_, copy, _) = try copies()
        let physics = try XCTUnwrap(copy.notebooks.first { $0.name == "Physics" })
        let pages = copy.pages.filter { $0.notebookId == physics.id }
        XCTAssertEqual(pages.count, 3)
        let pageIds = Set(pages.map(\.id))
        for s in copy.strokes { XCTAssertTrue(pageIds.contains(s.pageId)); XCTAssertEqual(s.notebookId, physics.id) }
        for e in copy.elements.filter({ $0.notebookId == physics.id }) { XCTAssertTrue(pageIds.contains(e.pageId)) }
    }

    func testAPdfBackgroundPointsAtTheCopiedAsset() throws {
        let (original, copy, _) = try copies()
        let asset = try XCTUnwrap(copy.assets.first)
        XCTAssertNotEqual(asset.id, try item(original.assets, 0).id)
        let physics = try XCTUnwrap(copy.notebooks.first { $0.name == "Physics" })
        XCTAssertEqual(asset.notebookId, physics.id)
        let pdfPage = try XCTUnwrap(copy.pages.first { if case .pdf? = $0.background { return true } else { return false } })
        XCTAssertEqual(pdfPage.background, .pdf(assetId: asset.id, page: 2))
        // the legacy image background is data, not a reference, so it is untouched
        XCTAssertTrue(copy.pages.contains { if case .image? = $0.background { return true } else { return false } })
    }

    func testBoardChunkIdsStayAddressedByTheirCell() throws {
        let (_, copy, _) = try copies()
        let board = try XCTUnwrap(copy.notebooks.first { $0.isBoard })
        let chunk = try XCTUnwrap(copy.pages.first { $0.notebookId == board.id })
        XCTAssertEqual(chunk.id, "\(board.id):0,0")
        XCTAssertTrue(copy.elements.filter { $0.notebookId == board.id }.allSatisfy { $0.pageId == chunk.id })
    }

    func testBubbleMembersAndConnectorAnchorsFollowTheCopies() throws {
        let (original, copy, _) = try copies()
        let strokeCopy = try XCTUnwrap(copy.strokes.first { $0.tool == .pen })
        var bubbles: [PageElement] = []
        var connector: PageElement.Connector?
        for e in copy.elements {
            switch e.content {
            case .bubble: bubbles.append(e)
            case .connector(let c): connector = c
            default: break
            }
        }
        XCTAssertEqual(bubbles.count, 2)
        let first = try XCTUnwrap(bubbles.first { if case .bubble(let b) = $0.content { return !b.members.isEmpty } else { return false } })
        guard case .bubble(let b) = first.content else { return XCTFail() }
        XCTAssertEqual(b.members, [strokeCopy.id], "the stroke follows its copy; the member that was never in the backup is dropped")
        let c = try XCTUnwrap(connector)
        XCTAssertTrue(bubbles.map(\.id).contains(c.a.bubbleId))
        XCTAssertTrue(bubbles.map(\.id).contains(c.b.bubbleId))
        XCTAssertFalse(original.elements.map(\.id).contains(c.a.bubbleId))
    }

    func testAConnectorWithoutBothBubblesIsDropped() {
        var b = Backup()
        b.notebooks = [Make.notebook("n")]
        b.pages = [Make.page("p", nb: "n")]
        b.elements = [PageElement(id: "c", pageId: "p", notebookId: "n", x: 0, y: 0, w: 1, h: 1, createdAt: 1,
                                  content: .connector(PageElement.Connector(a: .init(bubbleId: "x", node: .n), b: .init(bubbleId: "y", node: .s),
                                                                            color: "auto", size: 2, ax: 0, ay: 0, bx: 1, by: 1)))]
        let r = BackupImporter.makeCopies(of: b)
        XCTAssertTrue(r.backup.elements.isEmpty)
    }

    func testOrphansAreSkippedWithAWarning() {
        var b = Backup()
        b.notebooks = [Make.notebook("n")]
        b.pages = [Make.page("p", nb: "n"), Make.page("lost", nb: "missing")]
        b.strokes = [Make.stroke("s1", page: "p", nb: "n"), Make.stroke("s2", page: "lost", nb: "missing")]
        b.assets = [Asset(id: "a", notebookId: "missing", name: "x.pdf", pages: 1, data: Data())]
        let r = BackupImporter.makeCopies(of: b)
        XCTAssertEqual(r.backup.pages.count, 1)
        XCTAssertEqual(r.backup.strokes.count, 1)
        XCTAssertTrue(r.backup.assets.isEmpty)
        XCTAssertEqual(r.warnings.count, 2)
    }

    func testAPdfPageWhoseAssetIsMissingLosesItsBackgroundWithAWarning() {
        var b = Backup()
        b.notebooks = [Make.notebook("n")]
        var page = Make.page("p", nb: "n")
        page.background = .pdf(assetId: "gone", page: 1)
        b.pages = [page]
        let r = BackupImporter.makeCopies(of: b)
        XCTAssertNil(try item(r.backup.pages, 0).background)
        XCTAssertEqual(r.warnings.count, 1)
    }

    func testCopiesDecodeBackAfterEncoding() throws {
        let (_, copy, _) = try copies()
        let again = try BackupCodec.decode(BackupCodec.encode(copy)).backup
        XCTAssertEqual(again, copy)
    }
}
