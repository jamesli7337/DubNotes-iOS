import Foundation

/// A grab point on a selection frame.
enum SelectionHandle: Equatable {
    case move
    /// 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
    case corner(Int)
    /// 0 top, 1 right, 2 bottom, 3 left.
    case edge(Int)
    case rotate
}

/// Which handles a selection offers (selectionView in item-surface.ts).
struct SelectionStyle: Equatable {
    var rotate: Bool
    /// Corner drags keep the frame's aspect ratio.
    var aspect: Bool
    /// Edge handles: none, left/right only (text), or all four sides.
    var edges: Edges

    enum Edges: Equatable { case none, horizontal, all }

    /// A single element keeps its own box and handles; strokes and mixed selections get an aspect-locked
    /// bounding box with corner handles only.
    static func style(for items: [PageItem]) -> SelectionStyle {
        if items.count == 1, case .element(let e) = items[0] {
            switch e.content {
            case .text: return SelectionStyle(rotate: true, aspect: true, edges: .horizontal)
            case .image: return SelectionStyle(rotate: true, aspect: true, edges: .all)
            case .bubble, .connector: return SelectionStyle(rotate: false, aspect: false, edges: .all)
            default: return SelectionStyle(rotate: true, aspect: false, edges: .all)
            }
        }
        return SelectionStyle(rotate: false, aspect: true, edges: .none)
    }
}

enum SelectionMath {
    /// Smallest side a resize will shrink a frame to, in page units.
    static let minSide = 8.0
    /// A rotation drag snaps to multiples of this...
    static let rotateSnapStep = 15 * Double.pi / 180
    /// ...when within this of one.
    static let rotateSnapNear = 4 * Double.pi / 180
    /// How far the rotate grip sits above the frame's top edge, in screen points.
    static let rotateGripOffset = 28.0

    /// A frame's local corner / edge point (before rotation) for a handle.
    static func localPoint(_ f: ItemFrame, _ handle: SelectionHandle) -> Pt {
        switch handle {
        case .corner(let i):
            switch i {
            case 0: return Pt(f.x, f.y)
            case 1: return Pt(f.x + f.w, f.y)
            case 2: return Pt(f.x + f.w, f.y + f.h)
            default: return Pt(f.x, f.y + f.h)
            }
        case .edge(let i):
            switch i {
            case 0: return Pt(f.x + f.w / 2, f.y)
            case 1: return Pt(f.x + f.w, f.y + f.h / 2)
            case 2: return Pt(f.x + f.w / 2, f.y + f.h)
            default: return Pt(f.x, f.y + f.h / 2)
            }
        case .rotate, .move:
            return Pt(f.x + f.w / 2, f.y + f.h / 2)
        }
    }

    /// The handle's position on the page, rotation applied.
    static func pagePoint(_ f: ItemFrame, _ handle: SelectionHandle, gripOffset: Double = 0) -> Pt {
        let cx = f.x + f.w / 2, cy = f.y + f.h / 2
        if handle == .rotate {
            return Geometry.rotateAround(cx, f.y - gripOffset, cx, cy, f.rot)
        }
        let p = localPoint(f, handle)
        return Geometry.rotateAround(p.x, p.y, cx, cy, f.rot)
    }

    /// The handle under `pt`, if any. `hit` is the grab radius in page units (screen size divided by zoom).
    /// Corners win over edges, which win over the grip, which wins over the body.
    static func handle(at pt: Pt, frame f: ItemFrame, style: SelectionStyle, hit: Double, gripOffset: Double) -> SelectionHandle? {
        var candidates: [SelectionHandle] = (0..<4).map { SelectionHandle.corner($0) }
        switch style.edges {
        case .all: candidates += (0..<4).map { SelectionHandle.edge($0) }
        case .horizontal: candidates += [.edge(1), .edge(3)]
        case .none: break
        }
        if style.rotate { candidates.append(.rotate) }
        var best: SelectionHandle?
        var bestD = hit
        for h in candidates {
            let p = pagePoint(f, h, gripOffset: gripOffset)
            let d = Geometry.dist(p, pt)
            if d <= bestD { bestD = d; best = h }
        }
        if let b = best { return b }
        let c = Pt(f.x + f.w / 2, f.y + f.h / 2)
        let l = Geometry.rotateAround(pt.x, pt.y, c.x, c.y, -f.rot)
        if l.x >= f.x - hit / 2 && l.x <= f.x + f.w + hit / 2 && l.y >= f.y - hit / 2 && l.y <= f.y + f.h + hit / 2 {
            return .move
        }
        return nil
    }

    /// The frame after dragging a corner or edge handle to `pointer`. The opposite corner / edge stays put;
    /// the resize happens in the frame's own rotated space. `aspect` keeps the starting ratio on corner drags.
    static func resized(_ start: ItemFrame, handle: SelectionHandle, to pointer: Pt, aspect: Bool) -> ItemFrame {
        let c = Pt(start.x + start.w / 2, start.y + start.h / 2)
        let p = Geometry.rotateAround(pointer.x, pointer.y, c.x, c.y, -start.rot) // pointer in local space
        var x0 = start.x, y0 = start.y, x1 = start.x + start.w, y1 = start.y + start.h

        switch handle {
        case .corner(let i):
            // the moving corner follows the pointer; the opposite one is the anchor
            let movesLeft = (i == 0 || i == 3)
            let movesTop = (i == 0 || i == 1)
            var nx = p.x, ny = p.y
            if aspect, start.w > 0, start.h > 0 {
                let ax = movesLeft ? x1 : x0
                let ay = movesTop ? y1 : y0
                let sx = abs(nx - ax) / start.w
                let sy = abs(ny - ay) / start.h
                let s = max(sx, sy, minSide / max(start.w, start.h))
                nx = ax + (movesLeft ? -1 : 1) * start.w * s
                ny = ay + (movesTop ? -1 : 1) * start.h * s
            }
            if movesLeft { x0 = nx } else { x1 = nx }
            if movesTop { y0 = ny } else { y1 = ny }
        case .edge(let i):
            switch i {
            case 0: y0 = p.y
            case 1: x1 = p.x
            case 2: y1 = p.y
            default: x0 = p.x
            }
        default:
            return start
        }

        // keep at least `minSide` and never flip: pin the moving side against the anchor
        if x1 - x0 < minSide {
            if case .corner(let i) = handle, i == 0 || i == 3 { x0 = x1 - minSide } else if case .edge(3) = handle { x0 = x1 - minSide } else { x1 = x0 + minSide }
        }
        if y1 - y0 < minSide {
            if case .corner(let i) = handle, i == 0 || i == 1 { y0 = y1 - minSide } else if case .edge(0) = handle { y0 = y1 - minSide } else { y1 = y0 + minSide }
        }

        // the new local centre, rotated back onto the page, is the new centre
        let ncl = Pt((x0 + x1) / 2, (y0 + y1) / 2)
        let nc = Geometry.rotateAround(ncl.x, ncl.y, c.x, c.y, start.rot)
        let w = x1 - x0, h = y1 - y0
        return ItemFrame(x: nc.x - w / 2, y: nc.y - h / 2, w: w, h: h, rot: start.rot)
    }

    /// The frame after dragging the rotate grip to `pointer`: turned about its centre, snapped to 15° within 4°.
    static func rotated(_ start: ItemFrame, to pointer: Pt) -> ItemFrame {
        let cx = start.x + start.w / 2, cy = start.y + start.h / 2
        var angle = atan2(pointer.y - cy, pointer.x - cx) + Double.pi / 2 // the grip sits straight above the top edge
        let nearest = (angle / rotateSnapStep).rounded() * rotateSnapStep
        if abs(angle - nearest) <= rotateSnapNear { angle = nearest }
        var f = start
        f.rot = angle
        return f
    }

    /// The frame after moving by (dx, dy).
    static func moved(_ start: ItemFrame, dx: Double, dy: Double) -> ItemFrame {
        var f = start
        f.x += dx
        f.y += dy
        return f
    }
}
