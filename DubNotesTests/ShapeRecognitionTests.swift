import XCTest
@testable import DubNotes

final class ShapeRecognitionTests: XCTestCase {
    private func recognize(_ pts: [Pt], nib: Double = 4, zoom: Double = 1) -> ShapeFit? {
        ShapeRecognition.recognize(pts, nib: nib, zoom: zoom)
    }

    func testStraightLineSnaps() throws {
        var pts: [Pt] = []
        for i in 0...30 {
            let x: Double = Double(i) * 10.0
            let y: Double = 100.0 + Double(i) * 0.5
            pts.append(Pt(x, y))
        }
        let fit = try XCTUnwrap(recognize(pts))
        XCTAssertEqual(fit.shape, .line)
        XCTAssertEqual(fit.w, Geometry.dist(try item(pts, 0), try item(pts, 30)), accuracy: 0.5)
    }

    func testLineEndpointsRoundTripThroughTheFit() throws {
        let a = Pt(20, 30), b = Pt(220, 130)
        let fit = ShapeRecognition.lineFit(.line, a, b, nib: 3)
        XCTAssertEqual(fit.rotation, atan2(100, 200), accuracy: 1e-9)
        XCTAssertEqual(fit.x + fit.w / 2, 120, accuracy: 1e-9)
        XCTAssertEqual(fit.y + fit.h / 2, 80, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(fit.h, ShapeRecognition.lineBoxH)
    }

    func testAShortDashIsNotALine() {
        let pts = (0...8).map { Pt(Double($0) * 2, 0) }
        XCTAssertNil(recognize(pts))
    }

    func testAGentleCurveIsNotALine() {
        // a quarter circle bows far past 9% of its chord
        var pts: [Pt] = []
        for i in 0...40 {
            let a: Double = Double(i) / 40.0 * Double.pi / 2.0
            pts.append(Pt(100.0 * cos(a), 100.0 * sin(a)))
        }
        XCTAssertNotEqual(recognize(pts)?.shape, .line)
    }

    func testCircleSnapsToACircle() throws {
        let fit = try XCTUnwrap(recognize(Make.circle(cx: 200, cy: 300, r: 80)))
        XCTAssertEqual(fit.shape, .ellipse)
        XCTAssertEqual(fit.w, fit.h, accuracy: 1e-6) // within the circle tolerance it is made round
        XCTAssertEqual(fit.x + fit.w / 2, 200, accuracy: 4)
        XCTAssertEqual(fit.y + fit.h / 2, 300, accuracy: 4)
        XCTAssertEqual(fit.w / 2, 80, accuracy: 6)
    }

    func testWideEllipseKeepsItsAspect() throws {
        var pts: [Pt] = []
        for unit in Make.circle(cx: 300, cy: 300, r: 1) {
            let dx: Double = unit.x - 300.0
            let dy: Double = unit.y - 300.0
            pts.append(Pt(300.0 + dx * 120.0, 300.0 + dy * 50.0))
        }
        let fit = try XCTUnwrap(recognize(pts))
        XCTAssertEqual(fit.shape, .ellipse)
        XCTAssertGreaterThan(fit.w, fit.h * 2)
    }

    func testRectangleSnapsAndSquaresUp() throws {
        let corners = [Pt(100, 100), Pt(300, 104), Pt(298, 220), Pt(98, 216)] // slightly skewed by hand
        let fit = try XCTUnwrap(recognize(Make.polygon(corners)))
        XCTAssertEqual(fit.shape, .rect)
        XCTAssertEqual(fit.rotation, 0, accuracy: 1e-9) // within 15° of the axes: laid on them
        XCTAssertEqual(fit.w, 200, accuracy: 12)
        XCTAssertEqual(fit.h, 116, accuracy: 12)
    }

    func testTriangleSnapsWithThreeVertices() throws {
        let corners = [Pt(200, 100), Pt(320, 300), Pt(80, 300)]
        let fit = try XCTUnwrap(recognize(Make.polygon(corners)))
        XCTAssertEqual(fit.shape, .triangle)
        XCTAssertEqual(fit.pts?.count, 3)
        let v = ShapeRecognition.shapeHandles(fit)
        XCTAssertEqual(v.count, 3)
    }

    func testAWaveLikeHandwritingDoesNotSnap() {
        // far from straight, and its ends are nowhere near each other, so it is neither a line nor a closed shape
        var pts: [Pt] = []
        for i in 0...60 {
            let x: Double = Double(i) * 5.0
            let y: Double = 40.0 * sin(Double(i) * 0.25)
            pts.append(Pt(x, y))
        }
        XCTAssertNil(recognize(pts))
    }

    func testSmallClosedScribbleIsLeftAlone() {
        XCTAssertNil(recognize(Make.circle(cx: 10, cy: 10, r: 6)))
    }

    func testThresholdsScaleWithZoom() {
        // a 40-unit stroke is long enough at 100% but a short flick when zoomed out to 25%
        let pts = (0...12).map { Pt(Double($0) * 3.4, 0) }
        XCTAssertNotNil(recognize(pts, zoom: 1))
        XCTAssertNil(recognize(pts, zoom: 0.25))
    }

    func testNoPointsNoShape() {
        XCTAssertNil(recognize([]))
        XCTAssertNil(recognize([Pt(1, 1)]))
    }
}
