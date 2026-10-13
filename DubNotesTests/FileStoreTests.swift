import XCTest
@testable import DubNotes

final class FileStoreTests: ScratchTestCase {
    private func store() -> FileStore { FileStore(root: scratch) }

    private func sampleDocument() -> NotebookDocument {
        let doc = Make.document(pages: 3)
        doc.addElement(Make.text("t0", page: "p0"))
        doc.addElement(Make.shape("sh", page: "p0"))
        doc.setBackground("p1", .pdf(assetId: "a1", page: 2))
        doc.setPageSize("p1", w: 612, h: 792)
        return doc
    }

    // MARK: Documents

    func testADocumentRoundTripsThroughFiles() throws {
        let files = store()
        let doc = sampleDocument()
        try files.writeNew(doc)
        let loaded = try XCTUnwrap(files.loadDocument("nb1"))
        XCTAssertEqual(loaded.notebook, doc.notebook)
        XCTAssertEqual(loaded.pages, doc.pages)
        for p in doc.pages {
            XCTAssertEqual(loaded.strokes(of: p.id), doc.strokes(of: p.id))
            XCTAssertEqual(loaded.elements(of: p.id), doc.elements(of: p.id))
        }
    }

    func testOneFolderPerNotebookWithAFilePerPage() throws {
        let files = store()
        try files.writeNew(sampleDocument())
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: scratch.appendingPathComponent("Notebooks/nb1/notebook.json").path))
        for id in ["p0", "p1", "p2"] {
            XCTAssertTrue(fm.fileExists(atPath: scratch.appendingPathComponent("Notebooks/nb1/pages/\(id).json").path), id)
        }
    }

    func testSaveWritesOnlyDirtyPagesAndClearsTheMarks() throws {
        let files = store()
        let doc = sampleDocument()
        try files.writeNew(doc)
        let untouched = scratch.appendingPathComponent("Notebooks/nb1/pages/p2.json")
        let before = try Data(contentsOf: untouched)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: untouched.path)

        doc.addStroke(Make.stroke("fresh", page: "p0", at: 99))
        XCTAssertEqual(doc.dirtyPages, ["p0"])
        try files.save(doc)
        XCTAssertTrue(doc.dirtyPages.isEmpty)
        XCTAssertFalse(doc.manifestDirty)

        let attrs = try FileManager.default.attributesOfItem(atPath: untouched.path)
        XCTAssertEqual((attrs[.modificationDate] as? Date)?.timeIntervalSince1970, 0) // p2 was not rewritten
        XCTAssertEqual(try Data(contentsOf: untouched), before)
        XCTAssertTrue(try XCTUnwrap(files.loadDocument("nb1")).strokes(of: "p0").contains { $0.id == "fresh" })
    }

    func testDeletedPagesLoseTheirFiles() throws {
        let files = store()
        let doc = sampleDocument()
        try files.writeNew(doc)
        doc.deletePage("p0")
        try files.save(doc)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Notebooks/nb1/pages/p0.json").path))
        XCTAssertEqual(try XCTUnwrap(files.loadDocument("nb1")).pages.map(\.id), ["p1", "p2"])
    }

    func testRenumberingIsSavedWithTheManifest() throws {
        let files = store()
        let doc = sampleDocument()
        try files.writeNew(doc)
        doc.reorderPages(["p2", "p1", "p0"])
        try files.save(doc)
        let loaded = try XCTUnwrap(files.loadDocument("nb1"))
        XCTAssertEqual(loaded.pages.map(\.id), ["p2", "p1", "p0"])
        XCTAssertEqual(loaded.pages.map(\.index), [0, 1, 2])
    }

    func testABoardPageIdWithColonsIsAValidFileName() throws {
        let files = store()
        let nb = Make.notebook("nb2")
        let page = Page(id: "nb2:0,0", notebookId: "nb2", index: 0, paper: .default, col: 0, row: 0, createdAt: 1, updatedAt: 1)
        let doc = NotebookDocument(notebook: nb, pages: [page], strokes: [Make.stroke("s", page: "nb2:0,0", nb: "nb2")])
        try files.writeNew(doc)
        XCTAssertEqual(try XCTUnwrap(files.loadDocument("nb2")).strokes(of: "nb2:0,0").count, 1)
    }

    func testImagesStayInlineInThePageFile() throws {
        let files = store()
        let doc = NotebookDocument(notebook: Make.notebook(), pages: [Make.page("p1")])
        let img = PageElement(id: "img", pageId: "p1", notebookId: "nb1", x: 0, y: 0, w: 10, h: 10, createdAt: 1,
                              content: .image(PageElement.Image(src: "data:image/png;base64,AAAA")))
        doc.addElement(img)
        try files.writeNew(doc)
        XCTAssertEqual(try XCTUnwrap(files.loadDocument("nb1")).elements(of: "p1"), [img])
    }

    // MARK: Damage

    func testACorruptPageFileIsMovedAsideNotOverwritten() throws {
        let files = store()
        try files.writeNew(sampleDocument())
        let url = scratch.appendingPathComponent("Notebooks/nb1/pages/p0.json")
        try Data("{ not json".utf8).write(to: url)
        let loaded = try XCTUnwrap(files.loadDocument("nb1"))
        XCTAssertTrue(loaded.strokes(of: "p0").isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertTrue(names.contains { $0.hasPrefix("p0.json.corrupt-") }, "the damaged file must be kept for recovery")
        XCTAssertFalse(names.contains("p0.json"))
    }

    func testAMissingPageFileIsEmptyNotAnError() throws {
        let files = store()
        try files.writeNew(sampleDocument())
        try FileManager.default.removeItem(at: scratch.appendingPathComponent("Notebooks/nb1/pages/p1.json"))
        let loaded = try XCTUnwrap(files.loadDocument("nb1"))
        XCTAssertEqual(loaded.pages.count, 3)
        XCTAssertTrue(loaded.items(of: "p1").isEmpty)
    }

    func testAnUnreadableNotebookFolderIsReportedAndSkipped() throws {
        let files = store()
        try files.writeNew(sampleDocument())
        let bad = scratch.appendingPathComponent("Notebooks/broken", isDirectory: true)
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("nope".utf8).write(to: bad.appendingPathComponent("notebook.json"))
        let (manifests, unreadable) = files.loadManifests()
        XCTAssertEqual(manifests.map { $0.notebook.id }, ["nb1"])
        XCTAssertEqual(unreadable, ["broken"])
    }

    func testDeleteRemovesTheWholeFolder() throws {
        let files = store()
        try files.writeNew(sampleDocument())
        files.deleteNotebook("nb1")
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Notebooks/nb1").path))
        XCTAssertNil(files.loadDocument("nb1"))
    }

    // MARK: Library meta, assets

    func testLibraryMetaRoundTrip() throws {
        let files = store()
        XCTAssertEqual(files.loadLibraryMeta(), FileStore.LibraryMeta()) // nothing yet: empty, not an error
        let meta = FileStore.LibraryMeta(folders: [Folder(id: "f", name: "F", createdAt: 1, updatedAt: 1)],
                                         dividers: [Divider(id: "d", label: "D", order: 0, createdAt: 1)])
        try files.saveLibraryMeta(meta)
        XCTAssertEqual(files.loadLibraryMeta(), meta)
    }

    func testAssetsAreStoredOncePerNotebookAsPlainPDFs() throws {
        let files = store()
        let bytes = Data("%PDF-1.4\n".utf8)
        let asset = Asset(id: "a1", notebookId: "nb1", name: "sheet.pdf", pages: 2, data: bytes)
        try files.writeAsset(asset)
        XCTAssertEqual(try Data(contentsOf: files.assetURL(notebookId: "nb1", assetId: "a1")), bytes)
        XCTAssertEqual(files.readAsset(notebookId: "nb1", assetId: "a1"), asset)
        XCTAssertEqual(files.assetMetas(notebookId: "nb1").map(\.id), ["a1"])
        XCTAssertNil(files.readAsset(notebookId: "nb1", assetId: "missing"))
    }

    // MARK: Backups

    func testBackupExportThenWriteBackKeepsEverything() throws {
        let files = store()
        let decoded = try BackupCodec.decode(fixtureData()).backup
        let copies = BackupImporter.makeCopies(of: decoded).backup
        let written = try files.writeBackupNotebooks(copies)
        XCTAssertEqual(written.count, 2)
        let made = files.makeBackup(folders: copies.folders, dividers: copies.dividers, manifests: written)
        XCTAssertEqual(made.notebooks.count, 2)
        XCTAssertEqual(made.pages.count, 4)
        XCTAssertEqual(made.strokes.count, 2)
        XCTAssertEqual(made.elements.count, copies.elements.count)
        XCTAssertEqual(made.assets.map(\.name), ["sheet.pdf"])
        XCTAssertEqual(made.assets.first?.data, Data("%PDF-1.4\n".utf8))
        // and the result is a valid v11 backup that decodes again
        XCTAssertNoThrow(try BackupCodec.decode(BackupCodec.encode(made)))
    }
}
