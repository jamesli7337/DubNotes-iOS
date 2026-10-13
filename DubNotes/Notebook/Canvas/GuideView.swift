import UIKit

/// A straight edge in page space: a point on it and its unit direction.
struct EdgeLine: Equatable {
    var px: Double
    var py: Double
    var ux: Double
    var uy: Double

    /// Projects a page point onto the edge.
    func project(_ x: Double, _ y: Double) -> Pt {
        let t = (x - px) * ux + (y - py) * uy
        return Pt(px + t * ux, py + t * uy)
    }
}

/// Ruler / protractor geometry and snapping (guide.ts), kept free of UIKit so it can be tested.
struct GuideGeometry: Equatable {
    static let rulerLength = PageUnits.width
    static let rulerThickness = 64.0
    static let protractorRadius = 200.0
    /// How close (page units) a pen-down must be to a straight edge to snap to it.
    static let snapDistance = 24.0
    /// Page units are CSS pixels at 96 dpi, so the scales read in real centimetres and inches.
    static let pxPerInch = 96.0
    static let pxPerCm = 96.0 / 2.54

    var kind: GuideKind
    var cx: Double
    var cy: Double
    var angle: Double = 0

    init(kind: GuideKind, pageWidth: Double, pageHeight: Double) {
        self.kind = kind
        cx = pageWidth / 2
        cy = kind == .ruler ? pageHeight * 0.4 : pageHeight * 0.45
    }

    /// Screen angle (radians, y down) as protractor-style degrees, counter-clockwise, 0–359.
    var degrees: Int {
        let d = Int((-angle * 180 / Double.pi).rounded())
        return ((d % 360) + 360) % 360
    }

    /// If (x, y) is within snapping distance of a straight edge (the ruler's two long sides, the protractor's
    /// baseline), returns that edge.
    func edgeNear(_ x: Double, _ y: Double) -> EdgeLine? {
        let ux = cos(angle), uy = sin(angle)
        let nx = -uy, ny = ux
        let dx = x - cx, dy = y - cy
        let t = dx * ux + dy * uy // along the edge
        let d = dx * nx + dy * ny // across it
        if kind == .ruler {
            if abs(t) > Self.rulerLength / 2 + 10 { return nil }
            let half = Self.rulerThickness / 2
            if abs(abs(d) - half) > Self.snapDistance { return nil }
            let side = d < 0 ? -half : half
            return EdgeLine(px: cx + nx * side, py: cy + ny * side, ux: ux, uy: uy)
        }
        if abs(t) > Self.protractorRadius + 10 || abs(d) > Self.snapDistance { return nil }
        return EdgeLine(px: cx, py: cy, ux: ux, uy: uy)
    }

    /// The view box (before rotation) in page units.
    var size: CGSize {
        kind == .ruler ? CGSize(width: Self.rulerLength, height: Self.rulerThickness)
                       : CGSize(width: Self.protractorRadius * 2, height: Self.protractorRadius)
    }
}

/// The on-page ruler or protractor: dragged around by its body, turned by its grip. View state only; never
/// stored. Pen strokes that start beside its straight edge are snapped onto that edge by the page.
final class GuideView: UIView {
    private(set) var geometry: GuideGeometry
    private let paper: Paper
    private let pageSize: CGSize
    var zoom: CGFloat = 1 { didSet { setNeedsDisplay() } }
    private var rotating = false
    private var dragStart: (pt: Pt, cx: Double, cy: Double)?

    init(kind: GuideKind, page: Page) {
        geometry = GuideGeometry(kind: kind, pageWidth: page.pageWidth, pageHeight: page.pageHeight)
        paper = page.paper
        pageSize = CGSize(width: page.pageWidth, height: page.pageHeight)
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
        bounds = CGRect(origin: .zero, size: geometry.size)
        place()
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func edgeNear(_ x: Double, _ y: Double) -> EdgeLine? { geometry.edgeNear(x, y) }

    private func place() {
        // rotate about the ruler's centre / the protractor's baseline midpoint, which is also where it is anchored
        layer.anchorPoint = geometry.kind == .ruler ? CGPoint(x: 0.5, y: 0.5) : CGPoint(x: 0.5, y: 1)
        bounds = CGRect(origin: .zero, size: geometry.size)
        center = CGPoint(x: geometry.cx, y: geometry.cy)
        transform = CGAffineTransform(rotationAngle: CGFloat(geometry.angle))
        setNeedsDisplay()
    }

    // MARK: Gestures

    /// The grip: the ruler's right end, the protractor's apex.
    private var gripPoint: CGPoint {
        geometry.kind == .ruler ? CGPoint(x: bounds.width - 18, y: bounds.height / 2)
                                : CGPoint(x: bounds.width / 2, y: 22)
    }

    @objc private func panned(_ gr: UIPanGestureRecognizer) {
        guard let host = superview else { return }
        let loc = gr.location(in: host)
        let pt = Pt(Double(loc.x), Double(loc.y))
        switch gr.state {
        case .began:
            let local = gr.location(in: self)
            let g = gripPoint
            let r = 28 / zoom
            rotating = hypot(local.x - g.x, local.y - g.y) <= r
            dragStart = (pt, geometry.cx, geometry.cy)
        case .changed:
            guard let d = dragStart else { return }
            if rotating {
                var a = atan2(pt.y - geometry.cy, pt.x - geometry.cx)
                if geometry.kind == .protractor { a += Double.pi / 2 }
                let deg = (a * 180 / Double.pi).rounded() // whole degrees, like a real protractor
                geometry.angle = deg * Double.pi / 180
            } else {
                geometry.cx = min(max(d.cx + pt.x - d.pt.x, 0), Double(pageSize.width))
                geometry.cy = min(max(d.cy + pt.y - d.pt.y, 0), Double(pageSize.height))
            }
            place()
        default:
            dragStart = nil
            rotating = false
            setNeedsDisplay()
        }
    }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let c = PaperStyle.guideColors(paper)
        let ink = UIColor(c.ink)
        let body = UIColor(c.body)
        let edge = UIColor(c.edge)
        let hair = 1 / max(zoom, 0.1)
        ctx.setLineWidth(hair)
        if geometry.kind == .ruler {
            drawRuler(ctx, body: body, edge: edge, ink: ink)
        } else {
            drawProtractor(ctx, c, body: body, edge: edge, ink: ink)
        }
        drawGrip(ctx, c)
    }

    private func label(_ text: String, at p: CGPoint, color: UIColor, size: CGFloat = 10, anchorLeft: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: size, weight: .medium), .foregroundColor: color]
        let s = text as NSString
        let sz = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: anchorLeft ? p.x : p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: attrs)
    }

    private func drawRuler(_ ctx: CGContext, body: UIColor, edge: UIColor, ink: UIColor) {
        let w = CGFloat(GuideGeometry.rulerLength), h = CGFloat(GuideGeometry.rulerThickness)
        let path = UIBezierPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 4)
        let hairline: CGFloat = 1 / max(zoom, 0.1)
        let heavy: CGFloat = 1.4 / max(zoom, 0.1)
        body.setFill(); path.fill()
        edge.setStroke(); path.lineWidth = hairline; path.stroke()
        ink.setStroke()
        let width: Double = Double(w)
        // top: millimetres, longer at 5 mm and 1 cm, numbered every centimetre
        var mm = 0
        while true {
            let mmX: Double = Double(mm) * GuideGeometry.pxPerCm / 10.0
            if mmX > width { break }
            let x: CGFloat = CGFloat(mmX)
            let cm: Bool = mm % 10 == 0
            let len: CGFloat = cm ? 18 : (mm % 5 == 0 ? 12 : 7)
            ctx.setLineWidth(cm ? heavy : hairline)
            ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: len)); ctx.strokePath()
            let labelX: CGFloat = x + 3
            if cm && mm == 0 { label("cm", at: CGPoint(x: labelX, y: 27), color: ink, size: 9, anchorLeft: true) }
            else if cm { label(String(mm / 10), at: CGPoint(x: x, y: 27), color: ink) }
            mm += 1
        }
        // bottom: sixteenths of an inch
        var s = 0
        let labelY: CGFloat = h - 25
        while true {
            let sX: Double = Double(s) * GuideGeometry.pxPerInch / 16.0
            if sX > width { break }
            let x: CGFloat = CGFloat(sX)
            let inch: Bool = s % 16 == 0
            let len: CGFloat = inch ? 18 : (s % 8 == 0 ? 13 : (s % 4 == 0 ? 9 : 5))
            let tickTop: CGFloat = h - len
            ctx.setLineWidth(inch ? heavy : hairline)
            ctx.move(to: CGPoint(x: x, y: h)); ctx.addLine(to: CGPoint(x: x, y: tickTop)); ctx.strokePath()
            let labelX: CGFloat = x + 3
            if inch && s == 0 { label("in", at: CGPoint(x: labelX, y: labelY), color: ink, size: 9, anchorLeft: true) }
            else if inch { label(String(s / 16), at: CGPoint(x: x, y: labelY), color: ink) }
            s += 1
        }
    }

    private func drawProtractor(_ ctx: CGContext, _ c: (body: RGB, edge: RGB, ink: RGB, accent: RGB, onAccent: RGB),
                                body: UIColor, edge: UIColor, ink: UIColor) {
        let R = CGFloat(GuideGeometry.protractorRadius)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: R))
        path.addArc(withCenter: CGPoint(x: R, y: R), radius: R, startAngle: .pi, endAngle: 0, clockwise: true)
        path.close()
        body.setFill(); path.fill()
        edge.setStroke(); path.lineWidth = 1 / max(zoom, 0.1); path.stroke()
        func on(_ deg: Double, _ r: CGFloat) -> CGPoint {
            let a: CGFloat = CGFloat(deg * Double.pi / 180.0)
            let px: CGFloat = R + r * cos(a)
            let py: CGFloat = R - r * sin(a)
            return CGPoint(x: px, y: py)
        }
        ink.setStroke()
        // guide rays every 10°, stopping short of the inner scale; the 0° / 90° / 180° axes are heavier
        let hair: CGFloat = 1 / max(zoom, 0.1)
        for deg in stride(from: 0.0, through: 180.0, by: 10.0) {
            let isAxis: Bool = deg.truncatingRemainder(dividingBy: 90) == 0
            ctx.setLineWidth(isAxis ? hair * 1.4 : hair * 0.6)
            let rayEnd: CGPoint = on(deg, R - 64)
            ctx.move(to: CGPoint(x: R, y: R)); ctx.addLine(to: rayEnd); ctx.strokePath()
        }
        for deg in 0...180 {
            let ten: Bool = deg % 10 == 0
            let len: CGFloat = ten ? 22 : (deg % 5 == 0 ? 14 : 7)
            let d: Double = Double(deg)
            ctx.setLineWidth(ten ? hair * 1.4 : hair)
            let outer: CGPoint = on(d, R)
            let inner: CGPoint = on(d, R - len)
            ctx.move(to: outer); ctx.addLine(to: inner); ctx.strokePath()
            if ten {
                label(String(deg), at: on(d, R - 36), color: ink)
                if deg > 0 && deg < 180 {
                    let faint: UIColor = ink.withAlphaComponent(0.7)
                    label(String(180 - deg), at: on(d, R - 56), color: faint, size: 8)
                }
            }
        }
        // inner arc separating the two scales, and the origin ring on the baseline's midpoint
        ctx.setLineWidth(1 / max(zoom, 0.1))
        let inner = UIBezierPath(arcCenter: CGPoint(x: R, y: R), radius: R - 46, startAngle: .pi, endAngle: 0, clockwise: true)
        inner.stroke()
        let acc = UIColor(c.accent)
        acc.setStroke()
        ctx.strokeEllipse(in: CGRect(x: R - 9, y: R - 9, width: 18, height: 18))
        acc.setFill()
        ctx.fillEllipse(in: CGRect(x: R - 3.5, y: R - 3.5, width: 7, height: 7))
    }

    /// The rotate grip, and the angle readout while turning (or always on the protractor).
    private func drawGrip(_ ctx: CGContext, _ c: (body: RGB, edge: RGB, ink: RGB, accent: RGB, onAccent: RGB)) {
        let g = gripPoint
        let r: CGFloat = 12
        UIColor(c.accent).setFill()
        let gripRect = CGRect(x: g.x - r, y: g.y - r, width: r * 2, height: r * 2)
        ctx.fillEllipse(in: gripRect)
        let arrows = UIImage(systemName: "arrow.triangle.2.circlepath")?.withTintColor(UIColor(c.onAccent), renderingMode: .alwaysOriginal)
        arrows?.draw(in: CGRect(x: g.x - 7, y: g.y - 7, width: 14, height: 14))
        if geometry.kind == .protractor || rotating {
            let text = "\(geometry.degrees)°"
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                                                        .foregroundColor: UIColor(c.onAccent)]
            let s = text as NSString
            let sz = s.size(withAttributes: attrs)
            let pillX: CGFloat = g.x - sz.width / 2 - 8
            let pillY: CGFloat = g.y + r + 4
            let pillW: CGFloat = sz.width + 16
            let pillH: CGFloat = sz.height + 4
            let pill = CGRect(x: pillX, y: pillY, width: pillW, height: pillH)
            UIColor(c.accent).setFill()
            UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
            s.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 2), withAttributes: attrs)
        }
    }
}
