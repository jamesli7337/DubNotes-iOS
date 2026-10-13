import XCTest
@testable import DubNotes

final class LibraryPreferencesTests: XCTestCase {
    private func suite() throws -> UserDefaults {
        try XCTUnwrap(UserDefaults(suiteName: "library-prefs-\(UUID().uuidString)"))
    }

    func testDefaults() throws {
        let p = LibraryPreferences.load(from: try suite())
        XCTAssertEqual(p.layout, .grid)
        XCTAssertEqual(p.sort, .manual)
        XCTAssertTrue(p.openFolders.isEmpty)
    }

    func testFolderExpansionLayoutAndSortAreRemembered() throws {
        let d = try suite()
        var p = LibraryPreferences()
        p.openFolders = ["a", "b"]
        p.layout = .list
        p.sort = .name
        p.save(to: d)
        XCTAssertEqual(LibraryPreferences.load(from: d), p)
    }

    func testUnknownStoredValuesFallBackToDefaults() throws {
        let d = try suite()
        d.set("carousel", forKey: LibraryPreferences.layoutKey)
        d.set("by colour", forKey: LibraryPreferences.sortKey)
        d.set(Data("garbage".utf8), forKey: LibraryPreferences.openKey)
        let p = LibraryPreferences.load(from: d)
        XCTAssertEqual(p.layout, .grid)
        XCTAssertEqual(p.sort, .manual)
        XCTAssertTrue(p.openFolders.isEmpty)
    }

    func testPruneForgetsFoldersThatNoLongerExist() {
        var p = LibraryPreferences()
        p.openFolders = ["keep", "gone"]
        p.prune(existing: ["keep", "other"])
        XCTAssertEqual(p.openFolders, ["keep"])
    }

    func testSortOrders() {
        func nb(_ name: String, created: Double, updated: Double) -> Notebook {
            var n = Make.notebook(name, name: name, updatedAt: updated)
            n.createdAt = created
            return n
        }
        let list = [nb("b", created: 1, updated: 30), nb("c", created: 3, updated: 10), nb("a", created: 2, updated: 20)]
        XCTAssertEqual(LibraryPreferences.sorted(list, by: .manual).map(\.name), ["b", "c", "a"])
        XCTAssertEqual(LibraryPreferences.sorted(list, by: .name).map(\.name), ["a", "b", "c"])
        XCTAssertEqual(LibraryPreferences.sorted(list, by: .updated).map(\.name), ["b", "a", "c"])
        XCTAssertEqual(LibraryPreferences.sorted(list, by: .created).map(\.name), ["c", "a", "b"])
    }

    func testSortLabelsMatchTheWeb() {
        XCTAssertEqual(LibraryPreferences.Sort.allCases.map(\.rawValue),
                       ["Manual order", "Date modified", "Date created", "Name (A–Z)"])
    }

    // MARK: Cover picker rules

    func testPickingAColourKeepsThePattern() {
        let cover = Notebook.Cover(color: "#000000", pattern: "waves")
        XCTAssertEqual(CoverOptions.picking(color: "#047857", from: cover), Notebook.Cover(color: "#047857", pattern: "waves"))
        XCTAssertEqual(CoverOptions.picking(color: "#047857", from: nil), Notebook.Cover(color: "#047857", pattern: nil))
    }

    func testPickingAPatternKeepsTheColourOrStartsFromTheFirst() {
        XCTAssertEqual(CoverOptions.picking(pattern: "dots", from: Notebook.Cover(color: "#be123c")),
                       Notebook.Cover(color: "#be123c", pattern: "dots"))
        XCTAssertEqual(CoverOptions.picking(pattern: "grid", from: nil), Notebook.Cover(color: CoverOptions.colors[0], pattern: "grid"))
        XCTAssertEqual(CoverOptions.picking(pattern: nil, from: Notebook.Cover(color: "#be123c", pattern: "dots")),
                       Notebook.Cover(color: "#be123c", pattern: nil)) // "Plain"
    }

    func testTheCoverPaletteMatchesTheWeb() {
        XCTAssertEqual(CoverOptions.colors.count, 8)
        XCTAssertEqual(CoverOptions.patterns, ["dots", "grid", "stripes", "waves", "chevron"])
    }
}
