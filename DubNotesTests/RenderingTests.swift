import PencilKit
import UIKit
import XCTest
@testable import DubNotes

/// Ink conversion, image import, export and split-screen storage: the parts that touch UIKit or PencilKit.
final class RenderingTests: ScratchTestCase {
    // MARK: Stroke conversion

    private let paper = Paper.default

    private func reconcile(_ drawing: PKDrawing, baseline: [Stroke], tool: Stroke.Tool = .pen, nib: Double = 4) -> StrokeConverter.Reconciled {
        StrokeConverter.reconcile(drawing, baseline: baseline, pageId: "p1", notebookId: "nb1", paper: paper,
                                  tool: tool, nib: nib, now: 5000)
    }

    private func wave(_ id: String, at: Double = 1) -> Stroke {
        Make.stroke(id, points: [(10, 10), (20, 14), (30, 10), (40, 14), (50, 10)], color: "#2563eb", size: 4, at: at)
    }

    func testPressureAndWidthAreInverses() {
        for p in stride(from: 0.0, through: 1.0, by: 0.25) {
            XCTAssertEqual(StrokeConverter.pressure(widthFactor: StrokeConverter.widthFactor(pressure: p)), p, accuracy: 1e-9)
        }
        XCTAssertEqual(StrokeConverter.pressure(widthFactor: 9), 1) // clamped
        XCTAssertEqual(StrokeConverter.pressure(widthFactor: -3), 0)
    }

    func testAnUntouchedDrawingReconcilesToTheIdenticalStrokes() {
        let strokes = [wave("a"), wave("b", at: 2), Make.stroke("c", color: "auto", at: 3)]
        let drawing = StrokeConverter.drawing(strokes, paper: paper)
        XCTAssertEqual(drawing.strokes.count, 3)
        let r = reconcile(drawing, baseline: strokes)
        XCTAssertEqual(r.strokes, strokes) // same ids, same points: nothing was lost to the round trip
        XCTAssertEqual(r.baseline, strokes)
    }

    func testAnAutoStrokeKeepsTheAutoToken() {
        let s = Make.stroke("a", color: "auto")
        XCTAssertEqual(reconcile(StrokeConverter.drawing([s], paper: paper), baseline: [s]).strokes.first?.color, "auto")
    }

    func testAStrokeThePencilAddedBecomesANewRecord() throws {
        let a = wave("a")
        var strokes = StrokeConverter.drawing([a], paper: paper).strokes
        let drawn = Make.stroke("temp", points: [(100, 100), (110, 120), (130, 125)], color: "#dc2626", size: 4)
        strokes.append(StrokeConverter.pkStroke(drawn, paper: paper)) // stands in for what PencilKit reports
        let r = reconcile(PKDrawing(strokes: strokes), baseline: [a])
        XCTAssertEqual(r.strokes.count, 2)
        XCTAssertEqual(try item(r.strokes, 0), a)
        let new = try item(r.strokes, 1)
        XCTAssertNotEqual(new.id, "temp")
        XCTAssertEqual(new.pageId, "p1")
        XCTAssertEqual(new.notebookId, "nb1")
        XCTAssertEqual(new.tool, .pen)
        XCTAssertEqual(new.color, "#dc2626")
        XCTAssertEqual(new.size, 4, accuracy: 1e-6)
        XCTAssertEqual(new.points.count, 3)
        XCTAssertEqual(try item(new.points, 1).x, 110, accuracy: 1e-6)
        XCTAssertEqual(new.createdAt, 5000)
        XCTAssertEqual(r.baseline.count, 2) // the next edit matches it by its own points
    }

    func testAnErasedStrokeIsGone() throws {
        let a = wave("a"), b = wave("b", at: 2)
        let all = StrokeConverter.drawing([a, b], paper: paper).strokes
        let r = reconcile(PKDrawing(strokes: [try item(all, 1)]), baseline: [a, b])
        XCTAssertEqual(r.strokes.map(\.id), ["b"])
    }

    func testAMovedStrokeKeepsItsPressureProfileAndGetsANewId() throws {
        var s = wave("a")
        s.points = s.points.enumerated().map { StrokePoint(x: $1.x, y: $1.y, pressure: Double($0) / 4) }
        let moved = StrokeConverter.drawing([s], paper: paper).transformed(using: CGAffineTransform(translationX: 100, y: 50))
        let r = reconcile(moved, baseline: [s])
        let out = try item(r.strokes, 0)
        XCTAssertNotEqual(out.id, "a")
        XCTAssertEqual(out.points.map(\.pressure), s.points.map(\.pressure))
        XCTAssertEqual(try item(out.points, 0).x, 110, accuracy: 1e-3)
        XCTAssertEqual(try item(out.points, 0).y, 60, accuracy: 1e-3)
    }

    func testAResizedStrokeScalesItsPoints() throws {
        let s = wave("a")
        let big = StrokeConverter.drawing([s], paper: paper).transformed(using: CGAffineTransform(scaleX: 2, y: 2))
        let out = try item(reconcile(big, baseline: [s]).strokes, 0)
        XCTAssertEqual(try item(out.points, 4).x, 100, accuracy: 1e-3)
    }

    func testAHighlighterStaysAHighlighter() {
        let s = Make.stroke("h", points: [(0, 0), (100, 0)], tool: .highlighter, color: "#fde047", size: 24)
        let r = reconcile(StrokeConverter.drawing([s], paper: paper), baseline: [s], tool: .highlighter, nib: 24)
        XCTAssertEqual(r.strokes, [s])
        XCTAssertEqual(StrokeConverter.drawing([s], paper: paper).strokes.first?.ink.inkType, PKInk.InkType.marker)
    }

    func testASingleSampleBecomesADrawableDot() {
        let dot = Make.stroke("dot", points: [(5, 5)])
        XCTAssertEqual(StrokeConverter.drawing([dot], paper: paper).strokes.first?.path.count, 2)
        XCTAssertEqual(StrokeConverter.signature(of: dot, paper: paper), StrokeConverter.signature(StrokeConverter.pkStroke(dot, paper: paper)))
    }

    func testSignaturesAgreeBetweenTheModelAndPencilKit() {
        let s = wave("a")
        XCTAssertEqual(StrokeConverter.signature(of: s, paper: paper), StrokeConverter.signature(StrokeConverter.pkStroke(s, paper: paper)))
        let hi = Make.stroke("h", tool: .highlighter, color: "#fde047", size: 20)
        XCTAssertEqual(StrokeConverter.signature(of: hi, paper: paper), StrokeConverter.signature(StrokeConverter.pkStroke(hi, paper: paper)))
    }

    // MARK: Identity through edits (strokes with identical shapes must not be swapped)

    /// Three strokes with the same shape, told apart only by when they were drawn.
    private func trio() -> [Stroke] { [wave("a", at: 10), wave("b", at: 20), wave("c", at: 30)] }

    private func canvas(_ strokes: [Stroke]) -> [PKStroke] { StrokeConverter.drawing(strokes, paper: paper).strokes }

    private func ids(_ r: StrokeConverter.Reconciled) -> [String] { r.strokes.map { $0.id } }

    func testErasingTheFirstMiddleOrLastOfThreeKeepsTheRightTwo() throws {
        let s = trio()
        let pk = canvas(s)
        XCTAssertEqual(pk.count, 3)
        XCTAssertEqual(ids(reconcile(PKDrawing(strokes: [pk[1], pk[2]]), baseline: s)), ["b", "c"])
        XCTAssertEqual(ids(reconcile(PKDrawing(strokes: [pk[0], pk[2]]), baseline: s)), ["a", "c"])
        XCTAssertEqual(ids(reconcile(PKDrawing(strokes: [pk[0], pk[1]]), baseline: s)), ["a", "b"])
    }

    func testErasingTwoLeavesTheThird() throws {
        let s = trio()
        let pk = canvas(s)
        XCTAssertEqual(ids(reconcile(PKDrawing(strokes: [pk[0]]), baseline: s)), ["a"])
        XCTAssertEqual(ids(reconcile(PKDrawing(strokes: [pk[1]]), baseline: s)), ["b"])
        XCTAssertEqual(ids(reconcile(PKDrawing(strokes: [pk[2]]), baseline: s)), ["c"])
        XCTAssertEqual(ids(reconcile(PKDrawing(strokes: []), baseline: s)), [])
    }

    func testErasingAndAddingTogetherKeepsSurvivorsAndMakesOneNewRecord() throws {
        let s = trio()
        let pk = canvas(s)
        let drawn = Make.stroke("temp", points: [(100, 100), (110, 120), (130, 125)], color: "#dc2626", size: 4, at: 99_000)
        let r = reconcile(PKDrawing(strokes: [pk[1], pk[2], StrokeConverter.pkStroke(drawn, paper: paper)]), baseline: s)
        XCTAssertEqual(r.strokes.count, 3)
        XCTAssertEqual(Array(ids(r).prefix(2)), ["b", "c"])
        let new = try item(r.strokes, 2)
        XCTAssertFalse(["a", "b", "c", "temp"].contains(new.id))
        XCTAssertEqual(new.color, "#dc2626")
        XCTAssertEqual(r.baseline.count, 3)
    }

    func testMovingOneStrokeWhileAnotherIsErased() throws {
        let s = trio()
        let pk = canvas(s)
        let moved = try XCTUnwrap(PKDrawing(strokes: [pk[2]]).transformed(using: CGAffineTransform(translationX: 100, y: 0)).strokes.first)
        // "a" erased, "b" untouched, "c" moved
        let r = reconcile(PKDrawing(strokes: [pk[1], moved]), baseline: s)
        XCTAssertEqual(r.strokes.count, 2)
        XCTAssertEqual(try item(r.strokes, 0), s[1]) // b is exactly as it was
        let c = try item(r.strokes, 1)
        XCTAssertNotEqual(c.id, "a")
        XCTAssertNotEqual(c.id, "b")
        XCTAssertEqual(try item(c.points, 0).x, 110, accuracy: 1e-3) // c's own points, shifted by 100
        XCTAssertEqual(c.createdAt, 30)
    }

    func testDrawingOrderSurvivesAnEraseAnAddAndAMove() throws {
        let s = trio()
        let pk = canvas(s)
        let drawn = Make.stroke("temp", points: [(100, 100), (110, 120), (130, 125)], color: "#dc2626", size: 4, at: 99_000)
        let moved = try XCTUnwrap(PKDrawing(strokes: [pk[0]]).transformed(using: CGAffineTransform(translationX: 5, y: 5)).strokes.first)
        let first = reconcile(PKDrawing(strokes: [moved, pk[2], StrokeConverter.pkStroke(drawn, paper: paper)]), baseline: s)
        // order follows the canvas: moved a, c, new
        XCTAssertEqual(first.strokes.count, 3)
        XCTAssertEqual(try item(first.strokes, 1).id, "c")
        XCTAssertEqual(try item(first.strokes, 0).createdAt, 10)
        XCTAssertGreaterThan(try item(first.strokes, 2).createdAt, 30)
        // reconciling the same canvas again against what it returned changes nothing
        let again = reconcile(PKDrawing(strokes: [moved, pk[2], StrokeConverter.pkStroke(drawn, paper: paper)]), baseline: first.baseline)
        XCTAssertEqual(again.strokes.map { $0.points.count }, first.strokes.map { $0.points.count })
        XCTAssertEqual(try item(again.strokes, 1).id, "c")
    }

    func testStrokesWithDifferentShapesAreAlsoKeptApart() throws {
        let a = Make.stroke("a", points: [(0, 0), (10, 0), (20, 0)], color: "#2563eb", size: 4, at: 1)
        let b = Make.stroke("b", points: [(0, 50), (10, 60), (20, 50)], color: "#2563eb", size: 4, at: 2)
        let pk = canvas([a, b])
        XCTAssertEqual(ids(reconcile(PKDrawing(strokes: [pk[1]]), baseline: [a, b])), ["b"])
        XCTAssertEqual(ids(reconcile(PKDrawing(strokes: [pk[0]]), baseline: [a, b])), ["a"])
    }

    // MARK: Page rendering

    func testAPageRendersAtTheRequestedScale() {
        let src = PageRenderer.Source(page: Make.page("p1"), strokes: [wave("a")], elements: [Make.text("t"), Make.tape("tp")])
        let img = PageRenderer.image(src, scale: 0.5)
        XCTAssertEqual(img.size.width, 410, accuracy: 1)
        XCTAssertEqual(img.size.height, 530, accuracy: 1)
    }

    func testRenderingCanBeLimitedToASlice() {
        let src = PageRenderer.Source(page: Make.page("p1"), strokes: [], elements: [])
        let slice = PageRenderer.image(src, scale: 1, region: 100...400)
        XCTAssertEqual(slice.size.height, 300, accuracy: 1)
        XCTAssertEqual(slice.size.width, 820, accuracy: 1)
    }

    func testThumbnailsKeepThePageShape() {
        var page = Make.page("p1")
        page.w = 1060
        page.h = 820
        let thumb = PageRenderer.thumbnail(PageRenderer.Source(page: page, strokes: [], elements: []), width: 200)
        XCTAssertEqual(thumb.size.width, 200, accuracy: 1)
        XCTAssertEqual(thumb.size.height, 200 * 820 / 1060, accuracy: 1)
    }

    func testTextWrapsAtTheBoxWidth() {
        let narrow = TextLayout.layout("alpha beta gamma delta", fontSize: 20, maxWidth: 80)
        let wide = TextLayout.layout("alpha beta gamma delta", fontSize: 20, maxWidth: 2000)
        XCTAssertGreaterThan(narrow.lines.count, 1)
        XCTAssertEqual(wide.lines, ["alpha beta gamma delta"])
        XCTAssertEqual(narrow.lineHeight, 26, accuracy: 1e-9)
        XCTAssertEqual(narrow.height, Double(narrow.lines.count) * 26, accuracy: 1e-9)
        XCTAssertEqual(TextLayout.layout("a\n\nb", fontSize: 20, maxWidth: 500).lines, ["a", "", "b"])
        XCTAssertEqual(TextLayout.layout("", fontSize: 20, maxWidth: 500).height, 26, accuracy: 1e-9) // an empty box is one line tall
    }

    func testAWordWiderThanTheBoxBreaksByCharacter() {
        let r = TextLayout.layout("Supercalifragilisticexpialidocious", fontSize: 20, maxWidth: 60)
        XCTAssertGreaterThan(r.lines.count, 2)
        XCTAssertEqual(r.lines.joined(), "Supercalifragilisticexpialidocious")
    }

    // MARK: Export

    func testFileNamesAreSafe() {
        XCTAssertEqual(Exporter.safeFileName("Math: part 1/2?"), "Math- part 1-2-")
        XCTAssertEqual(Exporter.safeFileName("   "), "notebook")
        XCTAssertEqual(Exporter.safeFileName("a   b"), "a b")
    }

    func testPdfExportHasOnePagePerSourceAtItsOwnSize() throws {
        var landscape = Make.page("p2", index: 1)
        landscape.w = 1060
        landscape.h = 820
        let sources = [PageRenderer.Source(page: Make.page("p1"), strokes: [wave("a")], elements: [Make.text("t")]),
                       PageRenderer.Source(page: landscape, strokes: [], elements: [])]
        let data = Exporter.pdfData(sources: sources, title: "Test")
        XCTAssertEqual(String(decoding: data.prefix(5), as: UTF8.self), "%PDF-")
        let doc = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
        XCTAssertEqual(doc.numberOfPages, 2)
        let first = try XCTUnwrap(doc.page(at: 1)).getBoxRect(.mediaBox)
        XCTAssertEqual(first.width, 612, accuracy: 0.5) // Letter width for the default page
        XCTAssertEqual(first.height, 1060 * 612 / 820, accuracy: 0.5)
        let second = try XCTUnwrap(doc.page(at: 2)).getBoxRect(.mediaBox)
        XCTAssertGreaterThan(second.width, second.height)
    }

    func testPngAndJpegExport() throws {
        let src = PageRenderer.Source(page: Make.page("p1"), strokes: [wave("a")], elements: [])
        let png = try XCTUnwrap(Exporter.imageData(src, format: .png))
        XCTAssertEqual([UInt8](png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let jpeg = try XCTUnwrap(Exporter.imageData(src, format: .jpeg))
        XCTAssertEqual([UInt8](jpeg.prefix(2)), [0xFF, 0xD8])
        XCTAssertEqual(UIImage(data: png)?.size.width, 1640) // 2x
    }

    func testExportWritesAFileNamedForThePage() throws {
        let src = PageRenderer.Source(page: Make.page("p1"), strokes: [], elements: [])
        let url = try Exporter.export(sources: [src], title: "T", format: .pdf, fileName: "Notes - page 1")
        XCTAssertEqual(url.lastPathComponent, "Notes - page 1.pdf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // MARK: Images

    private func pngData(width: Int, height: Int) -> Data {
        let r = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f
        }())
        return r.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    func testSniffing() {
        XCTAssertEqual(ImageImport.sniff(pngData(width: 4, height: 4)), .png)
        XCTAssertEqual(ImageImport.sniff(Data([0xFF, 0xD8, 0xFF, 0xE0])), .jpeg)
        XCTAssertEqual(ImageImport.sniff(Data("GIF89a".utf8)), .gif)
        XCTAssertEqual(ImageImport.sniff(Data("hello".utf8)), .other)
    }

    func testASmallPngIsKeptByteForByte() throws {
        let data = pngData(width: 64, height: 32)
        let loaded = try XCTUnwrap(ImageImport.load(data))
        XCTAssertEqual(loaded.width, 64)
        XCTAssertEqual(loaded.height, 32)
        XCTAssertEqual(loaded.src, "data:image/png;base64,\(data.base64EncodedString())")
    }

    func testABigImageIsDownscaledToTheLongestEdge() throws {
        let loaded = try XCTUnwrap(ImageImport.load(pngData(width: 3200, height: 1600)))
        XCTAssertEqual(loaded.width, 1600, accuracy: 1)
        XCTAssertEqual(loaded.height, 800, accuracy: 1)
        XCTAssertTrue(loaded.src.hasPrefix("data:image/png;base64,")) // a PNG stays a PNG
    }

    func testNotAnImageIsRejected() {
        XCTAssertNil(ImageImport.load(Data("definitely not an image".utf8)))
    }

    func testAnInlineImageDecodesForDrawing() throws {
        let data = pngData(width: 8, height: 8)
        let el = PageElement(id: "i", pageId: "p", notebookId: "n", x: 0, y: 0, w: 8, h: 8, createdAt: 1,
                             content: .image(PageElement.Image(src: "data:image/png;base64,\(data.base64EncodedString())")))
        XCTAssertNotNil(ElementRenderer.image(for: el, src: "data:image/png;base64,\(data.base64EncodedString())"))
        XCTAssertNil(ElementRenderer.image(for: el, src: "not a data url"))
    }

    // MARK: Split screen storage

    func testSplitStateRoundTripsPerHostNotebook() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "split-\(UUID().uuidString)"))
        XCTAssertNil(SplitStore.load(hostId: "a", defaults: d))
        var s = SplitState(kind: .page, notebookId: "other")
        s.floating = true
        s.float = FloatRect(x: 10, y: 20, w: 300, h: 400)
        s.fraction = 0.6
        SplitStore.save(s, hostId: "a", defaults: d)
        XCTAssertEqual(SplitStore.load(hostId: "a", defaults: d), s)
        XCTAssertNil(SplitStore.load(hostId: "b", defaults: d), "a split belongs to the notebook it was opened in")
        SplitStore.save(nil, hostId: "a", defaults: d)
        XCTAssertNil(SplitStore.load(hostId: "a", defaults: d))
    }

    func testReferenceFilesLiveOutsideTheNotebook() throws {
        let dir = scratch.appendingPathComponent("refs")
        let url = try SplitStore.writePayload(Data("one".utf8), hostId: "host", ext: "pdf", directory: dir)
        XCTAssertEqual(try Data(contentsOf: url), Data("one".utf8))
        // replacing a reference with one of another type leaves only the new file
        let png = try SplitStore.writePayload(Data("two".utf8), hostId: "host", ext: "png", directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path))
        SplitStore.removePayload(hostId: "host", directory: dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: png.path))
    }

    func testAFloatingBoxIsKeptOnScreenAndNeverTiny() {
        let r = FloatRect(x: 900, y: -50, w: 50, h: 5000).clamped(in: (w: 1000, h: 800))
        XCTAssertGreaterThanOrEqual(r.w, FloatRect.minW)
        XCTAssertLessThanOrEqual(r.y + r.h, 800)
        XCTAssertGreaterThanOrEqual(r.y, 0)
        XCTAssertLessThanOrEqual(r.x + r.w, 1000)
    }
}
