import PencilKit
import UIKit
import XCTest
@testable import DubNotes

/// Diagnostic only: asserts nothing, prints how many strokes survive each way of building a PKDrawing, so the CI
/// log shows exactly where strokes vanish. Search the log for "[ink-diag]".
final class InkDiagnosticTests: XCTestCase {
    private func log(_ s: String) { print("[ink-diag] \(s)") }

    private func describe(_ label: String, _ d: PKDrawing) {
        let s = d.strokes
        log("\(label): drawing.strokes.count=\(s.count) bounds=\(d.bounds)")
        for (i, pk) in s.enumerated() {
            let path = pk.path
            let pts = Array(path)
            log("  [\(i)] ink=\(pk.ink.inkType) path.count=\(path.count) start=\(path.startIndex) end=\(path.endIndex) arrayCount=\(pts.count) first=\(String(describing: pts.first?.location)) last=\(String(describing: pts.last?.location)) transform=\(pk.transform) masks=\(pk.maskedPathRanges.count) renderBounds=\(pk.renderBounds)")
        }
    }

    private func points(_ pts: [(Double, Double)], dt: TimeInterval, size: CGFloat, altitude: CGFloat) -> [PKStrokePoint] {
        pts.enumerated().map { i, p in
            PKStrokePoint(location: CGPoint(x: p.0, y: p.1), timeOffset: TimeInterval(i) * dt, size: CGSize(width: size, height: size),
                          opacity: 1, force: 0.5, azimuth: 0, altitude: altitude)
        }
    }

    func testDiagnosePencilKitConstruction() {
        let pen = Make.stroke("a", points: [(10, 10), (20, 14), (30, 10), (40, 14), (50, 10)], color: "#2563eb", size: 4, at: 1)
        let marker = Make.stroke("h", points: [(0, 0), (100, 0)], tool: .highlighter, color: "#fde047", size: 24)
        let dot = Make.stroke("dot", points: [(5, 5)])
        let paper = Paper.default

        // 1. what the converter does today
        for s in [pen, marker, dot] {
            log("model stroke \(s.id): tool=\(s.tool) color=\(s.color) size=\(s.size) points=\(s.points.count) first=\(String(describing: s.points.first)) createdAt=\(s.createdAt)")
            let pk = StrokeConverter.pkStroke(s, paper: paper)
            log("  pkStroke built: path.count=\(pk.path.count) ink=\(pk.ink.inkType) renderBounds=\(pk.renderBounds)")
            describe("  PKDrawing(strokes: [pkStroke])", PKDrawing(strokes: [pk]))
            describe("  StrokeConverter.drawing", StrokeConverter.drawing([s], paper: paper))
        }
        describe("converter, all three", StrokeConverter.drawing([pen, marker, dot], paper: paper))

        // 2. hand-built variants of the same pen stroke, to see which ones PencilKit keeps
        let raw: [(Double, Double)] = [(10, 10), (20, 14), (30, 10), (40, 14), (50, 10)]
        let ink = PKInk(.pen, color: UIColor.fromHex("#2563eb"))
        let dense: [(Double, Double)] = (0...60).map { (10 + Double($0), 10 + 4 * sin(Double($0) / 4)) }
        let variants: [(String, [(Double, Double)], TimeInterval, CGFloat, CGFloat, Date)] = [
            ("5 pts dt=0.005 alt=pi/2 date=2001", raw, 0.005, .pi / 2, 4, Date(timeIntervalSinceReferenceDate: 0.001)),
            ("5 pts dt=0.005 alt=pi/2 date=now", raw, 0.005, .pi / 2, 4, Date()),
            ("5 pts dt=0.02 alt=pi/2 date=now", raw, 0.02, .pi / 2, 4, Date()),
            ("5 pts dt=0.02 alt=0 date=now", raw, 0.02, 0, 4, Date()),
            ("5 pts dt=0.02 size=1 date=now", raw, 0.02, .pi / 2, 1, Date()),
            ("61 pts dt=0.01 date=now", dense, 0.01, .pi / 2, 4, Date()),
            ("61 pts dt=0.005 date=2001", dense, 0.005, .pi / 2, 4, Date(timeIntervalSinceReferenceDate: 0.001)),
        ]
        for (label, pts, dt, alt, size, date) in variants {
            let path = PKStrokePath(controlPoints: points(pts, dt: dt, size: size, altitude: alt), creationDate: date)
            let stroke = PKStroke(ink: ink, path: path)
            log("variant \(label): path.count=\(path.count) renderBounds=\(stroke.renderBounds)")
            describe("  drawing", PKDrawing(strokes: [stroke]))
        }

        // 3. the round trip the app relies on
        let r = StrokeConverter.reconcile(StrokeConverter.drawing([pen, marker], paper: paper), baseline: [pen, marker],
                                          pageId: "p1", notebookId: "nb1", paper: paper, tool: .pen, nib: 4, now: 5000)
        log("reconcile round trip: strokes=\(r.strokes.count) baseline=\(r.baseline.count) ids=\(r.strokes.map(\.id))")
    }
}
