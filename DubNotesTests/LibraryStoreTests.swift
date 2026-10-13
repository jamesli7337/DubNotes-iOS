import XCTest
@testable import DubNotes

final class LibraryStoreTests: ScratchTestCase {
    private func makeStore() -> LibraryStore { LibraryStore(files: FileStore(root: scratch)) }

    /// A second store over the same folder, as a relaunch would build it.
    private func relaunch(_ s: LibraryStore) -> LibraryStore {
        s.flushNow()
        return makeStore()
    }

    // MARK: Persistence

    func testAnEmptyLibraryStartsEmpty() {
        let s = makeStore()
        XCTAssertTrue(s.notebooks.isEmpty)
        XCTAssertTrue(s.folders.isEmpty)
        XCTAssertNil(s.loadError)
        XCTAssertNil(s.recent.first)
    }

    func testNotebooksFoldersAndDividersSurviveARelaunch() {
        let s = makeStore()
        let folder = s.createFolder(name: "School", parentId: nil)
        let sub = s.createFolder(name: "Science", parentId: folder.id)
        let nb = s.createNotebook(name: "Physics", folderId: sub.id, paper: Paper(template: .grid, spacing: .narrow, color: .cream), kind: .pages)
        s.createDivider(folderId: nil, label: "Archive")
        s.setCover(nb.id, Notebook.Cover(color: "#0e7490", pattern: "waves"))

        let again = relaunch(s)
        XCTAssertEqual(again.folders.map(\.name).sorted(), ["School", "Science"])
        XCTAssertEqual(again.folder(sub.id)?.parentId, folder.id)
        XCTAssertEqual(again.dividers.map(\.label), ["Archive"])
        let loaded = try? XCTUnwrap(again.notebook(nb.id))
        XCTAssertEqual(loaded?.name, "Physics")
        XCTAssertEqual(loaded?.folderId, sub.id)
        XCTAssertEqual(loaded?.cover, Notebook.Cover(color: "#0e7490", pattern: "waves"))
        XCTAssertEqual(again.firstPage(of: nb.id)?.paper, Paper(template: .grid, spacing: .narrow, color: .cream))
    }

    func testAutosaveWritesAfterTheDelay() {
        let s = makeStore()
        let nb = s.createNotebook(name: "Timed", folderId: nil, paper: .default, kind: .pages)
        let file = scratch.appendingPathComponent("Notebooks/\(nb.id)/notebook.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing is written until the autosave fires")
        let wrote = expectation(description: "autosaved")
        DispatchQueue.main.asyncAfter(deadline: .now() + LibraryStore.saveDelay + 0.6) {
            if FileManager.default.fileExists(atPath: file.path) { wrote.fulfill() }
        }
        wait(for: [wrote], timeout: LibraryStore.saveDelay + 3)
    }

    func testEditsToAnOpenNotebookAreSavedAndCountedOnClose() throws {
        let s = makeStore()
        let nb = s.createNotebook(name: "Work", folderId: nil, paper: .default, kind: .pages)
        s.flushNow()
        let doc = try XCTUnwrap(s.openDocument(nb.id))
        let pageId = doc.pages[0].id
        doc.addStroke(Make.stroke("s1", page: pageId, nb: nb.id))
        doc.enforceTrailingBlank()
        doc.rename("Work, renamed")
        s.closeDocument(nb.id)

        XCTAssertEqual(s.notebook(nb.id)?.name, "Work, renamed")
        XCTAssertEqual(s.sizeLabel(for: s.notebook(nb.id)!), "1 page") // the trailing blank page is not counted

        let again = makeStore()
        let reopened = try XCTUnwrap(again.openDocument(nb.id))
        XCTAssertEqual(reopened.strokes(of: pageId).map(\.id), ["s1"])
        XCTAssertEqual(reopened.pages.count, 2)
        XCTAssertEqual(again.notebook(nb.id)?.name, "Work, renamed")
    }

    func testSizeLabels() throws {
        let s = makeStore()
        let nb = s.createNotebook(name: "N", folderId: nil, paper: .default, kind: .pages)
        XCTAssertEqual(s.sizeLabel(for: nb), "1 page")
        let board = s.createNotebook(name: "B", folderId: nil, paper: .default, kind: .board)
        XCTAssertEqual(s.sizeLabel(for: board), "Empty")
        XCTAssertEqual(s.firstPage(of: board.id)?.id, "\(board.id):0,0")
    }

    func testDeletingANotebookRemovesItsFolder() {
        let s = makeStore()
        let nb = s.createNotebook(name: "Gone", folderId: nil, paper: .default, kind: .pages)
        s.flushNow()
        let dir = scratch.appendingPathComponent("Notebooks/\(nb.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        s.delete(nb.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(relaunch(s).notebooks.isEmpty)
    }

    // MARK: Order, folders (rules carried over from the in-memory store)

    func testNewNotebooksGoToTheTopOfTheirFolder() {
        let s = makeStore()
        let a = s.createNotebook(name: "A", folderId: nil, paper: .default, kind: .pages)
        let b = s.createNotebook(name: "B", folderId: nil, paper: .default, kind: .pages)
        XCTAssertEqual(s.folderItems(nil).map(\.id), [b.id, a.id])
    }

    func testMovingUpAndDownSwapsNeighboursAndPersists() {
        let s = makeStore()
        let a = s.createNotebook(name: "A", folderId: nil, paper: .default, kind: .pages)
        let b = s.createNotebook(name: "B", folderId: nil, paper: .default, kind: .pages)
        let c = s.createNotebook(name: "C", folderId: nil, paper: .default, kind: .pages)
        s.moveItem(c.id, by: 1)
        XCTAssertEqual(s.folderItems(nil).map(\.id), [b.id, c.id, a.id])
        XCTAssertEqual(relaunch(s).folderItems(nil).map(\.id), [b.id, c.id, a.id])
    }

    func testDeletingAFolderMovesItsContentsUp() {
        let s = makeStore()
        let outer = s.createFolder(name: "Outer", parentId: nil)
        let inner = s.createFolder(name: "Inner", parentId: outer.id)
        let nb = s.createNotebook(name: "N", folderId: inner.id, paper: .default, kind: .pages)
        s.deleteFolder(inner.id)
        XCTAssertEqual(s.notebook(nb.id)?.folderId, outer.id)
        let again = relaunch(s)
        XCTAssertEqual(again.notebook(nb.id)?.folderId, outer.id)
        XCTAssertNil(again.folder(inner.id))
    }

    func testDividerAboveANotebook() {
        let s = makeStore()
        let a = s.createNotebook(name: "A", folderId: nil, paper: .default, kind: .pages)
        let b = s.createNotebook(name: "B", folderId: nil, paper: .default, kind: .pages)
        s.createDivider(folderId: nil, label: "Section", aboveNotebookId: a.id)
        let items = s.folderItems(nil)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].id, b.id)
        if case .divider(let d) = items[1] { XCTAssertEqual(d.label, "Section") } else { XCTFail("divider should sit above A") }
        XCTAssertEqual(items[2].id, a.id)
    }

    func testRecentIsByLastEdit() {
        let s = makeStore()
        let a = s.createNotebook(name: "A", folderId: nil, paper: .default, kind: .pages)
        let b = s.createNotebook(name: "B", folderId: nil, paper: .default, kind: .pages)
        Thread.sleep(forTimeInterval: 0.02) // timestamps are in milliseconds
        s.setCover(a.id, Notebook.Cover(color: "#000000")) // touches A's updatedAt
        XCTAssertEqual(s.recent.first?.id, a.id)
        XCTAssertEqual(s.recent.last?.id, b.id)
    }

    // MARK: Restore adds copies

    func testRestoreAddsCopiesAndNeverReplaces() throws {
        let s = makeStore()
        let mine = s.createNotebook(name: "Mine", folderId: nil, paper: .default, kind: .pages)
        let summary = try s.importBackup(fixtureData())
        XCTAssertEqual(summary.notebooks, 2)
        XCTAssertEqual(summary.folders, 2)
        XCTAssertEqual(s.notebooks.count, 3)
        XCTAssertNotNil(s.notebook(mine.id), "what was already here is untouched")
        XCTAssertFalse(s.notebooks.contains { $0.id == "nb1" }, "imported notebooks get new ids")

        let physics = try XCTUnwrap(s.notebooks.first { $0.name == "Physics" })
        XCTAssertNotNil(s.folder(try XCTUnwrap(physics.folderId)), "its folder came along")
        XCTAssertEqual(s.folders.map(\.name).sorted(), ["School", "Science"])
        XCTAssertEqual(s.folder(physics.folderId!)?.name, "Science")
        XCTAssertEqual(physics.cover, Notebook.Cover(color: "#3366aa", pattern: "dots"))
    }

    func testRestoringTwiceMakesTwoSeparateCopies() throws {
        let s = makeStore()
        try s.importBackup(fixtureData())
        try s.importBackup(fixtureData())
        XCTAssertEqual(s.notebooks.count, 4)
        XCTAssertEqual(Set(s.notebooks.map(\.id)).count, 4)
        XCTAssertEqual(s.folders.count, 4)
        XCTAssertEqual(s.notebooks.filter { $0.name == "Physics" }.count, 2)
    }

    func testRestoredNotebooksOpenWithTheirPagesAndInk() throws {
        let s = makeStore()
        try s.importBackup(fixtureData())
        let physics = try XCTUnwrap(s.notebooks.first { $0.name == "Physics" })
        let doc = try XCTUnwrap(relaunch(s).openDocument(physics.id))
        XCTAssertEqual(doc.pages.count, 3)
        XCTAssertEqual(doc.strokes(of: doc.pages[0].id).count, 2)
        XCTAssertEqual(doc.elements(of: doc.pages[0].id).count, 4)
        if case .pdf(let assetId, let n)? = doc.pages[2].background {
            XCTAssertEqual(n, 2)
            XCTAssertNotNil(s.files.readAsset(notebookId: physics.id, assetId: assetId), "the PDF came with it, under the new ids")
        } else {
            XCTFail("page 3 should still point at its PDF")
        }
        XCTAssertEqual(doc.pages[2].pageWidth, 612)
    }

    func testRestoredRootItemsGoAfterWhatIsAlreadyThere() throws {
        let s = makeStore()
        let mine = s.createNotebook(name: "Mine", folderId: nil, paper: .default, kind: .pages)
        try s.importBackup(fixtureData())
        let root = s.folderItems(nil)
        XCTAssertEqual(root.first?.id, mine.id)
        XCTAssertEqual(root.count, 3) // Mine, the board, the divider
        XCTAssertEqual(Set(root.map(\.order)).count, 3) // no two items share a slot
    }

    func testARestoreThatFailsLeavesTheLibraryAlone() throws {
        let s = makeStore()
        let mine = s.createNotebook(name: "Mine", folderId: nil, paper: .default, kind: .pages)
        XCTAssertThrowsError(try s.importBackup(Data("not a backup".utf8)))
        XCTAssertThrowsError(try s.importBackup(Data(#"{"app":"other","version":1}"#.utf8)))
        XCTAssertEqual(s.notebooks.map(\.id), [mine.id])
    }

    func testExportThenRestoreRoundTrips() throws {
        let s = makeStore()
        try s.importBackup(fixtureData())
        let data = try s.exportBackup()
        let backup = try BackupCodec.decode(data).backup
        XCTAssertEqual(backup.notebooks.count, 2)
        XCTAssertEqual(backup.assets.count, 1)
        XCTAssertEqual(backup.folders.count, 2)

        let other = LibraryStore(files: FileStore(root: scratch.appendingPathComponent("second", isDirectory: true)))
        try other.importBackup(data)
        XCTAssertEqual(other.notebooks.map(\.name).sorted(), ["Mind map", "Physics"])
        XCTAssertEqual(other.folders.count, 2)
    }
}
