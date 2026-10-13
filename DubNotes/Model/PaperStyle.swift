import Foundation

/// An sRGB colour as 0...255 components, kept free of UIKit so tests and geometry can use it.
struct RGB: Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    /// `#rgb`, `#rrggbb` or `#rrggbbaa`; anything else is nil.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 || s.count == 4 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            self.init(Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF))
        } else {
            self.init(Double((v >> 24) & 0xFF), Double((v >> 16) & 0xFF), Double((v >> 8) & 0xFF), Double(v & 0xFF) / 255)
        }
    }

    var hex: String {
        func c(_ v: Double) -> String { String(format: "%02x", Int(max(0, min(255, v.rounded())))) }
        return "#\(c(r))\(c(g))\(c(b))"
    }
}

/// Paper colours, ruling and the "auto" ink token, mirroring templates.ts and freehand.ts.
enum PaperStyle {
    /// The literal stored in `Stroke.color` / element colours for ink that follows the paper.
    static let autoColor = "auto"

    struct Ink {
        let bg: String
        let rule: String
    }

    static func ink(_ color: Paper.Color) -> Ink {
        switch color {
        case .white: return Ink(bg: "#ffffff", rule: "#c7d2dd")
        case .cream: return Ink(bg: "#f8f2e2", rule: "#ddcda4")
        case .dark: return Ink(bg: "#1e2330", rule: "#3f4759")
        }
    }

    /// Ruling gap in page units.
    static func gap(_ spacing: Paper.Spacing) -> Double {
        switch spacing {
        case .narrow: return 26
        case .medium: return 38
        case .wide: return 54
        }
    }

    /// Auto ink: dark on light paper, light on dark paper.
    static func autoInk(_ color: Paper.Color) -> String {
        color == .dark ? "#f5f4ef" : "#1f2530"
    }

    /// Resolves a stored colour (a hex value or the `auto` token) against a paper.
    static func resolve(_ color: String, on paper: Paper) -> String {
        color == autoColor ? autoInk(paper.color) : color
    }

    static func isDark(_ paper: Paper) -> Bool { paper.color == .dark }

    /// Selection / handle accent for drawing over a paper, keyed on the paper (never the app theme).
    static func accent(_ paper: Paper) -> String { isDark(paper) ? "#8ca8ff" : "#2563eb" }

    /// Hairline frame round a thumbnail so an empty page still reads as a page.
    static func thumbFrame(_ paper: Paper) -> RGB {
        isDark(paper) ? RGB(255, 255, 255, 0.14) : RGB(4, 21, 52, 0.14)
    }

    /// Ruler / protractor colours (guideBody, guideEdge, guideInk, guideAccent, guideOnAccent).
    static func guideColors(_ paper: Paper) -> (body: RGB, edge: RGB, ink: RGB, accent: RGB, onAccent: RGB) {
        if isDark(paper) {
            return (RGB(30, 35, 48, 0.72), RGB(0x8e, 0x90, 0x99), RGB(0xc4, 0xc6, 0xd0), RGB(0xaf, 0xc6, 0xff), RGB(0x14, 0x2f, 0x60))
        }
        return (RGB(255, 255, 255, 0.72), RGB(0x70, 0x7b, 0x93), RGB(0x43, 0x4a, 0x59), RGB(0x04, 0x15, 0x34), RGB(255, 255, 255))
    }

    /// Placeholder colours for a background PDF page that failed to render.
    static func placeholder(_ paper: Paper) -> (bg: RGB, text: RGB) {
        isDark(paper) ? (RGB(0x2c, 0x31, 0x40), RGB(0xa3, 0xa9, 0xb8)) : (RGB(0xe3, 0xe1, 0xda), RGB(0x79, 0x76, 0x6c))
    }
}

/// Sizing rules for imported PDF pages and inserted images.
enum PageSizing {
    /// Converts one PDF page's point dimensions into page units: the source aspect ratio at the same total
    /// area as the default portrait page, so a landscape import reads wide and short rather than cropped.
    static func notebookPageSize(pdfWidth: Double, pdfHeight: Double) -> (w: Double, h: Double) {
        guard pdfWidth > 0, pdfHeight > 0 else { return (PageUnits.width, PageUnits.height) }
        let aspect = pdfWidth / pdfHeight
        let area = PageUnits.width * PageUnits.height
        return ((aspect * area).squareRoot().rounded(), (area / aspect).squareRoot().rounded())
    }

    /// Longest edge, in pixels, an inserted photo is downscaled to before it is stored inline.
    static let imageMaxEdge = 1600.0
    /// Files at or under this size are stored as-is.
    static let keepOriginalBytes = 1_500_000
    /// Fraction of the page an inserted image is fitted to.
    static let imageFit = 0.6

    /// Size (page units) of an inserted image: fitted inside `imageFit` of the page, never upscaled, at least 24.
    static func insertedImageSize(naturalW: Double, naturalH: Double, pageW: Double, pageH: Double) -> (w: Double, h: Double) {
        let s = min(pageW * imageFit / naturalW, pageH * imageFit / naturalH, 1)
        return (max(24, naturalW * s), max(24, naturalH * s))
    }

    /// Page units are CSS pixels at 96 dpi; exported PDFs are Letter width (612 pt) for the default page.
    static let pdfScale = 612.0 / PageUnits.width
}
