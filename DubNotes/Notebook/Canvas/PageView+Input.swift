import UIKit

// Touch handling for everything PencilKit doesn't do: shapes, tape, text, box / circle lasso, the laser,
// selection handles and element taps. Ports the press / drag / tap rules of startPress in page-canvas.ts.
extension PageView {
    /// Screen points a press may travel and still count as a tap.
    static let tapSlopScreen = 8.0
    /// Smallest box a Shapes drag will place, in screen points.
    static let shapeMinScreen = 12.0
    /// Grab radius for selection handles, in screen points.
    static let handleHitScreen = 22.0

    private func location(_ t: UITouch) -> Pt {
        let p = t.location(in: overlay)
        return Pt(Double(p.x), Double(p.y))
    }

    // MARK: Hit tests

    func elementUnder(_ pt: Pt) -> PageElement? {
        for e in elements.reversed() where !hiddenIds.contains(e.id) && Geometry.pointInElement(e, pt.x, pt.y) { return e }
        return nil
    }

    func tapeUnder(_ pt: Pt) -> PageElement? {
        for e in elements.reversed() where !hiddenIds.contains(e.id) {
            if case .tape = e.content, Geometry.pointInElement(e, pt.x, pt.y) { return e }
        }
        return nil
    }

    func textUnder(_ pt: Pt) -> PageElement? {
        for e in elements.reversed() where !hiddenIds.contains(e.id) {
            if case .text = e.content, Geometry.pointInElement(e, pt.x, pt.y) { return e }
        }
        return nil
    }

    func shapeUnder(_ pt: Pt) -> PageElement? {
        for e in elements.reversed() where !hiddenIds.contains(e.id) {
            if case .shape = e.content, Geometry.pointInElement(e, pt.x, pt.y) { return e }
        }
        return nil
    }

    func handleAt(_ pt: Pt) -> SelectionHandle? {
        guard let f = selectionFrame else { return nil }
        let z = max(zoom, 0.1)
        return SelectionMath.handle(at: pt, frame: f, style: selectionStyle, hit: Self.handleHitScreen / z,
                                    gripOffset: SelectionMath.rotateGripOffset / z)
    }

    /// Whether the overlay should take a touch at `pt` rather than letting it fall through to the canvas.
    func overlayWants(_ pt: Pt) -> Bool {
        if mode != .none || xf != nil || editor != nil { return true }
        if handleAt(pt) != nil { return true }
        switch settings.kind {
        case .shapes, .tape, .laser, .text: return true
        case .lasso: return settings.lassoShape != .free || elementUnder(pt) != nil
        case .pen, .highlighter, .eraser: return tapeUnder(pt) != nil
        case .hand: return false
        }
    }

    // MARK: Touches

    func overlayBegan(_ touch: UITouch, _ event: UIEvent?) {
        guard activeTouch == nil else { return }
        column?.pressBegan()
        let pt = location(touch)
        let draws = touch.type != .direct || !PencilDetector.seen
        activeTouch = touch
        pressPt = pt
        moved = false
        livePts = [pt]
        let kind = settings.kind

        if editor != nil {
            // a press on another text box keeps editing going; anything else just closes the editor
            let keepsEditing = kind == .text && textUnder(pt) != nil
            commitEdit()
            if !keepsEditing {
                mode = .dismiss
                return
            }
        }
        if let h = handleAt(pt) {
            beginTransform(h, at: pt)
            return
        }

        switch kind {
        case .pen, .highlighter, .eraser:
            if let t = tapeUnder(pt) { mode = .press(.tape(t.id)) } else { mode = .dismiss }
        case .lasso:
            if let e = elementUnder(pt) {
                mode = .press(.element(e.id))
            } else if settings.lassoShape != .free && draws {
                clearSelection()
                mode = .marquee
                lassoPath = [pt]
            } else {
                clearSelection()
                mode = .dismiss
            }
        case .text:
            if let t = textUnder(pt) {
                mode = .press(.text(t.id))
            } else {
                clearSelection()
                mode = .press(.newText)
            }
        case .shapes:
            if let s = shapeUnder(pt) {
                mode = .press(.element(s.id))
            } else if draws {
                clearSelection()
                mode = .shape
            } else {
                mode = .dismiss
            }
        case .tape:
            if let t = tapeUnder(pt) {
                mode = .press(.tape(t.id))
            } else if draws {
                clearSelection()
                mode = .tapeDrag
            } else {
                mode = .dismiss
            }
        case .laser:
            if draws {
                mode = .laser
                laser.append([LaserPoint(x: pt.x, y: pt.y, t: CACurrentMediaTime())])
                startLaserLink()
            } else {
                mode = .dismiss
            }
        case .hand:
            mode = .dismiss
        }
        overlay.setNeedsDisplay()
    }

    func overlayMoved(_ touch: UITouch, _ event: UIEvent?) {
        guard touch === activeTouch else { return }
        let pts = (event?.coalescedTouches(for: touch) ?? [touch]).map { location($0) }
        guard let pt = pts.last else { return }
        if Geometry.dist(pt, pressPt) > Self.tapSlopScreen / max(zoom, 0.1) { moved = true }

        switch mode {
        case .shape, .tapeDrag:
            livePts = [pressPt, pt]
            overlay.setNeedsDisplay()
        case .laser:
            let now = CACurrentMediaTime()
            for p in pts { laser[laser.count - 1].append(LaserPoint(x: p.x, y: p.y, t: now)) }
        case .marquee:
            lassoPath = [pressPt, pt]
            overlay.setNeedsDisplay()
        case .transform:
            updateTransform(to: pt)
        case .press(let target):
            guard moved else { return }
            let kind = settings.kind
            switch target {
            case .tape(let id):
                if kind == .tape || kind == .lasso { startMove(of: id) } else { mode = .dismiss }
            case .element(let id), .text(let id):
                startMove(of: id)
            case .newText:
                mode = .dismiss
            }
        default:
            break
        }
    }

    func overlayEnded(_ touch: UITouch) {
        guard touch === activeTouch else { return }
        finish(commit: true, at: location(touch))
    }

    func overlayCancelled(_ touch: UITouch) {
        guard touch === activeTouch else { return }
        finish(commit: false, at: pressPt)
    }

    /// Abandons whatever is in flight (an undo while a shape was being dragged).
    func cancelInput() -> Bool {
        guard mode != .none else { return false }
        finish(commit: false, at: pressPt)
        return true
    }

    private func finish(commit: Bool, at pt: Pt) {
        let m = mode
        mode = .none
        activeTouch = nil
        switch m {
        case .shape:
            if commit, let el = shapeFromDrag(to: pt) {
                session.add([.element(el)], to: pageId)
                select(ids: [el.id])
            }
        case .tapeDrag:
            if commit, let el = tapeFromDrag(to: pt) {
                session.add([.element(el)], to: pageId)
            }
        case .marquee:
            if commit { finishMarquee(to: pt) }
            lassoPath = []
        case .transform:
            endTransform(commit: commit)
        case .press(let target):
            if commit && !moved { handleTap(target, at: pt) }
        default:
            break
        }
        livePts = []
        overlay.setNeedsDisplay()
    }

    private func startMove(of id: String) {
        select(ids: [id])
        guard let f = selectionFrame else { mode = .dismiss; return }
        _ = f
        beginTransform(.move, at: pressPt)
    }

    private func handleTap(_ target: PressTarget, at pt: Pt) {
        switch target {
        case .tape(let id):
            let kind = settings.kind
            if kind == .tape || kind == .lasso {
                select(ids: [id])
            } else {
                if peeled.contains(id) { peeled.remove(id) } else { peeled.insert(id) }
            }
        case .element(let id):
            select(ids: [id])
        case .text(let id):
            select(ids: [id])
            if let el = elements.first(where: { $0.id == id }), case .text = el.content { startEdit(el, isNew: false) }
        case .newText:
            startEdit(newText(at: pt), isNew: true)
        }
    }

    // MARK: Placing things

    private func shapeFromDrag(to b: Pt) -> PageElement? {
        let a = pressPt
        let s = settings
        let size = s.penSize
        let minSide = Self.shapeMinScreen / max(zoom, 0.1)
        let fit: ShapeFit
        switch s.shapeKind {
        case .arrow:
            if Geometry.dist(a, b) < minSide { return nil }
            fit = ShapeRecognition.lineFit(.arrow, a, b, nib: size)
        case .rect, .ellipse, .triangle:
            let w = abs(b.x - a.x), h = abs(b.y - a.y)
            if w < minSide || h < minSide { return nil }
            let kind: PageElement.Shape.Kind = s.shapeKind == .rect ? .rect : (s.shapeKind == .ellipse ? .ellipse : .triangle)
            fit = ShapeFit(shape: kind, x: min(a.x, b.x), y: min(a.y, b.y), w: w, h: h, rotation: 0,
                           pts: kind == .triangle ? [[0.5, 0], [1, 1], [0, 1]] : nil) // apex up, base along the bottom
        }
        let shape = PageElement.Shape(shape: fit.shape, color: s.penColor, size: size, pts: fit.pts)
        return PageElement(id: UUID().uuidString, pageId: pageId, notebookId: session.doc.id,
                           x: fit.x, y: fit.y, w: fit.w, h: fit.h, rotation: fit.rotation,
                           createdAt: LibraryStore.now(), content: .shape(shape))
    }

    private func tapeFromDrag(to b: Pt) -> PageElement? {
        let a = pressPt
        let w = abs(b.x - a.x), h = abs(b.y - a.y)
        if max(w, h) < 6 { return nil }
        return PageElement(id: UUID().uuidString, pageId: pageId, notebookId: session.doc.id,
                           x: min(a.x, b.x), y: min(a.y, b.y), w: w, h: h, rotation: 0,
                           createdAt: LibraryStore.now(), content: .tape(PageElement.Tape(color: ElementRenderer.tapeColor)))
    }

    private func finishMarquee(to b: Pt) {
        let circle = settings.lassoShape == .circle
        let poly = Geometry.marqueePolygon(circle: circle, pressPt, b)
        let items = session.doc.items(of: pageId).filter { !hiddenIds.contains($0.id) && Geometry.itemInPolygon($0, poly) }
        if items.isEmpty {
            clearSelection()
            let box = Geometry.aabb(poly)
            if box.w > 4 || box.h > 4 { column?.emptyLassoSelected(on: self, frame: ItemFrame(x: box.x, y: box.y, w: box.w, h: box.h)) }
            return
        }
        select(ids: Set(items.map(\.id)))
    }

    // MARK: Laser

    func startLaserLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(laserTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func laserTick() {
        let now = CACurrentMediaTime()
        let fade = ToolSettings.laserFadeSeconds
        laser = laser.map { $0.filter { now - $0.t < fade } }.filter { !$0.isEmpty }
        overlay.setNeedsDisplay()
        if laser.isEmpty && mode != .laser {
            displayLink?.invalidate()
            displayLink = nil
        }
    }

    // MARK: Drawing

    func drawOverlay(in ctx: CGContext) {
        let page = currentPage
        let paper = page.paper
        // tape covers the ink; a peeled strip is outline only
        for e in elements where PageView.isAboveInk(e) && !hiddenIds.contains(e.id) {
            ElementRenderer.draw(e, in: ctx, paper: paper, peeled: peeled.contains(e.id))
        }

        switch mode {
        case .shape:
            if let last = livePts.last, let el = shapeFromDrag(to: last) { ElementRenderer.draw(el, in: ctx, paper: paper, opacity: 0.9) }
        case .tapeDrag:
            if let last = livePts.last, let el = tapeFromDrag(to: last) { ElementRenderer.draw(el, in: ctx, paper: paper, opacity: 0.85) }
        case .marquee:
            if let last = livePts.last ?? lassoPath.last {
                let poly = Geometry.marqueePolygon(circle: settings.lassoShape == .circle, pressPt, lassoPath.last ?? last)
                drawDashedPolygon(poly, in: ctx, paper: paper)
            }
        default:
            break
        }

        if let xf {
            // the dragged items, drawn where they will land; their originals are hidden on the page
            if let img = xf.strokeImage, let to = selectionFrame {
                let from = xf.startFrame
                let sx: Double = from.w > 0 ? to.w / from.w : 1
                let sy: Double = from.h > 0 ? to.h / from.h : 1
                let toCX: Double = to.x + to.w / 2
                let toCY: Double = to.y + to.h / 2
                let fromCX: Double = from.x + from.w / 2
                let fromCY: Double = from.y + from.h / 2
                let turn: Double = to.rot - from.rot
                ctx.saveGState()
                ctx.translateBy(x: CGFloat(toCX), y: CGFloat(toCY))
                ctx.rotate(by: CGFloat(turn))
                ctx.scaleBy(x: CGFloat(sx), y: CGFloat(sy))
                ctx.translateBy(x: CGFloat(-fromCX), y: CGFloat(-fromCY))
                UIGraphicsPushContext(ctx)
                img.draw(in: xf.strokeImageRect)
                UIGraphicsPopContext()
                ctx.restoreGState()
            }
            for item in xf.preview { if case .element(let e) = item { ElementRenderer.draw(e, in: ctx, paper: paper) } }
        }

        drawSelection(in: ctx, paper: paper)
        drawLaser(in: ctx)
    }

    private func drawDashedPolygon(_ poly: [Pt], in ctx: CGContext, paper: Paper) {
        guard poly.count > 1 else { return }
        let z = CGFloat(max(zoom, 0.1))
        ctx.saveGState()
        ctx.setStrokeColor(UIColor.fromHex(PaperStyle.accent(paper)).cgColor)
        ctx.setLineWidth(1.5 / z)
        ctx.setLineDash(phase: 0, lengths: [6 / z, 4 / z])
        ctx.move(to: CGPoint(x: poly[0].x, y: poly[0].y))
        for p in poly.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
        ctx.closePath()
        ctx.strokePath()
        ctx.restoreGState()
    }

    private func drawSelection(in ctx: CGContext, paper: Paper) {
        guard let f = selectionFrame, !selectedIds.isEmpty else { return }
        let z = CGFloat(max(zoom, 0.1))
        let accent = UIColor.fromHex(PaperStyle.accent(paper))
        let corners = Geometry.frameCorners(f)
        ctx.saveGState()
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1.5 / z)
        ctx.move(to: CGPoint(x: corners[0].x, y: corners[0].y))
        for c in corners.dropFirst() { ctx.addLine(to: CGPoint(x: c.x, y: c.y)) }
        ctx.closePath()
        ctx.strokePath()

        let handleFill = paper.color == .dark ? UIColor.fromHex("#1e2330") : UIColor.white
        let half = 5 / z
        func handle(_ p: Pt) {
            let h: Double = Double(half)
            let r = CGRect(x: p.x - h, y: p.y - h, width: h * 2, height: h * 2)
            ctx.setFillColor(handleFill.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(accent.cgColor)
            ctx.stroke(r)
        }
        for i in 0..<4 { handle(SelectionMath.pagePoint(f, .corner(i))) }
        switch selectionStyle.edges {
        case .all: for i in 0..<4 { handle(SelectionMath.pagePoint(f, .edge(i))) }
        case .horizontal: handle(SelectionMath.pagePoint(f, .edge(1))); handle(SelectionMath.pagePoint(f, .edge(3)))
        case .none: break
        }
        if selectionStyle.rotate {
            let grip = SelectionMath.pagePoint(f, .rotate, gripOffset: SelectionMath.rotateGripOffset / Double(z))
            let top = SelectionMath.pagePoint(f, .edge(0))
            ctx.move(to: CGPoint(x: top.x, y: top.y))
            ctx.addLine(to: CGPoint(x: grip.x, y: grip.y))
            ctx.strokePath()
            let h: Double = Double(half)
            let r = CGRect(x: grip.x - h, y: grip.y - h, width: h * 2, height: h * 2)
            ctx.setFillColor(accent.cgColor)
            ctx.fillEllipse(in: r)
        }
        ctx.restoreGState()
    }

    private func drawLaser(in ctx: CGContext) {
        guard !laser.isEmpty else { return }
        let now = CACurrentMediaTime()
        let fade = ToolSettings.laserFadeSeconds
        let color = UIColor.fromHex(ToolSettings.laserColor)
        ctx.saveGState()
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        for trail in laser {
            if trail.count > 1 {
                for i in 1..<trail.count {
                    let age: Double = (now - trail[i].t) / fade
                    let alpha: CGFloat = CGFloat(max(0.0, 1.0 - age))
                    ctx.setStrokeColor(color.withAlphaComponent(alpha * 0.35).cgColor)
                    ctx.setLineWidth(14)
                    ctx.move(to: CGPoint(x: trail[i - 1].x, y: trail[i - 1].y))
                    ctx.addLine(to: CGPoint(x: trail[i].x, y: trail[i].y))
                    ctx.strokePath()
                    ctx.setStrokeColor(color.withAlphaComponent(alpha).cgColor)
                    ctx.setLineWidth(4)
                    ctx.move(to: CGPoint(x: trail[i - 1].x, y: trail[i - 1].y))
                    ctx.addLine(to: CGPoint(x: trail[i].x, y: trail[i].y))
                    ctx.strokePath()
                }
            }
            if let head = trail.last {
                let headAge: Double = (now - head.t) / fade
                let alpha: CGFloat = CGFloat(max(0.0, 1.0 - headAge))
                ctx.setFillColor(color.withAlphaComponent(alpha).cgColor)
                let headRect = CGRect(x: head.x - 5, y: head.y - 5, width: 10, height: 10)
                ctx.fillEllipse(in: headRect)
            }
        }
        ctx.restoreGState()
    }
}
