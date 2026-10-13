import PencilKit
import UIKit

/// Converts between the stored `[x, y, pressure]` strokes and PencilKit strokes. PencilKit draws and edits the
/// ink; the model stays the source of truth, so a stroke the user did not touch is written back exactly as it
/// was loaded (same id, same points) and only new or changed strokes pass through the lossy direction.
enum StrokeConverter {
    /// perfect-freehand's pressure response for the pen (thinning 0.62): width = size * (1 + thinning * (p - 0.5)).
    static let thinning = 0.62

    static func widthFactor(pressure p: Double) -> Double { 1 + thinning * (p - 0.5) }

    static func pressure(widthFactor f: Double) -> Double { min(max(0.5 + (f - 1) / thinning, 0), 1) }

    static func inkType(_ tool: Stroke.Tool) -> PKInk.InkType { tool == .pen ? .pen : .marker }

    static func color(for s: Stroke, paper: Paper) -> UIColor {
        UIColor.fromHex(PaperStyle.resolve(s.color, on: paper))
    }

    // MARK: Model → PencilKit

    static func pkStroke(_ s: Stroke, paper: Paper) -> PKStroke {
        let ink = PKInk(inkType(s.tool), color: color(for: s, paper: paper))
        let start = Date(timeIntervalSinceReferenceDate: s.createdAt / 1000)
        var points: [PKStrokePoint] = []
        for (i, p) in s.points.enumerated() {
            let w = CGFloat(s.size * (s.tool == .pen ? widthFactor(pressure: p.pressure) : 1))
            points.append(PKStrokePoint(location: CGPoint(x: p.x, y: p.y), timeOffset: TimeInterval(i) * 0.005,
                                        size: CGSize(width: w, height: w), opacity: 1,
                                        force: CGFloat(p.pressure), azimuth: 0, altitude: .pi / 2))
        }
        if points.count == 1, let only = points.first {
            // a lone sample needs a second point to be a drawable stroke
            points.append(PKStrokePoint(location: CGPoint(x: only.location.x + 0.1, y: only.location.y + 0.1), timeOffset: 0.005,
                                        size: only.size, opacity: 1, force: only.force, azimuth: 0, altitude: .pi / 2))
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: start))
    }

    static func drawing(_ strokes: [Stroke], paper: Paper) -> PKDrawing {
        PKDrawing(strokes: strokes.map { pkStroke($0, paper: paper) })
    }

    /// Identifies a stroke by what PencilKit leaves alone under a lasso move or an eraser mask: the ink type and the
    /// untransformed path's length and end points. Colour is left out on purpose: PencilKit may re-encode it
    /// slightly, and a recolour goes through the model, not the canvas.
    static func signature(_ pk: PKStroke) -> String {
        let n = pk.path.count
        guard n > 0 else { return "empty" }
        let a = pk.path[0].location, b = pk.path[n - 1].location
        func r(_ v: CGFloat) -> String { String(format: "%.2f", Double(v)) }
        return "\(pk.ink.inkType)|\(n)|\(r(a.x)),\(r(a.y))|\(r(b.x)),\(r(b.y))"
    }

    /// The signature `signature(_:)` gives the PencilKit stroke built from `s`, computed without building it.
    static func signature(of s: Stroke, paper: Paper) -> String {
        guard let first = s.points.first, let last = s.points.last else { return "empty" }
        func r(_ v: Double) -> String { String(format: "%.2f", v) }
        // a lone sample becomes a two-point stroke offset by 0.1 (see pkStroke)
        let n = s.points.count == 1 ? 2 : s.points.count
        let end = s.points.count == 1 ? Pt(first.x + 0.1, first.y + 0.1) : Pt(last.x, last.y)
        return "\(inkType(s.tool))|\(n)|\(r(first.x)),\(r(first.y))|\(r(end.x)),\(r(end.y))"
    }

    // MARK: PencilKit → model
    struct Reconciled {
        /// The stroke list the model should now hold.
        var strokes: [Stroke]
        /// What the canvas's strokes were built from (untransformed), for matching the next edit.
        var baseline: [Stroke]
    }

    /// Rebuilds the stroke list from PencilKit's drawing after an edit.
    ///
    /// `baseline` is the stroke list the canvas drawing was built from (plus anything reconciled since).
    /// PencilKit keeps a stroke's original path and records moves, resizes and erase masks beside it, so each
    /// canvas stroke is matched back to its baseline original by signature. Untouched strokes keep their id and
    /// points exactly; moved, resized or partly erased ones get fresh ids (their pressure profile is kept);
    /// strokes PencilKit created itself are converted using `nib`, the current tool's size.
    static func reconcile(_ drawing: PKDrawing, baseline: [Stroke], pageId: String, notebookId: String,
                          paper: Paper, tool: Stroke.Tool, nib: Double, now: Double) -> Reconciled {
        var bySignature: [String: [Stroke]] = [:]
        for s in baseline { bySignature[signature(of: s, paper: paper), default: []].append(s) }
        var used = Set<String>()
        var model: [Stroke] = []
        var nextBaseline: [Stroke] = []
        var stamp = now

        for pk in drawing.strokes {
            let sig = signature(pk)
            let unchanged = pk.transform.isIdentity && pk.maskedPathRanges.isEmpty
            if let original = bySignature[sig]?.first(where: { !used.contains($0.id) }) {
                used.insert(original.id)
                nextBaseline.append(original)
                if unchanged {
                    model.append(original)
                } else {
                    model += derived(from: original, transform: pk.transform, masked: pk.maskedPathRanges, createdAt: original.createdAt)
                }
            } else if let original = bySignature[sig]?.first {
                // a duplicate of a stroke already matched (a copy made inside PencilKit)
                var twin = original
                twin.id = UUID().uuidString
                twin.createdAt = stamp
                nextBaseline.append(twin)
                model += derived(from: twin, transform: pk.transform, masked: pk.maskedPathRanges, createdAt: stamp,
                                 keepId: unchanged)
                stamp += 1
            } else {
                let s = fresh(pk, pageId: pageId, notebookId: notebookId, paper: paper, tool: tool, nib: nib, createdAt: stamp)
                nextBaseline.append(s)
                model.append(s)
                stamp += 1
            }
        }
        return Reconciled(strokes: model, baseline: nextBaseline)
    }

    /// A moved / resized / partly erased version of a known stroke, always under fresh ids.
    private static func derived(from original: Stroke, transform: CGAffineTransform, masked: [ClosedRange<CGFloat>],
                                createdAt: Double, keepId: Bool = false) -> [Stroke] {
        let scale = Double((transform.a * transform.a + transform.b * transform.b).squareRoot())
        var moved = original
        moved.size = original.size * (scale > 0 ? scale : 1)
        moved.createdAt = createdAt
        moved.points = original.points.map { p in
            let q = CGPoint(x: p.x, y: p.y).applying(transform)
            return StrokePoint(x: Double(q.x), y: Double(q.y), pressure: p.pressure)
        }
        if masked.isEmpty {
            if !keepId { moved.id = UUID().uuidString }
            return [moved]
        }
        // masked ranges are parametric positions along the path; control point i sits at parameter i
        var gone = Set<Int>()
        for i in 0..<moved.points.count where masked.contains(where: { $0.contains(CGFloat(i)) }) { gone.insert(i) }
        return Geometry.survivingSegments(moved.points, gone: gone).map { seg in
            var s = moved
            s.id = UUID().uuidString
            s.points = seg
            return s
        }
    }

    private static func fresh(_ pk: PKStroke, pageId: String, notebookId: String, paper: Paper,
                              tool: Stroke.Tool, nib: Double, createdAt: Double) -> Stroke {
        let scale = Double((pk.transform.a * pk.transform.a + pk.transform.b * pk.transform.b).squareRoot())
        let k = scale > 0 ? scale : 1
        let nominal = max(nib * k, 0.1)
        var pts: [StrokePoint] = []
        for i in 0..<pk.path.count {
            let p = pk.path[i]
            let loc = p.location.applying(pk.transform)
            let pressureValue = tool == .pen ? pressure(widthFactor: Double(p.size.width) * k / nominal) : 0.5
            pts.append(StrokePoint(x: Double(loc.x), y: Double(loc.y), pressure: pressureValue))
        }
        var hex = pk.ink.color.rgb.hex
        if tool == .pen && hex == PaperStyle.autoInk(paper.color) { hex = PaperStyle.autoColor }
        return Stroke(id: UUID().uuidString, pageId: pageId, notebookId: notebookId, tool: tool, color: hex,
                      size: nominal, points: pts, createdAt: createdAt)
    }
}
