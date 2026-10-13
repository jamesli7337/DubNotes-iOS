import UIKit

extension UIColor {
    convenience init(_ c: RGB) {
        self.init(red: CGFloat(c.r / 255), green: CGFloat(c.g / 255), blue: CGFloat(c.b / 255), alpha: CGFloat(c.a))
    }

    /// `#rgb` / `#rrggbb`; anything unreadable is black, like the web's export.
    static func fromHex(_ s: String) -> UIColor {
        RGB(hex: s).map { UIColor($0) } ?? .black
    }

    var rgb: RGB {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        // resolve in the light trait so dynamic colours give one stable answer
        let resolved = resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGB(Double(r * 255), Double(g * 255), Double(b * 255), Double(a))
    }
}

/// Text wrapping and sizing, a port of `layoutText` in elements.ts.
enum TextLayout {
    static let lineHeightFactor = 1.3

    static func font(_ size: Double) -> UIFont { UIFont.systemFont(ofSize: CGFloat(size), weight: .regular) }

    struct Result {
        var lines: [String]
        var lineHeight: Double
        var height: Double
    }

    /// Greedy word wrap at `maxWidth` page units; words wider than the box break by character.
    static func layout(_ text: String, fontSize: Double, maxWidth: Double) -> Result {
        let f = font(fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: f]
        func fits(_ s: String) -> Bool { Double((s as NSString).size(withAttributes: attrs).width) <= maxWidth }
        var lines: [String] = []
        for para in text.components(separatedBy: "\n") {
            var line = ""
            for word in para.components(separatedBy: " ") {
                let test = line.isEmpty ? word : "\(line) \(word)"
                if fits(test) { line = test; continue }
                if !line.isEmpty { lines.append(line); line = "" }
                if fits(word) { line = word; continue }
                var chunk = ""
                for ch in word {
                    if !chunk.isEmpty && !fits(chunk + String(ch)) {
                        lines.append(chunk)
                        chunk = String(ch)
                    } else {
                        chunk += String(ch)
                    }
                }
                line = chunk
            }
            lines.append(line)
        }
        let lh = fontSize * lineHeightFactor
        return Result(lines: lines, lineHeight: lh, height: Double(max(lines.count, 1)) * lh)
    }

    static func height(of t: PageElement.Text, width: Double) -> Double {
        layout(t.text, fontSize: t.fontSize, maxWidth: width).height
    }
}

/// Draws page elements with Core Graphics at the context's current transform. Page units in, so the caller
/// scales. Ports `drawElement` and friends from elements.ts.
enum ElementRenderer {
    static let tapeColor = "#fbbf24"
    static let textBgPadX = 8.0
    static let textBgPadY = 6.0

    private static let imageCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 40
        return c
    }()

    /// Decodes a `data:` URL to an image, cached by element id and payload length.
    static func image(for el: PageElement, src: String) -> UIImage? {
        let key = "\(el.id)-\(src.count)" as NSString
        if let hit = imageCache.object(forKey: key) { return hit }
        guard let comma = src.firstIndex(of: ","), src.hasPrefix("data:") else { return nil }
        let meta = src[src.startIndex..<comma]
        let payload = String(src[src.index(after: comma)...])
        let data: Data?
        if meta.contains(";base64") {
            data = Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
        } else {
            data = payload.removingPercentEncoding?.data(using: .utf8)
        }
        guard let d = data, let img = UIImage(data: d) else { return nil }
        imageCache.setObject(img, forKey: key)
        return img
    }

    /// Ink for an element colour on a paper (the `auto` token resolves from the paper).
    static func ink(_ color: String, _ paper: Paper) -> UIColor {
        UIColor.fromHex(PaperStyle.resolve(color, on: paper))
    }

    /// Draws one element. `peeled` draws a tape see-through (outline only) so it can be found and re-covered.
    static func draw(_ el: PageElement, in ctx: CGContext, paper: Paper, opacity: CGFloat = 1, peeled: Bool = false) {
        ctx.saveGState()
        ctx.setAlpha(opacity)
        if el.rotation != 0 {
            let cx = CGFloat(el.x + el.w / 2), cy = CGFloat(el.y + el.h / 2)
            ctx.translateBy(x: cx, y: cy)
            ctx.rotate(by: CGFloat(el.rotation))
            ctx.translateBy(x: -cx, y: -cy)
        }
        switch el.content {
        case .text(let t): drawText(el, t, ctx, paper)
        case .image(let i): drawImage(el, i, ctx)
        case .shape(let s): drawShape(el, s, ctx, paper)
        case .tape(let t): drawTape(el, t, ctx, peeled: peeled)
        case .bubble(let b): drawBubble(el, b, ctx, paper)
        case .connector(let k): drawConnector(k, ctx, paper)
        }
        ctx.restoreGState()
    }

    private static func rect(_ el: PageElement) -> CGRect {
        CGRect(x: el.x, y: el.y, width: el.w, height: el.h)
    }

    private static func drawTape(_ el: PageElement, _ t: PageElement.Tape, _ ctx: CGContext, peeled: Bool) {
        let color = UIColor.fromHex(t.color)
        ctx.setLineWidth(1.5)
        ctx.setStrokeColor(UIColor(white: 0, alpha: 0.25).cgColor)
        if peeled {
            ctx.setLineDash(phase: 0, lengths: [6, 4])
            ctx.setFillColor(color.withAlphaComponent(0.15).cgColor)
            ctx.fill(rect(el))
            ctx.stroke(rect(el))
            return
        }
        ctx.setFillColor(color.cgColor)
        ctx.fill(rect(el))
        ctx.stroke(rect(el).insetBy(dx: 0.75, dy: 0.75))
        // a faint sheen so it reads as a strip of tape rather than a flat box
        ctx.setFillColor(UIColor(white: 1, alpha: 0.28).cgColor)
        ctx.fill(CGRect(x: el.x, y: el.y, width: el.w, height: max(2, el.h * 0.3)))
    }

    private static func drawText(_ el: PageElement, _ t: PageElement.Text, _ ctx: CGContext, _ paper: Paper) {
        let lay = TextLayout.layout(t.text, fontSize: t.fontSize, maxWidth: el.w)
        if let bg = t.bg {
            let r = CGRect(x: el.x - textBgPadX, y: el.y - textBgPadY, width: el.w + textBgPadX * 2, height: el.h + textBgPadY * 2)
            ctx.setFillColor(UIColor.fromHex(bg).cgColor)
            ctx.addPath(UIBezierPath(roundedRect: r, cornerRadius: 6).cgPath)
            ctx.fillPath()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: TextLayout.font(t.fontSize), .foregroundColor: ink(t.color, paper)]
        let lead = (lay.lineHeight - t.fontSize) / 2 // half-leading, like CSS line-height
        UIGraphicsPushContext(ctx)
        for (i, line) in lay.lines.enumerated() where !line.isEmpty {
            (line as NSString).draw(at: CGPoint(x: el.x, y: el.y + Double(i) * lay.lineHeight + lead), withAttributes: attrs)
        }
        UIGraphicsPopContext()
    }

    private static func drawImage(_ el: PageElement, _ i: PageElement.Image, _ ctx: CGContext) {
        if let img = image(for: el, src: i.src) {
            UIGraphicsPushContext(ctx)
            img.draw(in: rect(el))
            UIGraphicsPopContext()
        } else {
            ctx.setFillColor(UIColor(white: 0.5, alpha: 0.15).cgColor)
            ctx.fill(rect(el))
        }
    }

    private static func drawShape(_ el: PageElement, _ s: PageElement.Shape, _ ctx: CGContext, _ paper: Paper) {
        ctx.setStrokeColor(ink(s.color, paper).cgColor)
        ctx.setLineWidth(CGFloat(s.size))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let cy = el.y + el.h / 2
        switch s.shape {
        case .rect:
            ctx.stroke(rect(el))
        case .ellipse:
            ctx.strokeEllipse(in: rect(el))
        case .triangle:
            let pts = s.pts ?? [[0.5, 0], [1, 1], [0, 1]]
            for (i, p) in pts.enumerated() {
                let pt = CGPoint(x: el.x + p[0] * el.w, y: el.y + p[1] * el.h)
                if i == 0 { ctx.move(to: pt) } else { ctx.addLine(to: pt) }
            }
            ctx.closePath()
            ctx.strokePath()
        case .line:
            ctx.move(to: CGPoint(x: el.x, y: cy))
            ctx.addLine(to: CGPoint(x: el.x + el.w, y: cy))
            ctx.strokePath()
        case .arrow:
            // shaft along the box's horizontal centreline, head at the right end
            let head = max(s.size * 4, 12)
            let tipX = el.x + el.w
            let dx = head * cos(Double.pi / 6), dy = head * sin(Double.pi / 6)
            ctx.move(to: CGPoint(x: el.x, y: cy))
            ctx.addLine(to: CGPoint(x: tipX, y: cy))
            ctx.move(to: CGPoint(x: tipX - dx, y: cy - dy))
            ctx.addLine(to: CGPoint(x: tipX, y: cy))
            ctx.addLine(to: CGPoint(x: tipX - dx, y: cy + dy))
            ctx.strokePath()
        }
    }

    private static func drawBubble(_ el: PageElement, _ b: PageElement.Bubble, _ ctx: CGContext, _ paper: Paper) {
        ctx.setStrokeColor(ink(b.color, paper).cgColor)
        ctx.setLineWidth(CGFloat(b.size))
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if b.outline == .ellipse {
            ctx.strokeEllipse(in: rect(el))
        } else {
            let r = min(el.w, el.h) * 0.22
            ctx.addPath(UIBezierPath(roundedRect: rect(el), cornerRadius: CGFloat(r)).cgPath)
            ctx.strokePath()
        }
    }

    private static func drawConnector(_ k: PageElement.Connector, _ ctx: CGContext, _ paper: Paper) {
        ctx.setStrokeColor(ink(k.color, paper).cgColor)
        ctx.setLineWidth(CGFloat(k.size))
        ctx.setLineCap(.round)
        ctx.move(to: CGPoint(x: k.ax, y: k.ay))
        ctx.addLine(to: CGPoint(x: k.bx, y: k.by))
        ctx.strokePath()
    }
}
