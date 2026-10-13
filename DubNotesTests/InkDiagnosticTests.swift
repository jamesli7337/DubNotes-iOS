import PencilKit
import UIKit
import XCTest
@testable import DubNotes

/// Diagnostic only: asserts nothing, prints how many strokes survive each way of building a PKDrawing, so the CI
/// log shows exactly where strokes vanish. Search the log for "[ink-diag]".
final class InkDiagnosticTests: XCTestCase {
    private func log(_ s: String) { print("[ink-diag] \(s)") }

    private func describe(_ label: String, _ d: PKDrawing) {
        let s: [PKStroke] = d.strokes
        let count: String = String(s.count)
        let bounds: String = String(describing: d.bounds)
        log(label + ": drawing.strokes.count=" + count + " bounds=" + bounds)
        for (i, pk) in s.enumerated() {
            let path: PKStrokePath = pk.path
            let pts: [PKStrokePoint] = Array(path)
            var parts: [String] = []
            parts.append("  [" + String(i) + "] ink=" + String(describing: pk.ink.inkType))
            parts.append("path.count=" + String(path.count))
            parts.append("start=" + String(path.startIndex))
            parts.append("end=" + String(path.endIndex))
            parts.append("arrayCount=" + String(pts.count))
            parts.append("first=" + String(describing: pts.first?.location))
            parts.append("last=" + String(describing: pts.last?.location))
            parts.append("transform=" + String(describing: pk.transform))
            parts.append("masks=" + String(pk.maskedPathRanges.count))
            parts.append("renderBounds=" + String(describing: pk.renderBounds))
            log(parts.joined(separator: " "))
        }
    }

    private func points(_ pts: [(Double, Double)], dt: TimeInterval, size: CGFloat, altitude: CGFloat) -> [PKStrokePoint] {
        var out: [PKStrokePoint] = []
        for (i, p) in pts.enumerated() {
            let location: CGPoint = CGPoint(x: p.0, y: p.1)
            let offset: TimeInterval = TimeInterval(i) * dt
            let dims: CGSize = CGSize(width: size, height: size)
            out.append(PKStrokePoint(location: location, timeOffset: offset, size: dims,
                                     opacity: 1, force: 0.5, azimuth: 0, altitude: altitude))
        }
        return out
    }

    func testDiagnosePencilKitConstruction() {
        let pen = Make.stroke("a", points: [(10, 10), (20, 14), (30, 10), (40, 14), (50, 10)], color: "#2563eb", size: 4, at: 1)
        let marker = Make.stroke("h", points: [(0, 0), (100, 0)], tool: .highlighter, color: "#fde047", size: 24)
        let dot = Make.stroke("dot", points: [(5, 5)])
        let paper = Paper.default

        // 1. what the converter does today
        for s in [pen, marker, dot] {
            var m: [String] = []
            m.append("model stroke " + s.id)
            m.append("tool=" + String(describing: s.tool))
            m.append("color=" + s.color)
            m.append("size=" + String(s.size))
            m.append("points=" + String(s.points.count))
            m.append("first=" + String(describing: s.points.first))
            m.append("createdAt=" + String(s.createdAt))
            log(m.joined(separator: " "))
            let pk = StrokeConverter.pkStroke(s, paper: paper)
            let builtCount: String = String(pk.path.count)
            let builtInk: String = String(describing: pk.ink.inkType)
            let builtBounds: String = String(describing: pk.renderBounds)
            log("  pkStroke built: path.count=" + builtCount + " ink=" + builtInk + " renderBounds=" + builtBounds)
            describe("  PKDrawing(strokes: [pkStroke])", PKDrawing(strokes: [pk]))
            describe("  StrokeConverter.drawing", StrokeConverter.drawing([s], paper: paper))
        }
        describe("converter, all three", StrokeConverter.drawing([pen, marker, dot], paper: paper))

        // 2. hand-built variants of the same pen stroke, to see which ones PencilKit keeps
        let raw: [(Double, Double)] = [(10, 10), (20, 14), (30, 10), (40, 14), (50, 10)]
        let ink = PKInk(.pen, color: UIColor.fromHex("#2563eb"))
        var dense: [(Double, Double)] = []
        for i in 0...60 {
            let x: Double = 10.0 + Double(i)
            let angle: Double = Double(i) / 4.0
            let y: Double = 10.0 + 4.0 * sin(angle)
            dense.append((x, y))
        }
        let halfPi: CGFloat = CGFloat.pi / 2
        let oldDate: Date = Date(timeIntervalSinceReferenceDate: 0.001)
        let nowDate: Date = Date()
        var variants: [Variant] = []
        variants.append(Variant(label: "5 pts dt=0.005 alt=pi/2 date=2001", pts: raw, dt: 0.005, altitude: halfPi, size: 4, date: oldDate))
        variants.append(Variant(label: "5 pts dt=0.005 alt=pi/2 date=now", pts: raw, dt: 0.005, altitude: halfPi, size: 4, date: nowDate))
        variants.append(Variant(label: "5 pts dt=0.02 alt=pi/2 date=now", pts: raw, dt: 0.02, altitude: halfPi, size: 4, date: nowDate))
        variants.append(Variant(label: "5 pts dt=0.02 alt=0 date=now", pts: raw, dt: 0.02, altitude: 0, size: 4, date: nowDate))
        variants.append(Variant(label: "5 pts dt=0.02 size=1 date=now", pts: raw, dt: 0.02, altitude: halfPi, size: 1, date: nowDate))
        variants.append(Variant(label: "61 pts dt=0.01 date=now", pts: dense, dt: 0.01, altitude: halfPi, size: 4, date: nowDate))
        variants.append(Variant(label: "61 pts dt=0.005 date=2001", pts: dense, dt: 0.005, altitude: halfPi, size: 4, date: oldDate))
        for v in variants {
            let controlPoints: [PKStrokePoint] = points(v.pts, dt: v.dt, size: v.size, altitude: v.altitude)
            let path = PKStrokePath(controlPoints: controlPoints, creationDate: v.date)
            let stroke = PKStroke(ink: ink, path: path)
            let countText: String = String(path.count)
            let boundsText: String = String(describing: stroke.renderBounds)
            log("variant " + v.label + ": path.count=" + countText + " renderBounds=" + boundsText)
            describe("  drawing", PKDrawing(strokes: [stroke]))
        }

        // 3. the round trip the app relies on
        let r = StrokeConverter.reconcile(StrokeConverter.drawing([pen, marker], paper: paper), baseline: [pen, marker],
                                          pageId: "p1", notebookId: "nb1", paper: paper, tool: .pen, nib: 4, now: 5000)
        let ids: [String] = r.strokes.map { $0.id }
        log("reconcile round trip: strokes=" + String(r.strokes.count) + " baseline=" + String(r.baseline.count) + " ids=" + ids.joined(separator: ","))
    }
}

private struct Variant {
    let label: String
    let pts: [(Double, Double)]
    let dt: TimeInterval
    let altitude: CGFloat
    let size: CGFloat
    let date: Date
}
