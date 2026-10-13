import Foundation

/// A point in page units. Geometry code works on these rather than `CGPoint` so it stays plain Foundation.
struct Pt: Equatable {
    var x: Double
    var y: Double
    init(_ x: Double, _ y: Double) { self.x = x; self.y = y }
}

struct PageRect: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
}

/// A selection frame: a box that may be rotated (radians) about its centre.
struct ItemFrame: Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var rot: Double

    init(x: Double, y: Double, w: Double, h: Double, rot: Double = 0) {
        self.x = x; self.y = y; self.w = w; self.h = h; self.rot = rot
    }
}

/// Anything that can sit on a page: ink or a box element.
enum PageItem: Equatable {
    case stroke(Stroke)
    case element(PageElement)

    var id: String {
        switch self {
        case .stroke(let s): return s.id
        case .element(let e): return e.id
        }
    }

    var pageId: String {
        switch self {
        case .stroke(let s): return s.pageId
        case .element(let e): return e.pageId
        }
    }

    var createdAt: Double {
        switch self {
        case .stroke(let s): return s.createdAt
        case .element(let e): return e.createdAt
        }
    }

    var isStroke: Bool {
        if case .stroke = self { return true }
        return false
    }
}

extension Stroke {
    var pts: [Pt] { points.map { Pt($0.x, $0.y) } }
}

enum Geometry {
    // MARK: Basics

    static func dist(_ a: Pt, _ b: Pt) -> Double { hypot(a.x - b.x, a.y - b.y) }

    static func rotateAround(_ x: Double, _ y: Double, _ cx: Double, _ cy: Double, _ ang: Double) -> Pt {
        if ang == 0 { return Pt(x, y) }
        let c = cos(ang), s = sin(ang)
        let dx = x - cx, dy = y - cy
        return Pt(cx + dx * c - dy * s, cy + dx * s + dy * c)
    }

    /// Ray-casting point-in-polygon; the last edge back to the first is implicit.
    static func pointInPolygon(_ x: Double, _ y: Double, _ poly: [Pt]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let xi = poly[i].x, yi = poly[i].y
            let xj = poly[j].x, yj = poly[j].y
            if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }

    static func distToSegmentSq(_ px: Double, _ py: Double, _ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Double {
        let dx = bx - ax, dy = by - ay
        let len2 = dx * dx + dy * dy
        var t = len2 > 0 ? ((px - ax) * dx + (py - ay) * dy) / len2 : 0
        t = min(max(t, 0), 1)
        let cx = ax + t * dx, cy = ay + t * dy
        return (px - cx) * (px - cx) + (py - cy) * (py - cy)
    }

    /// True if (x, y) is within `tol` of the polyline `pts`.
    static func nearPolyline(_ x: Double, _ y: Double, _ pts: [Pt], _ tol: Double) -> Bool {
        let t2 = tol * tol
        for i in 0..<pts.count {
            let a = pts[i]
            if (x - a.x) * (x - a.x) + (y - a.y) * (y - a.y) <= t2 { return true }
            if i + 1 < pts.count {
                let b = pts[i + 1]
                if distToSegmentSq(x, y, a.x, a.y, b.x, b.y) <= t2 { return true }
            }
        }
        return false
    }

    // MARK: Elements

    static func elementCenter(_ el: PageElement) -> Pt { Pt(el.x + el.w / 2, el.y + el.h / 2) }

    static func elementCorners(_ el: PageElement) -> [Pt] {
        let c = elementCenter(el)
        let raw = [Pt(el.x, el.y), Pt(el.x + el.w, el.y), Pt(el.x + el.w, el.y + el.h), Pt(el.x, el.y + el.h)]
        return raw.map { rotateAround($0.x, $0.y, c.x, c.y, el.rotation) }
    }

    static func pointInElement(_ el: PageElement, _ x: Double, _ y: Double) -> Bool {
        let c = elementCenter(el)
        let l = rotateAround(x, y, c.x, c.y, -el.rotation)
        return l.x >= el.x && l.x <= el.x + el.w && l.y >= el.y && l.y <= el.y + el.h
    }

    /// True when (x, y) is within `tol` of a shape's drawn outline (not its interior).
    static func nearShapeOutline(_ el: PageElement, _ shape: PageElement.Shape, _ x: Double, _ y: Double, _ tol: Double) -> Bool {
        let c = elementCenter(el)
        let l = rotateAround(x, y, c.x, c.y, -el.rotation)
        if l.x < el.x - tol || l.x > el.x + el.w + tol || l.y < el.y - tol || l.y > el.y + el.h + tol { return false }
        var outline: [Pt]
        switch shape.shape {
        case .line, .arrow:
            outline = [Pt(el.x, c.y), Pt(el.x + el.w, c.y)]
        case .triangle:
            let pts = shape.pts ?? [[0.5, 0], [1, 1], [0, 1]]
            outline = pts.map { Pt(el.x + $0[0] * el.w, el.y + $0[1] * el.h) }
            if let first = outline.first { outline.append(first) }
        case .ellipse:
            let n = 48
            outline = (0...n).map { i in
                let a = Double(i) / Double(n) * Double.pi * 2
                return Pt(c.x + el.w / 2 * cos(a), c.y + el.h / 2 * sin(a))
            }
        case .rect:
            outline = [Pt(el.x, el.y), Pt(el.x + el.w, el.y), Pt(el.x + el.w, el.y + el.h), Pt(el.x, el.y + el.h), Pt(el.x, el.y)]
        }
        return nearPolyline(l.x, l.y, outline, tol)
    }

    // MARK: Bounds and frames

    static func aabb(_ pts: [Pt], pad: Double = 0) -> PageRect {
        guard !pts.isEmpty else { return PageRect(x: 0, y: 0, w: 0, h: 0) }
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for p in pts {
            x0 = min(x0, p.x); x1 = max(x1, p.x)
            y0 = min(y0, p.y); y1 = max(y1, p.y)
        }
        return PageRect(x: x0 - pad, y: y0 - pad, w: x1 - x0 + pad * 2, h: y1 - y0 + pad * 2)
    }

    static func itemBounds(_ item: PageItem) -> PageRect {
        switch item {
        case .stroke(let s): return aabb(s.pts, pad: s.size / 2)
        case .element(let e): return aabb(elementCorners(e))
        }
    }

    static func unionRects(_ rects: [PageRect]) -> PageRect? {
        guard !rects.isEmpty else { return nil }
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        for r in rects {
            x0 = min(x0, r.x); y0 = min(y0, r.y)
            x1 = max(x1, r.x + r.w); y1 = max(y1, r.y + r.h)
        }
        return PageRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)
    }

    /// The frame a selection is edited through. A single element keeps its own (possibly rotated) box.
    static func itemsFrame(_ items: [PageItem]) -> ItemFrame? {
        if items.count == 1, case .element(let e) = items[0] {
            return ItemFrame(x: e.x, y: e.y, w: e.w, h: e.h, rot: e.rotation)
        }
        guard let r = unionRects(items.map(itemBounds)) else { return nil }
        return ItemFrame(x: r.x, y: r.y, w: r.w, h: r.h, rot: 0)
    }

    /// The frame's four corners on the page, rotation applied.
    static func frameCorners(_ f: ItemFrame) -> [Pt] {
        let cx = f.x + f.w / 2, cy = f.y + f.h / 2
        return [Pt(f.x, f.y), Pt(f.x + f.w, f.y), Pt(f.x + f.w, f.y + f.h), Pt(f.x, f.y + f.h)]
            .map { rotateAround($0.x, $0.y, cx, cy, f.rot) }
    }

    // MARK: Lasso hit tests

    private static func orient(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double) -> Double {
        let v = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
        return v > 0 ? 1 : (v < 0 ? -1 : 0)
    }

    private static func onSegment(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double, _ cx: Double, _ cy: Double) -> Bool {
        cx >= min(ax, bx) && cx <= max(ax, bx) && cy >= min(ay, by) && cy <= max(ay, by)
    }

    static func segmentsIntersect(_ a1: Pt, _ a2: Pt, _ b1: Pt, _ b2: Pt) -> Bool {
        let o1 = orient(a1.x, a1.y, a2.x, a2.y, b1.x, b1.y)
        let o2 = orient(a1.x, a1.y, a2.x, a2.y, b2.x, b2.y)
        let o3 = orient(b1.x, b1.y, b2.x, b2.y, a1.x, a1.y)
        let o4 = orient(b1.x, b1.y, b2.x, b2.y, a2.x, a2.y)
        if o1 != o2 && o3 != o4 { return true }
        if o1 == 0 && onSegment(a1.x, a1.y, a2.x, a2.y, b1.x, b1.y) { return true }
        if o2 == 0 && onSegment(a1.x, a1.y, a2.x, a2.y, b2.x, b2.y) { return true }
        if o3 == 0 && onSegment(b1.x, b1.y, b2.x, b2.y, a1.x, a1.y) { return true }
        if o4 == 0 && onSegment(b1.x, b1.y, b2.x, b2.y, a2.x, a2.y) { return true }
        return false
    }

    static func polygonsOverlap(_ a: [Pt], _ b: [Pt]) -> Bool {
        for p in a where pointInPolygon(p.x, p.y, b) { return true }
        for p in b where pointInPolygon(p.x, p.y, a) { return true }
        for i in 0..<a.count {
            let a1 = a[i], a2 = a[(i + 1) % a.count]
            for j in 0..<b.count where segmentsIntersect(a1, a2, b[j], b[(j + 1) % b.count]) { return true }
        }
        return false
    }

    /// Any point of the stroke inside the lasso, or any segment crossing its edge, selects the stroke.
    static func strokeInPolygon(_ points: [Pt], _ poly: [Pt]) -> Bool {
        if points.isEmpty { return false }
        if points.contains(where: { pointInPolygon($0.x, $0.y, poly) }) { return true }
        if points.count >= 2 {
            for i in 0..<(points.count - 1) {
                for j in 0..<poly.count where segmentsIntersect(points[i], points[i + 1], poly[j], poly[(j + 1) % poly.count]) {
                    return true
                }
            }
        }
        return false
    }

    static func elementInPolygon(_ el: PageElement, _ poly: [Pt]) -> Bool {
        polygonsOverlap(elementCorners(el), poly)
    }

    static func itemInPolygon(_ item: PageItem, _ poly: [Pt]) -> Bool {
        switch item {
        case .stroke(let s): return strokeInPolygon(s.pts, poly)
        case .element(let e): return elementInPolygon(e, poly)
        }
    }

    /// The box or ellipse spanning two corners, as a polygon the lasso hit tests can use as-is.
    static func marqueePolygon(circle: Bool, _ a: Pt, _ b: Pt) -> [Pt] {
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y), x1 = max(a.x, b.x), y1 = max(a.y, b.y)
        if !circle { return [Pt(x0, y0), Pt(x1, y0), Pt(x1, y1), Pt(x0, y1)] }
        let cx = (x0 + x1) / 2, cy = (y0 + y1) / 2, rx = (x1 - x0) / 2, ry = (y1 - y0) / 2
        let n = 48
        return (0..<n).map { i in
            let t = Double(i) / Double(n) * Double.pi * 2
            return Pt(cx + rx * cos(t), cy + ry * sin(t))
        }
    }

    // MARK: Hit testing

    /// Tap slop beyond a stroke's own half-width, in page units.
    static let tapRadius = 6.0

    /// Topmost item under a point: strokes by proximity to their centreline, elements by their rotated box.
    static func topItemAt(_ items: [PageItem], _ x: Double, _ y: Double, tapSlop: Double = tapRadius) -> PageItem? {
        for item in items.reversed() {
            switch item {
            case .stroke(let s):
                if nearPolyline(x, y, s.pts, s.size / 2 + tapSlop) { return item }
            case .element(let e):
                if pointInElement(e, x, y) { return item }
            }
        }
        return nil
    }

    // MARK: Transforms

    /// Maps a point from where it sits inside `from` to where it lands inside `to`: rotate, scale per axis, translate.
    static func mapPoint(_ x: Double, _ y: Double, from: ItemFrame, to: ItemFrame) -> Pt {
        let sx = from.w > 0 ? to.w / from.w : 1
        let sy = from.h > 0 ? to.h / from.h : 1
        let fcx = from.x + from.w / 2, fcy = from.y + from.h / 2
        let tcx = to.x + to.w / 2, tcy = to.y + to.h / 2
        let c = cos(to.rot), s = sin(to.rot)
        let l0 = rotateAround(x, y, fcx, fcy, -from.rot)
        let lx = (l0.x - fcx) * sx
        let ly = (l0.y - fcy) * sy
        return Pt(tcx + lx * c - ly * s, tcy + lx * s + ly * c)
    }

    /// Re-maps items from one frame to another; stroke nibs and text sizes scale with the box.
    static func transformItems(_ items: [PageItem], from: ItemFrame, to: ItemFrame) -> [PageItem] {
        let sx = from.w > 0 ? to.w / from.w : 1
        let sy = from.h > 0 ? to.h / from.h : 1
        let drot = to.rot - from.rot
        let uniform = (abs(sx * sy)).squareRoot()
        return items.map { item in
            switch item {
            case .stroke(var s):
                s.size *= uniform
                s.points = s.points.map { p in
                    let m = mapPoint(p.x, p.y, from: from, to: to)
                    return StrokePoint(x: m.x, y: m.y, pressure: p.pressure)
                }
                return .stroke(s)
            case .element(var e):
                let c = elementCenter(e)
                let nc = mapPoint(c.x, c.y, from: from, to: to)
                let w = e.w * sx, h = e.h * sy
                e.x = nc.x - w / 2; e.y = nc.y - h / 2; e.w = w; e.h = h
                e.rotation = e.rotation + drot
                switch e.content {
                case .text(var t):
                    // width-only drags re-wrap without changing the type size; corner drags scale it
                    t.fontSize *= sy
                    e.content = .text(t)
                case .bubble:
                    e.rotation = 0
                case .connector(var k):
                    let a = mapPoint(k.ax, k.ay, from: from, to: to)
                    let b = mapPoint(k.bx, k.by, from: from, to: to)
                    k.ax = a.x; k.ay = a.y; k.bx = b.x; k.by = b.y
                    e.content = .connector(k)
                    e.rotation = 0
                default:
                    break
                }
                return .element(e)
            }
        }
    }

    static func translateItems(_ items: [PageItem], dx: Double, dy: Double) -> [PageItem] {
        items.map { item in
            switch item {
            case .stroke(var s):
                s.points = s.points.map { StrokePoint(x: $0.x + dx, y: $0.y + dy, pressure: $0.pressure) }
                return .stroke(s)
            case .element(var e):
                e.x += dx; e.y += dy
                if case .connector(var k) = e.content {
                    k.ax += dx; k.ay += dy; k.bx += dx; k.by += dy
                    e.content = .connector(k)
                }
                return .element(e)
            }
        }
    }

    // MARK: Eraser

    /// Result of rubbing a circle across a stroke: the (possibly extended) points and which of them are gone.
    struct Rubbed: Equatable {
        var pts: [StrokePoint]
        var gone: Set<Int>
    }

    /// Marks the points of a stroke within `r` of (cx, cy) as rubbed out, splitting segments the circle
    /// crosses. Returns nil when nothing changed.
    static func rubOut(_ points: [StrokePoint], gone: Set<Int>, cx: Double, cy: Double, r: Double) -> Rubbed? {
        let r2 = r * r
        let inside: [Bool] = points.enumerated().map { i, p in
            !gone.contains(i) && (p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy) <= r2
        }
        func lerp(_ a: StrokePoint, _ b: StrokePoint, _ t: Double) -> StrokePoint {
            StrokePoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t, pressure: a.pressure + (b.pressure - a.pressure) * t)
        }
        var pts: [StrokePoint] = []
        var out = Set<Int>()
        var changed = false
        for i in 0..<points.count {
            if gone.contains(i) || inside[i] {
                out.insert(pts.count)
                if inside[i] { changed = true }
            }
            pts.append(points[i])
            let j = i + 1
            if j >= points.count || gone.contains(i) || gone.contains(j) { continue }
            let a = points[i], b = points[j]
            let dx = b.x - a.x, dy = b.y - a.y
            let fx = a.x - cx, fy = a.y - cy
            let A = dx * dx + dy * dy
            if A == 0 { continue }
            let B = 2 * (fx * dx + fy * dy)
            let disc = B * B - 4 * A * (fx * fx + fy * fy - r2)
            if disc <= 0 { continue }
            let s = disc.squareRoot()
            let lo = max((-B - s) / (2 * A), 0)
            let hi = min((-B + s) / (2 * A), 1)
            if lo >= hi { continue }
            if inside[i] && inside[j] { continue }
            if inside[i] {
                pts.append(lerp(a, b, hi))
            } else if inside[j] {
                pts.append(lerp(a, b, lo))
            } else {
                // the circle crosses between two samples without containing either
                pts.append(lerp(a, b, lo))
                out.insert(pts.count)
                pts.append(lerp(a, b, (lo + hi) / 2))
                pts.append(lerp(a, b, hi))
                changed = true
            }
        }
        return changed ? Rubbed(pts: pts, gone: out) : nil
    }

    /// Maximal runs of points not in `gone`; runs shorter than two points can't be drawn and are dropped.
    static func survivingSegments(_ points: [StrokePoint], gone: Set<Int>) -> [[StrokePoint]] {
        var segs: [[StrokePoint]] = []
        var run: [StrokePoint] = []
        for i in 0...points.count {
            if i < points.count && !gone.contains(i) {
                run.append(points[i])
                continue
            }
            if run.count >= 2 { segs.append(run) }
            run = []
        }
        return segs
    }
}
