import XCTest
@testable import DubNotes

final class ToolSettingsTests: XCTestCase {
    func testDefaults() {
        let s = ToolSettings()
        XCTAssertEqual(s.kind, .pen)
        XCTAssertEqual(s.penColor, "auto")
        XCTAssertEqual(s.toolOrder, ToolKind.allCases)
        XCTAssertEqual(s.dockPosition, .top)
        XCTAssertEqual(s.penSwatches.first, PaperStyle.autoColor)
    }

    func testSizesAreClampedToEachToolsRange() {
        var s = ToolSettings()
        s.setSize(.pen, 99)
        s.setSize(.highlighter, 0.1)
        XCTAssertEqual(s.penSize, 12)
        XCTAssertEqual(s.highlighterSize, 4)
    }

    func testCustomColourIsAppendedLowercasedAndDeduplicated() {
        var s = ToolSettings()
        s.addCustomColor(.pen, hex: "#ABCDEF")
        s.addCustomColor(.pen, hex: "#abcdef")
        XCTAssertEqual(s.penSwatches.filter { $0 == "#abcdef" }.count, 1)
        XCTAssertEqual(s.penSwatches.last, "#abcdef")
    }

    func testCustomColoursAreCappedAndTheOldestGoesFirst() {
        var s = ToolSettings()
        for i in 0..<(ToolSettings.customColorsMax + 3) { s.addCustomColor(.pen, hex: String(format: "#0000%02x", i + 1)) }
        let customs = s.penSwatches.filter { !ToolSettings.penColors.contains($0) }
        XCTAssertEqual(customs.count, ToolSettings.customColorsMax)
        XCTAssertFalse(customs.contains("#000001")) // evicted
        XCTAssertEqual(customs.last, String(format: "#0000%02x", ToolSettings.customColorsMax + 3))
        XCTAssertTrue(ToolSettings.penColors.allSatisfy { s.penSwatches.contains($0) }) // presets are never evicted
    }

    func testRemovingAPresetParksItAndTheCustomIsDroppedForGood() {
        var s = ToolSettings()
        s.removeSwatch(.pen, "#dc2626")
        XCTAssertFalse(s.penSwatches.contains("#dc2626"))
        XCTAssertEqual(s.penDeletedPresets, ["#dc2626"])
        s.addCustomColor(.pen, hex: "#123456")
        s.removeSwatch(.pen, "#123456")
        XCTAssertFalse(s.penSwatches.contains("#123456"))
        XCTAssertFalse(s.penDeletedPresets.contains("#123456"))
        s.restorePreset(.pen, "#dc2626")
        XCTAssertEqual(s.penSwatches.last, "#dc2626")
        XCTAssertTrue(s.penDeletedPresets.isEmpty)
    }

    func testThePrimaryColourCannotBeRemoved() {
        var s = ToolSettings()
        s.removeSwatch(.pen, PaperStyle.autoColor)
        XCTAssertEqual(s.penSwatches.first, PaperStyle.autoColor)
        XCTAssertTrue(s.penDeletedPresets.isEmpty)
    }

    func testSwatchOrderMustBeAPermutation() {
        var s = ToolSettings()
        let reversed = Array(s.penSwatches.reversed())
        s.setSwatchOrder(.pen, reversed)
        XCTAssertEqual(s.penSwatches, reversed)
        s.setSwatchOrder(.pen, ["#000000"]) // wrong contents: ignored
        XCTAssertEqual(s.penSwatches, reversed)
    }

    func testToolOrderMovesOnlyTheNamedTools() {
        var s = ToolSettings()
        s.setToolOrder([.hand, .pen]) // swap the first and last of the two named
        XCTAssertEqual(s.toolOrder.first, .hand)
        XCTAssertEqual(s.toolOrder[1], .highlighter) // untouched slots stay put
        XCTAssertEqual(s.toolOrder.last, .pen)
        XCTAssertEqual(Set(s.toolOrder), Set(ToolKind.allCases))
    }

    func testToolOrderIgnoresDuplicatesAndUnknownTools() {
        var s = ToolSettings()
        let before = s.toolOrder
        s.setToolOrder([.pen, .pen])
        XCTAssertEqual(s.toolOrder, before)
    }

    func testCleanToolOrderAppendsMissingTools() {
        XCTAssertEqual(Array(ToolSettings.cleanToolOrder([.hand, .pen, .hand]).prefix(2)), [ToolKind.hand, ToolKind.pen])
        XCTAssertEqual(Set(ToolSettings.cleanToolOrder([.hand])), Set(ToolKind.allCases))
    }

    func testResetToPrimary() {
        var s = ToolSettings()
        s.penColor = "#2563eb"
        s.highlighterColor = "#93c5fd"
        s.textColor = "#dc2626"
        s.resetActiveColorsToPrimary()
        XCTAssertEqual(s.penColor, "auto")
        XCTAssertEqual(s.highlighterColor, "#fde047")
        XCTAssertEqual(s.textColor, "auto")
    }

    func testRoundTripThroughUserDefaults() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "tool-settings-\(UUID().uuidString)"))
        var s = ToolSettings()
        s.kind = .lasso
        s.lassoShape = .circle
        s.penSize = 7.5
        s.dockPosition = .bottom
        s.addCustomColor(.highlighter, hex: "#00ff00")
        s.setToolOrder([.laser, .pen])
        s.save(to: suite)
        XCTAssertEqual(ToolSettings.load(from: suite), s)
    }

    func testAnOldOrDamagedSaveStillLoads() throws {
        let json = #"{"kind":"shape","penSize":99,"penSwatches":["#ZZZ","#2563EB","#2563eb"],"toolOrder":["hand","bogus"],"penColor":"#missing"}"#
        let s = try JSONDecoder().decode(ToolSettings.self, from: Data(json.utf8))
        XCTAssertEqual(s.kind, .pen) // the old draw-then-snap tool is gone: back to the pen
        XCTAssertEqual(s.penSize, 12) // clamped
        XCTAssertEqual(s.penSwatches, ["#2563eb"]) // junk dropped, duplicates merged
        XCTAssertEqual(s.penColor, "#2563eb") // the active colour must be in its row
        XCTAssertEqual(s.toolOrder.first, .hand)
        XCTAssertEqual(Set(s.toolOrder), Set(ToolKind.allCases))
    }

    func testMissingSaveIsFreshDefaults() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "tool-settings-\(UUID().uuidString)"))
        XCTAssertEqual(ToolSettings.load(from: suite), ToolSettings())
    }

    // MARK: Reordering helper

    func testMovingBefore() {
        XCTAssertEqual([1, 2, 3, 4].moving(4, before: 2), [1, 4, 2, 3])
        XCTAssertEqual([1, 2, 3, 4].moving(1, before: 3), [2, 1, 3, 4])
        XCTAssertEqual([1, 2, 3].moving(2, before: 2), [1, 2, 3])
        XCTAssertEqual([1, 2, 3].moving(9, before: 2), [1, 2, 3])
        XCTAssertEqual([1, 2, 3].movingToEnd(1), [2, 3, 1])
    }
}
