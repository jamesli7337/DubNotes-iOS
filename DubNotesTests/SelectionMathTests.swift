import XCTest
@testable import DubNotes

final class SelectionMathTests: XCTestCase {
    private let frame = ItemFrame(x: 100, y: 100, w: 200, h: 100)

    // MARK: Which handles an item offers

    func testHandleSetsByItemKind() {
        XCTAssertEqual(SelectionStyle.style(for: [.element(Make.text("t"))]), SelectionStyle(rotate: true, aspect: true, edges: .horizontal))
        XCTAssertEqual(SelectionStyle.style(for: [.element(Make.shape("s"))]), SelectionStyle(rotate: true, aspect: false, edges: .all))
        let img = PageElement(id: "i", pageId: "p", notebookId: "n", x: 0, y: 0, w: 10, h: 10, createdAt: 1,
                              content: .image(PageElement.Image(src: "data:image/png;base64,AAAA")))
        XCTAssertEqual(SelectionStyle.style(for: [.element(img)]), SelectionStyle(rotate: true, aspect: true, edges: .all))
        XCTAssertEqual(SelectionStyle.style(for: [.stroke(Make.stroke("a"))]), SelectionStyle(rotate: false, aspect: true, edges: .none))
        XCTAssertEqual(SelectionStyle.style(for: [.element(Make.shape("a")), .element(Make.shape("b"))]),
                       SelectionStyle(rotate: false, aspect: true, edges: .none))
    }

    // MARK: Hit testing

    func testCornersWinOverTheBody() {
        let style = SelectionStyle(rotate: true, aspect: false, edges: .all)
        XCTAssertEqual(SelectionMath.handle(at: Pt(101, 101), frame: frame, style: style, hit: 10, gripOffset: 30), .corner(0))
        XCTAssertEqual(SelectionMath.handle(at: Pt(299, 199), frame: frame, style: style, hit: 10, gripOffset: 30), .corner(2))
        XCTAssertEqual(SelectionMath.handle(at: Pt(200, 101), frame: frame, style: style, hit: 10, gripOffset: 30), .edge(0))
        XCTAssertEqual(SelectionMath.handle(at: Pt(200, 150), frame: frame, style: style, hit: 10, gripOffset: 30), .move)
        XCTAssertNil(SelectionMath.handle(at: Pt(500, 500), frame: frame, style: style, hit: 10, gripOffset: 30))
    }

    func testTheRotateGripSitsAboveTheTopEdge() {
        let style = SelectionStyle(rotate: true, aspect: false, edges: .all)
        XCTAssertEqual(SelectionMath.handle(at: Pt(200, 70), frame: frame, style: style, hit: 10, gripOffset: 30), .rotate)
        let noRotate = SelectionStyle(rotate: false, aspect: true, edges: .none)
        XCTAssertNil(SelectionMath.handle(at: Pt(200, 70), frame: frame, style: noRotate, hit: 10, gripOffset: 30))
    }

    func testTextOffersOnlyLeftAndRightEdges() {
        let style = SelectionStyle(rotate: true, aspect: true, edges: .horizontal)
        XCTAssertEqual(SelectionMath.handle(at: Pt(299, 150), frame: frame, style: style, hit: 10, gripOffset: 30), .edge(1))
        XCTAssertEqual(SelectionMath.handle(at: Pt(200, 101), frame: frame, style: style, hit: 10, gripOffset: 30), .move) // no top handle
    }

    func testHandlesFollowARotatedFrame() {
        var f = frame
        f.rot = Double.pi / 2
        // the top-left corner of a frame turned a quarter about its centre (200, 150)
        let p = SelectionMath.pagePoint(f, .corner(0))
        XCTAssertEqual(p.x, 250, accuracy: 1e-9)
        XCTAssertEqual(p.y, 50, accuracy: 1e-9)
        let style = SelectionStyle(rotate: true, aspect: false, edges: .all)
        XCTAssertEqual(SelectionMath.handle(at: p, frame: f, style: style, hit: 5, gripOffset: 30), .corner(0))
    }

    // MARK: Resize

    func testDraggingTheBottomRightCornerAnchorsTheTopLeft() {
        let f = SelectionMath.resized(frame, handle: .corner(2), to: Pt(400, 300), aspect: false)
        XCTAssertEqual(f, ItemFrame(x: 100, y: 100, w: 300, h: 200))
    }

    func testDraggingTheTopLeftCornerAnchorsTheBottomRight() {
        let f = SelectionMath.resized(frame, handle: .corner(0), to: Pt(50, 50), aspect: false)
        XCTAssertEqual(f.x, 50, accuracy: 1e-9)
        XCTAssertEqual(f.y, 50, accuracy: 1e-9)
        XCTAssertEqual(f.w, 250, accuracy: 1e-9)
        XCTAssertEqual(f.h, 150, accuracy: 1e-9)
    }

    func testAspectLockKeepsTheRatioFromTheLargerChange() {
        let f = SelectionMath.resized(frame, handle: .corner(2), to: Pt(500, 210), aspect: true)
        XCTAssertEqual(f.w / f.h, 2, accuracy: 1e-9)
        XCTAssertEqual(f.w, 400, accuracy: 1e-9) // the x drag (to 500) was the larger relative change
        XCTAssertEqual(f.x, 100, accuracy: 1e-9)
        XCTAssertEqual(f.y, 100, accuracy: 1e-9)
    }

    func testEdgeHandlesResizeOneAxis() {
        let right = SelectionMath.resized(frame, handle: .edge(1), to: Pt(350, 999), aspect: false)
        XCTAssertEqual(right, ItemFrame(x: 100, y: 100, w: 250, h: 100))
        let top = SelectionMath.resized(frame, handle: .edge(0), to: Pt(0, 60), aspect: false)
        XCTAssertEqual(top, ItemFrame(x: 100, y: 60, w: 200, h: 140))
    }

    func testResizeNeverFlipsOrCollapses() {
        let f = SelectionMath.resized(frame, handle: .corner(2), to: Pt(10, 10), aspect: false) // past the anchor
        XCTAssertEqual(f.w, SelectionMath.minSide, accuracy: 1e-9)
        XCTAssertEqual(f.h, SelectionMath.minSide, accuracy: 1e-9)
        XCTAssertEqual(f.x, 100, accuracy: 1e-9)
        let left = SelectionMath.resized(frame, handle: .edge(3), to: Pt(900, 0), aspect: false)
        XCTAssertEqual(left.w, SelectionMath.minSide, accuracy: 1e-9)
        XCTAssertEqual(left.x + left.w, 300, accuracy: 1e-9) // the right edge stayed
    }

    func testResizingARotatedFrameKeepsItsAnchorCornerFixed() {
        var f = frame
        f.rot = 0.6
        let anchor = SelectionMath.pagePoint(f, .corner(0))
        // drag the bottom-right corner outwards along the frame's own axes
        let target = Geometry.rotateAround(400, 250, f.x + f.w / 2, f.y + f.h / 2, f.rot)
        let out = SelectionMath.resized(f, handle: .corner(2), to: target, aspect: false)
        XCTAssertEqual(out.rot, 0.6, accuracy: 1e-9)
        let anchorAfter = SelectionMath.pagePoint(out, .corner(0))
        XCTAssertEqual(anchorAfter.x, anchor.x, accuracy: 1e-6)
        XCTAssertEqual(anchorAfter.y, anchor.y, accuracy: 1e-6)
        XCTAssertGreaterThan(out.w, f.w)
    }

    // MARK: Rotate, move

    func testRotationSnapsToFifteenDegreesWhenClose() {
        // pointer straight above the centre: the frame is upright
        let up = SelectionMath.rotated(frame, to: Pt(200, 0))
        XCTAssertEqual(up.rot, 0, accuracy: 1e-9)
        // pointer to the right of the centre: a quarter turn
        let right = SelectionMath.rotated(frame, to: Pt(500, 150))
        XCTAssertEqual(right.rot, Double.pi / 2, accuracy: 1e-9)
        // 2° off 45° still snaps; 8° off does not
        func angle(_ deg: Double) -> Double {
            let a = (deg - 90) * Double.pi / 180
            return SelectionMath.rotated(frame, to: Pt(200 + 100 * cos(a), 150 + 100 * sin(a))).rot
        }
        XCTAssertEqual(angle(47), 45 * Double.pi / 180, accuracy: 1e-9)
        XCTAssertEqual(angle(53), 53 * Double.pi / 180, accuracy: 1e-6)
    }

    func testMove() {
        XCTAssertEqual(SelectionMath.moved(frame, dx: 5, dy: -7), ItemFrame(x: 105, y: 93, w: 200, h: 100))
    }
}
