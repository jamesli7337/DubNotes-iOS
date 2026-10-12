import XCTest
@testable import DubNotes

final class BackupTests: XCTestCase {
    // MARK: Helpers

    private func fixtureData() throws -> Data {
        if let url = Bundle(for: BackupTests.self).url(forResource: "backup-sample", withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/backup-sample.json")
        return try Data(contentsOf: url)
    }

    private func decode(_ json: String) throws -> BackupImportResult {
        try BackupCodec.decode(Data(json.utf8))
    }

    private func assertDecodeFails(_ json: String, _ expected: BackupError,
                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try decode(json), file: file, line: line) { error in
            XCTAssertEqual(error as? BackupError, expected, file: file, line: line)
        }
    }

    // MARK: Sample file

    func testSampleDecodesEveryRecordAndElementKind() throws {
        let result = try BackupCodec.decode(fixtureData())
        let b = result.backup
        XCTAssertEqual(result.sourceVersion, 11)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(b.notebooks.count, 2)
        XCTAssertEqual(b.pages.count, 4)
        XCTAssertEqual(b.strokes.count, 2)
        XCTAssertEqual(b.elements.count, 7)
        XCTAssertEqual(b.folders.count, 2)
        XCTAssertEqual(b.dividers.count, 1)
        XCTAssertEqual(b.assets.count, 1)

        XCTAssertEqual(b.notebooks[0].cover, Notebook.Cover(color: "#3366aa", pattern: "dots"))
        XCTAssertTrue(b.notebooks[1].isBoard)
        XCTAssertEqual(b.pages[2].background, .pdf(assetId: "a1", page: 2))
        XCTAssertEqual(b.pages[2].pageWidth, 612)
        XCTAssertEqual(b.pages[0].pageWidth, PageUnits.width)
        XCTAssertEqual(b.pages[0].pageHeight, PageUnits.height)
        XCTAssertEqual(b.pages[3].col, 0)
        XCTAssertEqual(b.strokes[0].points[1], StrokePoint(x: 12.5, y: 24.25, pressure: 0.75))
        XCTAssertEqual(b.assets[0].data, Data("%PDF-1.4\n".utf8))

        var kinds = Set<String>()
        for e in b.elements {
            switch e.content {
            case .text(let t): kinds.insert("text"); XCTAssertEqual(t.bg, "#fff3b0")
            case .image: kinds.insert("image")
            case .shape(let s): kinds.insert("shape"); XCTAssertEqual(s.pts?.count, 3)
            case .tape: kinds.insert("tape")
            case .bubble: kinds.insert("bubble")
            case .connector(let c): kinds.insert("connector"); XCTAssertEqual(c.a.node, .e)
            }
        }
        XCTAssertEqual(kinds, PageElement.knownKinds)
    }

    func testRoundTripIsIdentical() throws {
        let first = try BackupCodec.decode(fixtureData()).backup
        let encoded = try BackupCodec.encode(first)
        let second = try BackupCodec.decode(encoded).backup
        XCTAssertEqual(first, second)
        // Encoding is deterministic, so a second pass is byte-identical.
        XCTAssertEqual(try BackupCodec.encode(second), encoded)
    }

    func testEncoderWritesVersion11() throws {
        let data = try BackupCodec.encode(Backup())
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["app"] as? String, "noteapp")
        XCTAssertEqual(obj["version"] as? Int, 11)
    }

    func testRootFolderIsWrittenAsExplicitNull() throws {
        let nb = Notebook(id: "n", name: "N", createdAt: 1, updatedAt: 1)
        let data = try BackupCodec.encode(Backup(notebooks: [nb]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try XCTUnwrap((obj["notebooks"] as? [[String: Any]])?.first)
        XCTAssertTrue(first["folderId"] is NSNull)
    }

    func testOlderRoundTripUpgradesThenIsStable() throws {
        let old = try decode(Self.v1)
        let again = try BackupCodec.decode(BackupCodec.encode(old.backup))
        XCTAssertEqual(again.sourceVersion, 11)
        XCTAssertEqual(old.backup, again.backup)
    }

    // MARK: Upgrades

    private static let v1 = """
    {"app":"noteapp","version":1,
     "notebooks":[
       {"id":"n1","name":"A","template":"lined","createdAt":1,"updatedAt":5},
       {"id":"n2","name":"B","template":"grid","createdAt":1,"updatedAt":9},
       {"id":"n3","name":"C","createdAt":1,"updatedAt":2}],
     "pages":[
       {"id":"p1","notebookId":"n1","index":0,"createdAt":1,"updatedAt":1},
       {"id":"p2","notebookId":"n2","index":0,"createdAt":1,"updatedAt":1},
       {"id":"p3","notebookId":"n3","index":0,"createdAt":1,"updatedAt":1}],
     "strokes":[
       {"id":"s1","pageId":"p1","notebookId":"n1","tool":"pen","color":"#1f2530","size":3,
        "points":[[1,2,0.5]],"createdAt":2}]}
    """

    func testV1ToV2MovesTemplateOntoPages() throws {
        let b = try decode(Self.v1).backup
        XCTAssertEqual(b.pages[0].paper, Paper(template: .ruled, spacing: .medium, color: .white))
        XCTAssertEqual(b.pages[1].paper, Paper(template: .grid, spacing: .medium, color: .white))
        XCTAssertEqual(b.pages[2].paper, Paper.default)
    }

    func testV1UpgradeAlsoAppliesLaterSteps() throws {
        let r = try decode(Self.v1)
        XCTAssertEqual(r.sourceVersion, 1)
        XCTAssertEqual(r.backup.strokes[0].color, "auto")          // v3
        XCTAssertTrue(r.backup.elements.isEmpty)                    // v4: missing array
        XCTAssertNil(r.backup.notebooks[0].folderId)                // v6
        // v6: ordered most-recently-edited first: n2 (9), n1 (5), n3 (2)
        XCTAssertEqual(r.backup.notebooks.map(\.order), [1, 0, 2])
    }

    func testV2ToV3ConvertsOnlyTheOldFixedBlack() throws {
        let b = try decode("""
        {"app":"noteapp","version":2,"notebooks":[],"pages":[],
         "strokes":[
           {"id":"s1","pageId":"p","notebookId":"n","tool":"pen","color":"#1f2530","size":3,"points":[],"createdAt":1},
           {"id":"s2","pageId":"p","notebookId":"n","tool":"pen","color":"#ff0000","size":3,"points":[],"createdAt":2}]}
        """).backup
        XCTAssertEqual(b.strokes.map(\.color), ["auto", "#ff0000"])
    }

    func testV3FileKeepsExplicitBlack() throws {
        let b = try decode("""
        {"app":"noteapp","version":3,"notebooks":[],"pages":[],
         "strokes":[{"id":"s1","pageId":"p","notebookId":"n","tool":"pen","color":"#1f2530","size":3,"points":[],"createdAt":1}]}
        """).backup
        XCTAssertEqual(b.strokes[0].color, "#1f2530")
    }

    func testV3ToV4DefaultsMissingRotation() throws {
        let b = try decode("""
        {"app":"noteapp","version":3,"notebooks":[],"pages":[],"strokes":[],
         "elements":[{"id":"e1","pageId":"p","notebookId":"n","kind":"tape","x":0,"y":0,"w":10,"h":10,
                      "createdAt":1,"color":"#fff"}]}
        """).backup
        XCTAssertEqual(b.elements[0].rotation, 0)
    }

    func testV5ToV6RepairsFoldersOrderAndOrphans() throws {
        let b = try decode("""
        {"app":"noteapp","version":5,
         "notebooks":[
           {"id":"n1","name":"A","folderId":"gone","createdAt":1,"updatedAt":1},
           {"id":"n2","name":"B","createdAt":1,"updatedAt":7}],
         "pages":[],"strokes":[],
         "folders":[
           {"id":"f1","name":"Root","createdAt":1,"updatedAt":1},
           {"id":"f2","name":"Orphan","parentId":"missing","createdAt":1,"updatedAt":1},
           {"id":"f3","name":"Child","parentId":"f1","createdAt":1,"updatedAt":1}],
         "dividers":[
           {"id":"d1","folderId":"missing","label":"L","order":0,"createdAt":1},
           {"id":"d2","folderId":"f1","label":"M","order":1,"createdAt":1}]}
        """).backup
        XCTAssertNil(b.notebooks[0].folderId)
        XCTAssertEqual(b.notebooks.map(\.order), [1, 0])
        XCTAssertEqual(b.folders.map(\.parentId), [nil, nil, "f1"])
        XCTAssertEqual(b.dividers.map(\.folderId), [nil, "f1"])
    }

    func testAdditiveVersionsDecodeUnchanged() throws {
        // v7 asset + triangle, v8 text bg, v9 board, v10 bubble, v11 connector: nothing to migrate.
        for v in 6...11 {
            let r = try BackupCodec.decode(fixtureData().replacingVersion(with: v))
            XCTAssertEqual(r.sourceVersion, v)
            XCTAssertEqual(r.backup.elements.count, 7)
            XCTAssertEqual(r.backup.notebooks[0].folderId, "f2")
        }
    }

    // MARK: Unknown kinds

    func testUnknownElementKindIsSkippedWithWarning() throws {
        let r = try decode("""
        {"app":"noteapp","version":11,"notebooks":[],"pages":[],"strokes":[],
         "elements":[
           {"id":"e1","pageId":"p","notebookId":"n","kind":"hologram","x":0,"y":0,"w":1,"h":1,"rotation":0,"createdAt":1},
           {"id":"e2","pageId":"p","notebookId":"n","kind":"tape","x":0,"y":0,"w":1,"h":1,"rotation":0,"createdAt":2,"color":"#fff"},
           {"id":"e3","pageId":"p","notebookId":"n","x":0,"y":0,"w":1,"h":1,"rotation":0,"createdAt":3}]}
        """)
        XCTAssertEqual(r.backup.elements.map(\.id), ["e2"])
        XCTAssertEqual(r.warnings.count, 2)
        XCTAssertTrue(r.warnings[0].contains("hologram"))
        XCTAssertTrue(r.warnings[0].contains("e1"))
    }

    // MARK: Errors

    func testRejectsNewerVersion() {
        assertDecodeFails(#"{"app":"noteapp","version":12}"#, .newerVersion(found: 12, supported: 11))
    }

    func testRejectsOtherApp() {
        assertDecodeFails(#"{"app":"other","version":11}"#, .notNoteApp)
        assertDecodeFails(#"{"version":11}"#, .notNoteApp)
    }

    func testRejectsNonJSONAndNonObject() {
        assertDecodeFails("not json at all", .notJSON)
        assertDecodeFails("[1,2,3]", .notJSON)
    }

    func testRejectsMissingOrBadVersion() {
        assertDecodeFails(#"{"app":"noteapp"}"#, .invalidVersion)
        assertDecodeFails(#"{"app":"noteapp","version":"11"}"#, .invalidVersion)
        assertDecodeFails(#"{"app":"noteapp","version":0}"#, .invalidVersion)
    }

    func testMalformedRecordReportsWhereAndHasReadableMessage() {
        let json = #"{"app":"noteapp","version":11,"notebooks":[{"id":"n1"}]}"#
        XCTAssertThrowsError(try decode(json)) { error in
            guard case BackupError.malformed(let detail) = error else {
                return XCTFail("expected malformed, got \(error)")
            }
            XCTAssertTrue(detail.contains("name"))
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.isEmpty ?? true)
        }
    }

    func testBadAssetBase64IsMalformed() {
        let json = """
        {"app":"noteapp","version":11,"assets":[{"id":"a","notebookId":"n","kind":"pdf","name":"x","pages":1,"dataBase64":"!!!"}]}
        """
        XCTAssertThrowsError(try decode(json)) { error in
            guard case BackupError.malformed = error else { return XCTFail("expected malformed") }
        }
    }
}

private extension Data {
    /// Rewrites the top-level "version" of a JSON backup.
    func replacingVersion(with version: Int) throws -> Data {
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: self) as? [String: Any])
        obj["version"] = version
        return try JSONSerialization.data(withJSONObject: obj)
    }
}
