import XCTest
@testable import DubNotes

final class PaperAndSizingTests: XCTestCase {
    // MARK: Colours

    func testHexParsing() {
        XCTAssertEqual(RGB(hex: "#ff8000"), RGB(255, 128, 0))
        XCTAssertEqual(RGB(hex: "f80"), RGB(255, 136, 0)) // short form, no hash
        XCTAssertEqual(RGB(hex: "#ff000080")?.a ?? 0, 128.0 / 255, accuracy: 1e-9)
        XCTAssertNil(RGB(hex: "#12"))
        XCTAssertNil(RGB(hex: "nonsense"))
        XCTAssertNil(RGB(hex: ""))
    }

    func testHexOutputIsLowercaseSixDigits() {
        XCTAssertEqual(RGB(255, 128, 0).hex, "#ff8000")
        XCTAssertEqual(RGB(0, 0, 0).hex, "#000000")
        XCTAssertEqual(RGB(300, -5, 12.4).hex, "#ff000c") // clamped, rounded
    }

    func testAutoInkFollowsThePaper() {
        let light = Paper(template: .blank, spacing: .medium, color: .white)
        let dark = Paper(template: .blank, spacing: .medium, color: .dark)
        XCTAssertEqual(PaperStyle.resolve("auto", on: light), "#1f2530")
        XCTAssertEqual(PaperStyle.resolve("auto", on: dark), "#f5f4ef")
        XCTAssertEqual(PaperStyle.resolve("auto", on: Paper(template: .grid, spacing: .narrow, color: .cream)), "#1f2530")
        XCTAssertEqual(PaperStyle.resolve("#dc2626", on: dark), "#dc2626") // fixed colours never change
    }

    func testPaperColoursAndSpacingMatchTheWeb() {
        XCTAssertEqual(PaperStyle.ink(.white).bg, "#ffffff")
        XCTAssertEqual(PaperStyle.ink(.cream).bg, "#f8f2e2")
        XCTAssertEqual(PaperStyle.ink(.dark).bg, "#1e2330")
        XCTAssertEqual(PaperStyle.ink(.dark).rule, "#3f4759")
        XCTAssertEqual([Paper.Spacing.narrow, .medium, .wide].map(PaperStyle.gap), [26, 38, 54])
    }

    func testOverlayColoursAreKeyedOnThePaperNotTheTheme() {
        XCTAssertEqual(PaperStyle.accent(Paper(template: .blank, spacing: .medium, color: .white)), "#2563eb")
        XCTAssertEqual(PaperStyle.accent(Paper(template: .blank, spacing: .medium, color: .dark)), "#8ca8ff")
    }

    // MARK: Page units

    func testTheDefaultPageIsAbout820By1060() {
        XCTAssertEqual(PageUnits.width, 820)
        XCTAssertEqual(PageUnits.height, 1060)
        let p = Make.page("p")
        XCTAssertEqual(p.pageWidth, 820)
        XCTAssertEqual(p.pageHeight, 1060)
    }

    func testPdfPageSizesKeepTheAspectAndTheDefaultArea() {
        let letter = PageSizing.notebookPageSize(pdfWidth: 612, pdfHeight: 792)
        XCTAssertEqual(letter.w * letter.h, PageUnits.width * PageUnits.height, accuracy: 1500) // rounding only
        XCTAssertEqual(letter.w / letter.h, 612.0 / 792, accuracy: 0.005)
        let landscape = PageSizing.notebookPageSize(pdfWidth: 792, pdfHeight: 612)
        XCTAssertGreaterThan(landscape.w, landscape.h)
        XCTAssertEqual(landscape.w * landscape.h, PageUnits.width * PageUnits.height, accuracy: 1500)
        let same = PageSizing.notebookPageSize(pdfWidth: 820, pdfHeight: 1060)
        XCTAssertEqual(same.w, 820)
        XCTAssertEqual(same.h, 1060)
    }

    func testAnUnreadablePdfPageFallsBackToTheDefaultSize() {
        let bad = PageSizing.notebookPageSize(pdfWidth: 0, pdfHeight: -4)
        XCTAssertEqual(bad.w, PageUnits.width)
        XCTAssertEqual(bad.h, PageUnits.height)
    }

    func testInsertedImagesFitSixtyPercentAndNeverUpscale() {
        let big = PageSizing.insertedImageSize(naturalW: 4000, naturalH: 2000, pageW: 820, pageH: 1060)
        XCTAssertEqual(big.w, 820 * 0.6, accuracy: 1e-9)
        XCTAssertEqual(big.h, 820 * 0.6 / 2, accuracy: 1e-9)
        let small = PageSizing.insertedImageSize(naturalW: 100, naturalH: 50, pageW: 820, pageH: 1060)
        XCTAssertEqual(small.w, 100)
        XCTAssertEqual(small.h, 50)
        let tiny = PageSizing.insertedImageSize(naturalW: 5, naturalH: 5, pageW: 820, pageH: 1060)
        XCTAssertEqual(tiny.w, 24) // never smaller than something you can grab
    }

    func testExportScaleIsLetterWidth() {
        XCTAssertEqual(PageSizing.pdfScale * PageUnits.width, 612, accuracy: 1e-9)
    }

    // MARK: Ruler and protractor

    func testRulerSnapsToItsLongEdges() throws {
        var g = GuideGeometry(kind: .ruler, pageWidth: 820, pageHeight: 1060)
        XCTAssertEqual(g.cx, 410)
        XCTAssertEqual(g.cy, 424)
        let top = try XCTUnwrap(g.edgeNear(410, 424 - 32 + 5)) // just inside the top edge
        XCTAssertEqual(top.py, 424 - 32, accuracy: 1e-9)
        XCTAssertEqual(top.project(100, 999).y, 392, accuracy: 1e-9) // everything lands on the edge line
        XCTAssertNil(g.edgeNear(410, 424)) // the middle of the ruler is not an edge
        XCTAssertNil(g.edgeNear(410, 700))
        g.angle = Double.pi / 2
        XCTAssertNotNil(g.edgeNear(410 + 32 - 4, 424)) // turned: its edge is now vertical
    }

    func testProtractorSnapsToItsBaseline() throws {
        let g = GuideGeometry(kind: .protractor, pageWidth: 820, pageHeight: 1060)
        let e = try XCTUnwrap(g.edgeNear(500, g.cy + 10))
        XCTAssertEqual(e.project(500, g.cy + 10).y, g.cy, accuracy: 1e-9)
        XCTAssertNil(g.edgeNear(500, g.cy + 60))
        XCTAssertNil(g.edgeNear(g.cx + 400, g.cy)) // beyond the protractor's width
    }

    func testGuideDegreesReadCounterClockwise() {
        var g = GuideGeometry(kind: .protractor, pageWidth: 820, pageHeight: 1060)
        XCTAssertEqual(g.degrees, 0)
        g.angle = -Double.pi / 4 // screen angle y-down: this is a counter-clockwise 45°
        XCTAssertEqual(g.degrees, 45)
        g.angle = Double.pi / 2
        XCTAssertEqual(g.degrees, 270)
    }
}
