import UIKit

/// Paper fill, ruling and page backgrounds (templates.ts, drawBackground in elements.ts).
enum PaperRenderer {
    /// Paints the page colour plus optional ruling. `unit` is how many device pixels one page unit covers, so
    /// hairlines stay one device pixel wide at any zoom.
    static func drawTemplate(_ paper: Paper, in ctx: CGContext, width w: Double, height h: Double, unit: Double = 1) {
        let ink = PaperStyle.ink(paper.color)
        let gap = PaperStyle.gap(paper.spacing)
        ctx.saveGState()
        ctx.setFillColor(UIColor.fromHex(ink.bg).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let rule = UIColor.fromHex(ink.rule)
        ctx.setStrokeColor(rule.cgColor)
        ctx.setLineWidth(CGFloat(1 / max(unit, 0.01)))
        switch paper.template {
        case .blank:
            break
        case .ruled:
            var y = gap * 1.5
            while y < h - 4 {
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y))
                y += gap
            }
            ctx.strokePath()
        case .grid:
            var x = gap
            while x < w {
                ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h))
                x += gap
            }
            var y = gap
            while y < h {
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y))
                y += gap
            }
            ctx.strokePath()
        case .dot:
            ctx.setFillColor(rule.cgColor)
            var x = gap
            while x < w {
                var y = gap
                while y < h {
                    ctx.fillEllipse(in: CGRect(x: x - 1.3, y: y - 1.3, width: 2.6, height: 2.6))
                    y += gap
                }
                x += gap
            }
        }
        ctx.restoreGState()
    }

    /// Pixel width a PDF background should be rendered at for a page `w` units wide shown at `unit` px/unit.
    static func backgroundPixelWidth(pageWidth w: Double, unit: Double) -> Int {
        let px = Int((w * unit).rounded(.up))
        // bucket to a multiple of 256 so a slow zoom doesn't re-render for every pixel of change
        return min(max(((px + 255) / 256) * 256, 512), 4096)
    }

    /// Paints a background image or a stored-PDF page over the paper. A PDF page fills the page full-bleed,
    /// scaled to cover and centre-cropped; a legacy image background is fitted inside and centred.
    /// `pdfImage` is the rendered PDF page if ready; a missing one draws a light placeholder (or the failure
    /// message when `pdfFailed`).
    static func drawBackground(_ page: Page, in ctx: CGContext, pdfImage: UIImage?, pdfFailed: Bool) {
        guard let bg = page.background else { return }
        let w = page.pageWidth, h = page.pageHeight
        switch bg {
        case .pdf:
            guard let img = pdfImage else {
                if pdfFailed {
                    let p = PaperStyle.placeholder(page.paper)
                    ctx.setFillColor(UIColor(p.bg).cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                    let attrs: [NSAttributedString.Key: Any] = [.font: TextLayout.font(22), .foregroundColor: UIColor(p.text)]
                    let text = "This page couldn't be rendered" as NSString
                    let size = text.size(withAttributes: attrs)
                    UIGraphicsPushContext(ctx)
                    text.draw(at: CGPoint(x: (w - Double(size.width)) / 2, y: (h - Double(size.height)) / 2), withAttributes: attrs)
                    UIGraphicsPopContext()
                } else {
                    ctx.setFillColor(UIColor(white: 0.5, alpha: 0.08).cgColor)
                    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                }
                return
            }
            let iw = Double(img.size.width), ih = Double(img.size.height)
            guard iw > 0, ih > 0 else { return }
            // cover + centre-crop: fills the page exactly, no paper margin around it
            let s = max(w / iw, h / ih)
            let dw = iw * s, dh = ih * s
            ctx.saveGState()
            ctx.clip(to: CGRect(x: 0, y: 0, width: w, height: h))
            UIGraphicsPushContext(ctx)
            img.draw(in: CGRect(x: (w - dw) / 2, y: (h - dh) / 2, width: dw, height: dh))
            UIGraphicsPopContext()
            ctx.restoreGState()
        case .image(let src):
            guard let comma = src.firstIndex(of: ","),
                  let data = Data(base64Encoded: String(src[src.index(after: comma)...]), options: .ignoreUnknownCharacters),
                  let img = UIImage(data: data) else { return }
            let iw = Double(img.size.width), ih = Double(img.size.height)
            guard iw > 0, ih > 0 else { return }
            let s = min(w / iw, h / ih)
            let dw = iw * s, dh = ih * s
            UIGraphicsPushContext(ctx)
            img.draw(in: CGRect(x: (w - dw) / 2, y: (h - dh) / 2, width: dw, height: dh))
            UIGraphicsPopContext()
        }
    }
}
