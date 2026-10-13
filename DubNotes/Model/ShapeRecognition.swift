import Foundation

/// Geometry of a shape fitted to a hand-drawn stroke (page units). Port of recognize.ts / recognize-shape.ts.
struct ShapeFit: Equatable {
    var shape: PageElement.Shape.Kind
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var rotation: Double
    /// Polygon vertices as fractions of the box (triangle only).
    var pts: [[Double]]?
}

/// Pen-lift shape snapping: a straight line first, then a closed shape (rectangle, ellipse, triangle).
/// Every screen-px constant is divided by `zoom` before use so the same-looking shape snaps the same way
/// at any zoom.
enum ShapeRecognition {
    static func recognize(_ pts: [Pt], nib: Double, zoom: Double) -> ShapeFit? {
        recognizeLine(pts, nib: nib, zoom: zoom) ?? recognizeClosed(pts, zoom: zoom)
    }

    // MARK: Lines

    /// Box height given to a line so it stays tappable; the line itself is drawn on the centre-line.
    static let lineBoxH = 14.0
    private static let minTotalLen = 30.0
    private static let minChord = 20.0
    private static let minDeviationFloor = 5.0
    /// How far a stroke may bow off its chord and still be straight, as a fraction of the chord.
    private static let maxBow = 0.09

    private static func dist(_ a: Pt, _ b: Pt) -> Double { Geometry.dist(a, b) }

    private static func pathLength(_ pts: [Pt]) -> Double {
        var l = 0.0
        if pts.count > 1 { for i in 1..<pts.count { l += dist(pts[i - 1], pts[i]) } }
        return l
    }

    private static func chordDeviation(_ pts: [Pt]) -> Double {
        guard let a = pts.first, let b = pts.last else { return .infinity }
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        if len < 1e-6 { return .infinity }
        var m = 0.0
        for p in pts { m = max(m, abs((p.x - a.x) * dy - (p.y - a.y) * dx) / len) }
        return m
    }

    private static func isStraight(_ pts: [Pt], zoom: Double) -> Bool {
        guard pts.count >= 2, let first = pts.first, let last = pts.last else { return false }
        let chord = dist(first, last)
        return chord >= minChord / zoom && chordDeviation(pts) <= max(maxBow * chord, minDeviationFloor / zoom)
    }

    /// The line element box between two endpoints, `nib` being the stroke width.
    static func lineFit(_ kind: PageElement.Shape.Kind, _ a: Pt, _ b: Pt, nib: Double) -> ShapeFit {
        let len = dist(a, b)
        let h = max(nib * 2, lineBoxH)
        let cx = (a.x + b.x) / 2, cy = (a.y + b.y) / 2
        return ShapeFit(shape: kind, x: cx - len / 2, y: cy - h / 2, w: len, h: h,
                        rotation: atan2(b.y - a.y, b.x - a.x), pts: nil)
    }

    /// Fits a straight line to a stroke or returns nil (curve, corner, loop, ordinary writing).
    static func recognizeLine(_ pts: [Pt], nib: Double, zoom: Double) -> ShapeFit? {
        if pts.count < 6 { return nil }
        if pathLength(pts) < minTotalLen / zoom { return nil }
        let start = pts[0]
        var tipIndex = 0
        var tipDist = 0.0
        for i in 0..<pts.count {
            let d = dist(start, pts[i])
            if d > tipDist { tipDist = d; tipIndex = i }
        }
        let tip = pts[tipIndex]
        let shaft = Array(pts[0...tipIndex])
        let tail = Array(pts[tipIndex...])
        if !isStraight(shaft, zoom: zoom) { return nil }
        if pathLength(tail) > max(0.08 * pathLength(shaft), nib) { return nil }
        return lineFit(.line, start, tip, nib: nib)
    }

    // MARK: Closed shapes

    private static let deg = Double.pi / 180
    private static let minPoints = 12
    private static let minLen = 80.0
    private static let minSize = 24.0
    private static let maxGap = 0.25
    private static let acceptError = 0.08
    private static let enclosedMin = 0.6
    private static let resampleN = 64
    private static let rectAngleStep = 5 * deg
    private static let rectRefineStep = 1 * deg
    private static let axisSnap = 15 * deg
    private static let ellipseMinAspect = 0.15
    private static let circleAspect = 0.1
    private static let minTriAngle = 15 * deg
    private static let rightSnap = 18 * deg
    private static let triMaxCandidates = 8
    private static let triStartEps = 0.01
    private static let triEpsGrowth = 1.5

    private static func distToChord(_ p: Pt, _ a: Pt, _ b: Pt) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        if len < 1e-9 { return dist(p, a) }
        return abs((p.x - a.x) * dy - (p.y - a.y) * dx) / len
    }

    private static func distToSegment(_ p: Pt, _ a: Pt, _ b: Pt) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 < 1e-9 { return dist(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Douglas-Peucker over ring[i0...i1], adding the indices of the points it keeps.
    private static func simplify(_ ring: [Pt], _ i0: Int, _ i1: Int, _ eps: Double, _ keep: inout Set<Int>) {
        var stack: [(Int, Int)] = [(i0, i1)]
        while let (a, b) = stack.popLast() {
            var worst = -1
            var worstD = 0.0
            if a + 1 < b {
                for i in (a + 1)..<b {
                    let d = distToChord(ring[i], ring[a], ring[b])
                    if d > worstD { worstD = d; worst = i }
                }
            }
            if worst >= 0 && worstD > eps {
                keep.insert(worst)
                stack.append((a, worst))
                stack.append((worst, b))
            }
        }
    }

    private static func interiorAngle(_ prev: Pt, _ cur: Pt, _ next: Pt) -> Double {
        let ax = prev.x - cur.x, ay = prev.y - cur.y
        let bx = next.x - cur.x, by = next.y - cur.y
        let m = hypot(ax, ay) * hypot(bx, by)
        if m < 1e-9 { return 0 }
        return acos(max(-1, min(1, (ax * bx + ay * by) / m)))
    }

    /// Twice the enclosed area of the implicitly closed polygon (shoelace), signed.
    private static func shoelace2(_ pts: [Pt]) -> Double {
        var sum = 0.0
        var j = pts.count - 1
        for i in 0..<pts.count {
            sum += (pts[j].x - pts[i].x) * (pts[j].y + pts[i].y)
            j = i
        }
        return sum
    }

    /// `n` points evenly spaced by arc length along a polyline.
    private static func resample(_ ring: [Pt], _ total: Double, _ n: Int) -> [Pt] {
        var out: [Pt] = []
        let step = total / Double(n)
        var seg = 1
        var segStart = 0.0
        var segLen = dist(ring[0], ring[1])
        for k in 0..<n {
            let target = Double(k) * step
            while seg < ring.count - 1 && segStart + segLen < target {
                segStart += segLen
                seg += 1
                segLen = dist(ring[seg - 1], ring[seg])
            }
            let t = segLen > 1e-9 ? min(1, max(0, (target - segStart) / segLen)) : 0
            let a = ring[seg - 1], b = ring[seg]
            out.append(Pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
        }
        return out
    }

    // MARK: Scoring

    /// The four corners (top-left, top-right, bottom-right, bottom-left) of a box fit, or a triangle's vertices.
    static func shapeHandles(_ fit: ShapeFit) -> [Pt] {
        if fit.shape == .triangle {
            let p = fit.pts ?? [[0.5, 0], [1, 1], [0, 1]]
            return p.map { Pt(fit.x + $0[0] * fit.w, fit.y + $0[1] * fit.h) }
        }
        let cx = fit.x + fit.w / 2, cy = fit.y + fit.h / 2
        let c = cos(fit.rotation), s = sin(fit.rotation)
        return [(-fit.w / 2, -fit.h / 2), (fit.w / 2, -fit.h / 2), (fit.w / 2, fit.h / 2), (-fit.w / 2, fit.h / 2)]
            .map { Pt(cx + $0.0 * c - $0.1 * s, cy + $0.0 * s + $0.1 * c) }
    }

    private static func outlineDistance(_ fit: ShapeFit) -> (Pt) -> Double {
        if fit.shape == .triangle {
            let v = shapeHandles(fit)
            return { p in min(distToSegment(p, v[0], v[1]), distToSegment(p, v[1], v[2]), distToSegment(p, v[2], v[0])) }
        }
        let cx = fit.x + fit.w / 2, cy = fit.y + fit.h / 2
        let hw = fit.w / 2, hh = fit.h / 2
        let c = cos(fit.rotation), s = sin(fit.rotation)
        if fit.shape == .rect {
            return { p in
                let dx = p.x - cx, dy = p.y - cy
                let du = hw - abs(dx * c + dy * s)
                let dv = hh - abs(-dx * s + dy * c)
                return du >= 0 && dv >= 0 ? min(du, dv) : hypot(max(-du, 0), max(-dv, 0))
            }
        }
        return { p in
            let dx = p.x - cx, dy = p.y - cy
            let u = dx * c + dy * s
            let v = -dx * s + dy * c
            let r = hypot(u, v)
            if r < 1e-9 { return min(hw, hh) }
            let rho = hypot(u / hw, v / hh)
            return r * abs(1 - 1 / rho)
        }
    }

    private static func meanError(_ fit: ShapeFit, _ s: [Pt]) -> Double {
        if fit.w < 1e-6 || fit.h < 1e-6 { return .infinity }
        let d = outlineDistance(fit)
        var t = 0.0
        for p in s { t += d(p) }
        return t / Double(s.count)
    }

    private static func fitArea(_ fit: ShapeFit) -> Double {
        if fit.shape == .rect { return fit.w * fit.h }
        if fit.shape == .ellipse { return Double.pi * fit.w * fit.h / 4 }
        return abs(shoelace2(shapeHandles(fit))) / 2
    }

    private static func recognizeClosed(_ pts: [Pt], zoom: Double) -> ShapeFit? {
        let n = pts.count
        if n < minPoints { return nil }
        let ring = pts + [pts[0]]
        var total = 0.0
        for i in 1..<ring.count { total += dist(ring[i - 1], ring[i]) }
        if total < minLen / zoom { return nil }
        if dist(pts[0], pts[n - 1]) > maxGap * total { return nil }

        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for p in pts {
            x0 = min(x0, p.x); x1 = max(x1, p.x)
            y0 = min(y0, p.y); y1 = max(y1, p.y)
        }
        let minS = minSize / zoom
        if x1 - x0 < minS || y1 - y0 < minS { return nil }

        let s = resample(ring, total, resampleN)
        let size = ((x1 - x0) * (y1 - y0)).squareRoot()
        let enclosed = abs(shoelace2(s)) / 2

        var best: ShapeFit?
        var bestErr = Double.infinity
        let candidates: [ShapeFit?] = [fitRect(s), fitEllipse(s), fitTriangle(ring, total, s, zoom)]
        for case let fit? in candidates {
            if enclosed < enclosedMin * fitArea(fit) { continue }
            let err = meanError(fit, s) / size
            if err < bestErr { bestErr = err; best = fit }
        }
        if let b = best, bestErr <= acceptError { return b }
        return nil
    }

    // MARK: Candidates

    private static func boxAt(_ s: [Pt], _ rot: Double) -> ShapeFit {
        let c = cos(rot), sn = sin(rot)
        var u0 = Double.infinity, v0 = Double.infinity, u1 = -Double.infinity, v1 = -Double.infinity
        for p in s {
            let u = p.x * c + p.y * sn
            let v = -p.x * sn + p.y * c
            u0 = min(u0, u); u1 = max(u1, u)
            v0 = min(v0, v); v1 = max(v1, v)
        }
        let w = u1 - u0, h = v1 - v0
        let cu = (u0 + u1) / 2, cv = (v0 + v1) / 2
        let cx = cu * c - cv * sn
        let cy = cu * sn + cv * c
        return ShapeFit(shape: .rect, x: cx - w / 2, y: cy - h / 2, w: w, h: h, rotation: rot, pts: nil)
    }

    private static func fitRect(_ s: [Pt]) -> ShapeFit? {
        var bestRot = 0.0
        var bestErr = Double.infinity
        func tryRot(_ rot: Double) {
            let err = meanError(boxAt(s, rot), s)
            if err < bestErr { bestErr = err; bestRot = rot }
        }
        var r = -Double.pi / 4
        while r < Double.pi / 4 { tryRot(r); r += rectAngleStep }
        let coarse = bestRot
        r = coarse - rectAngleStep
        while r <= coarse + rectAngleStep { tryRot(r); r += rectRefineStep }
        if !bestErr.isFinite { return nil }
        return boxAt(s, abs(bestRot) < axisSnap ? 0 : bestRot)
    }

    private static func fitEllipse(_ s: [Pt]) -> ShapeFit? {
        var mx = 0.0, my = 0.0
        for p in s { mx += p.x; my += p.y }
        mx /= Double(s.count); my /= Double(s.count)
        var cxx = 0.0, cyy = 0.0, cxy = 0.0
        for p in s {
            let dx = p.x - mx, dy = p.y - my
            cxx += dx * dx; cyy += dy * dy; cxy += dx * dy
        }
        let n = Double(s.count)
        cxx /= n; cyy /= n; cxy /= n
        var theta = 0.5 * atan2(2 * cxy, cxx - cyy)
        let mean = (cxx + cyy) / 2
        let diff = hypot((cxx - cyy) / 2, cxy)
        var a = (2 * (mean + diff)).squareRoot()
        var b = (2 * max(0, mean - diff)).squareRoot()
        if a < 1e-6 || b < ellipseMinAspect * a { return nil }

        let c = cos(theta), sn = sin(theta)
        var avg = 0.0
        for p in s {
            let u = (p.x - mx) * c + (p.y - my) * sn
            let v = -(p.x - mx) * sn + (p.y - my) * c
            avg += hypot(u / a, v / b)
        }
        avg /= n
        a *= avg
        b *= avg

        if abs(a - b) / max(a, b) < circleAspect {
            let r = (a + b) / 2
            return ShapeFit(shape: .ellipse, x: mx - r, y: my - r, w: r * 2, h: r * 2, rotation: 0, pts: nil)
        }
        if abs(theta) < axisSnap {
            theta = 0
        } else if abs(abs(theta) - Double.pi / 2) < axisSnap {
            theta = 0
            swap(&a, &b)
        }
        return ShapeFit(shape: .ellipse, x: mx - a, y: my - b, w: a * 2, h: b * 2, rotation: theta, pts: nil)
    }

    private static func triangleFit(_ v: [Pt]) -> ShapeFit {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for p in v {
            x0 = min(x0, p.x); x1 = max(x1, p.x)
            y0 = min(y0, p.y); y1 = max(y1, p.y)
        }
        let w = max(x1 - x0, 1), h = max(y1 - y0, 1)
        return ShapeFit(shape: .triangle, x: x0, y: y0, w: w, h: h, rotation: 0,
                        pts: v.map { [($0.x - x0) / w, ($0.y - y0) / h] })
    }

    private static func cornerCandidates(_ ring: [Pt], _ total: Double) -> [Int] {
        let last = ring.count - 1
        var far = 0
        var farD = 0.0
        if last > 1 {
            for i in 1..<last {
                let d = dist(ring[0], ring[i])
                if d > farD { farD = d; far = i }
            }
        }
        if far == 0 { return [] }
        var eps = triStartEps * total
        for _ in 0..<16 {
            var keep: Set<Int> = [0, far, last]
            simplify(ring, 0, far, eps, &keep)
            simplify(ring, far, last, eps, &keep)
            var idx = keep.sorted()
            idx.removeLast() // the closing duplicate of index 0
            if idx.count <= triMaxCandidates { return idx }
            eps *= triEpsGrowth
        }
        return []
    }

    /// A corner within `rightSnap` of 90 degrees is made exactly square; the triangle is then axis-aligned if close.
    private static func snapRight(_ v: [Pt]) -> [Pt] {
        let ang = (0..<3).map { k in interiorAngle(v[(k + 2) % 3], v[k], v[(k + 1) % 3]) }
        var right = -1
        var rightOff = rightSnap
        for k in 0..<3 {
            let off = abs(ang[k] - Double.pi / 2)
            if off <= rightOff { rightOff = off; right = k }
        }
        if right < 0 { return v }
        let c = v[right]
        let a = v[(right + 2) % 3]
        let bi = (right + 1) % 3
        let b = v[bi]
        let ul = dist(a, c)
        if ul < 1e-9 { return v }
        let nx = -(a.y - c.y) / ul
        let ny = (a.x - c.x) / ul
        let side: Double = (b.x - c.x) * nx + (b.y - c.y) * ny >= 0 ? 1 : -1
        let len = dist(b, c)
        var out = v
        out[bi] = Pt(c.x + nx * side * len, c.y + ny * side * len)

        let quarter = Double.pi / 2
        let raw = atan2(a.y - c.y, a.x - c.x) + quarter / 2
        let tilt = (raw.truncatingRemainder(dividingBy: quarter) + quarter).truncatingRemainder(dividingBy: quarter) - quarter / 2
        if abs(tilt) <= axisSnap {
            let cs = cos(-tilt), sn = sin(-tilt)
            return out.map { p in
                Pt(c.x + (p.x - c.x) * cs - (p.y - c.y) * sn, c.y + (p.x - c.x) * sn + (p.y - c.y) * cs)
            }
        }
        return out
    }

    private static func fitTriangle(_ ring: [Pt], _ total: Double, _ s: [Pt], _ zoom: Double) -> ShapeFit? {
        let cand = cornerCandidates(ring, total)
        if cand.count < 3 { return nil }
        let minS = minSize / zoom
        var best: [Pt]?
        var bestErr = Double.infinity
        for i in 0..<(cand.count - 2) {
            for j in (i + 1)..<(cand.count - 1) {
                for k in (j + 1)..<cand.count {
                    let v = [ring[cand[i]], ring[cand[j]], ring[cand[k]]]
                    var smallest = Double.infinity
                    for q in 0..<3 { smallest = min(smallest, interiorAngle(v[(q + 2) % 3], v[q], v[(q + 1) % 3])) }
                    if smallest < minTriAngle { continue }
                    let fit = triangleFit(v)
                    if fit.w < minS || fit.h < minS { continue }
                    let err = meanError(fit, s)
                    if err < bestErr { bestErr = err; best = v }
                }
            }
        }
        guard let b = best else { return nil }
        return triangleFit(snapRight(b))
    }
}
