import XCTest
@testable import DubNotes

final class GeometryTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false // later lines index into results; stop at the first failure instead of trapping
    }

    private let square = [Pt(0, 0), Pt(10, 0), Pt(10, 10), Pt(0, 10)]

    func testPointInPolygon() {
        XCTAssertTrue(Geometry.pointInPolygon(5, 5, square))
        XCTAssertFalse(Geometry.pointInPolygon(15, 5, square))
        XCTAssertFalse(Geometry.pointInPolygon(-1, -1, square))
    }

    func testNearPolylineMeasuresToSegmentsNotJustVertices() {
        let line = [Pt(0, 0), Pt(100, 0)]
        XCTAssertTrue(Geometry.nearPolyline(50, 3, line, 4))
        XCTAssertFalse(Geometry.nearPolyline(50, 6, line, 4))
        XCTAssertTrue(Geometry.nearPolyline(104, 0, line, 5))
    }

    func testRotateAroundQuarterTurn() {
        let p = Geometry.rotateAround(10, 0, 0, 0, Double.pi / 2)
        XCTAssertEqual(p.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.y, 10, accuracy: 1e-9)
        XCTAssertEqual(Geometry.rotateAround(3, 4, 0, 0, 0), Pt(3, 4))
    }

    func testElementHitRespectsRotation() {
        var e = Make.shape("e", x: 0, y: 0, w: 100, h: 10)
        XCTAssertTrue(Geometry.pointInElement(e, 90, 5))
        e.rotation = Double.pi / 2 // now a tall box about its centre (50, 5)
        XCTAssertFalse(Geometry.pointInElement(e, 90, 5))
        XCTAssertTrue(Geometry.pointInElement(e, 50, 50))
    }

    func testShapeOutlineHitIgnoresTheInterior() {
        let e = Make.shape("e", kind: .rect, x: 0, y: 0, w: 100, h: 100)
        guard case .shape(let s) = e.content else { return XCTFail() }
        XCTAssertTrue(Geometry.nearShapeOutline(e, s, 0, 50, 3))
        XCTAssertFalse(Geometry.nearShapeOutline(e, s, 50, 50, 3))
    }

    func testStrokeInPolygonTouchesOrCrosses() {
        let inside = Make.stroke("a", points: [(5, 5), (6, 6)])
        let outside = Make.stroke("b", points: [(50, 50), (60, 60)])
        let crossing = Make.stroke("c", points: [(-20, 5), (30, 5)]) // no sample inside, but the segment crosses
        XCTAssertTrue(Geometry.strokeInPolygon(inside.pts, square))
        XCTAssertFalse(Geometry.strokeInPolygon(outside.pts, square))
        XCTAssertTrue(Geometry.strokeInPolygon(crossing.pts, square))
    }

    func testMarqueePolygons() {
        let box = Geometry.marqueePolygon(circle: false, Pt(10, 20), Pt(0, 0))
        XCTAssertEqual(box.count, 4)
        XCTAssertTrue(Geometry.pointInPolygon(5, 10, box))
        let ellipse = Geometry.marqueePolygon(circle: true, Pt(0, 0), Pt(100, 100))
        XCTAssertTrue(Geometry.pointInPolygon(50, 50, ellipse))
        XCTAssertFalse(Geometry.pointInPolygon(2, 2, ellipse)) // the corner of the box is outside the circle
    }

    func testItemsFrameSingleElementKeepsItsBox() {
        var e = Make.shape("e", x: 10, y: 20, w: 30, h: 40)
        e.rotation = 0.5
        let f = Geometry.itemsFrame([.element(e)])
        XCTAssertEqual(f, ItemFrame(x: 10, y: 20, w: 30, h: 40, rot: 0.5))
    }

    func testItemsFrameOfStrokesIsTheirBounds() throws {
        let a = Make.stroke("a", points: [(0, 0), (10, 10)], size: 2)
        let f = try XCTUnwrap(Geometry.itemsFrame([.stroke(a)]))
        XCTAssertEqual(f.x, -1, accuracy: 1e-9)
        XCTAssertEqual(f.w, 12, accuracy: 1e-9)
        XCTAssertEqual(f.rot, 0)
        XCTAssertNil(Geometry.itemsFrame([]))
    }

    func testTransformIdentityChangesNothing() {
        let items: [PageItem] = [.stroke(Make.stroke("a", points: [(0, 0), (10, 10)])), .element(Make.text("t"))]
        let frame = Geometry.itemsFrame(items)!
        XCTAssertEqual(Geometry.transformItems(items, from: frame, to: frame), items)
    }

    func testTransformScalesStrokePointsAndNib() throws {
        let s = Make.stroke("a", points: [(0, 0), (10, 10)], size: 4)
        let from = ItemFrame(x: 0, y: 0, w: 10, h: 10)
        let to = ItemFrame(x: 100, y: 100, w: 20, h: 20)
        guard case .stroke(let out)? = Geometry.transformItems([.stroke(s)], from: from, to: to).first else { return XCTFail() }
        XCTAssertEqual(out.points[0].x, 100, accuracy: 1e-9)
        XCTAssertEqual(out.points[1].x, 120, accuracy: 1e-9)
        XCTAssertEqual(out.size, 8, accuracy: 1e-9)
        XCTAssertEqual(out.points[0].pressure, 0.5)
    }

    func testTransformRotatesElementsAndScalesText() throws {
        let t = Make.text("t", x: 0, y: 0, w: 100, h: 20)
        let from = ItemFrame(x: 0, y: 0, w: 100, h: 20)
        let to = ItemFrame(x: 0, y: 0, w: 200, h: 40, rot: 0.3)
        guard case .element(let out)? = Geometry.transformItems([.element(t)], from: from, to: to).first,
              case .text(let tt) = out.content else { return XCTFail() }
        XCTAssertEqual(out.rotation, 0.3, accuracy: 1e-9)
        XCTAssertEqual(out.w, 200, accuracy: 1e-9)
        XCTAssertEqual(tt.fontSize, 40, accuracy: 1e-9)
    }

    func testTranslateMovesEverything() {
        let moved = Geometry.translateItems([.stroke(Make.stroke("a", points: [(1, 1), (2, 2)])), .element(Make.tape("t"))], dx: 5, dy: -1)
        guard case .stroke(let s) = moved[0], case .element(let e) = moved[1] else { return XCTFail() }
        XCTAssertEqual(s.points[0].x, 6)
        XCTAssertEqual(s.points[0].y, 0)
        XCTAssertEqual(e.x, 5)
    }

    func testTopItemPrefersTheNewest() {
        let under = PageItem.element(Make.shape("under", x: 0, y: 0, w: 100, h: 100, at: 1))
        let over = PageItem.element(Make.shape("over", x: 0, y: 0, w: 100, h: 100, at: 2))
        XCTAssertEqual(Geometry.topItemAt([under, over], 50, 50)?.id, "over")
        XCTAssertNil(Geometry.topItemAt([under, over], 500, 500))
    }

    // MARK: Eraser

    func testRubOutMarksPointsInsideTheCircle() throws {
        let pts = (0...10).map { StrokePoint(x: Double($0) * 10, y: 0, pressure: 0.5) }
        let r = try XCTUnwrap(Geometry.rubOut(pts, gone: [], cx: 50, cy: 0, r: 12))
        XCTAssertTrue(r.gone.contains(where: { r.pts[$0].x == 50 }))
        let segs = Geometry.survivingSegments(r.pts, gone: r.gone)
        XCTAssertEqual(segs.count, 2)
        XCTAssertLessThan(segs[0].last!.x, 50)
        XCTAssertGreaterThan(segs[1].first!.x, 50)
    }

    func testRubOutMissingEverythingReturnsNil() {
        let pts = [StrokePoint(x: 0, y: 0, pressure: 0.5), StrokePoint(x: 10, y: 0, pressure: 0.5)]
        XCTAssertNil(Geometry.rubOut(pts, gone: [], cx: 100, cy: 100, r: 5))
    }

    func testRubOutSplitsAStrokeCrossedBetweenSamples() throws {
        let pts = [StrokePoint(x: 0, y: 0, pressure: 0.5), StrokePoint(x: 100, y: 0, pressure: 0.5)]
        let r = try XCTUnwrap(Geometry.rubOut(pts, gone: [], cx: 50, cy: 0, r: 5))
        XCTAssertEqual(Geometry.survivingSegments(r.pts, gone: r.gone).count, 2)
    }

    func testSurvivingSegmentsDropsSinglePointRuns() {
        let pts = (0..<5).map { StrokePoint(x: Double($0), y: 0, pressure: 0.5) }
        let segs = Geometry.survivingSegments(pts, gone: [1, 3])
        XCTAssertTrue(segs.isEmpty) // runs of one point can't be drawn
        XCTAssertEqual(Geometry.survivingSegments(pts, gone: [4]).count, 1)
    }
}
