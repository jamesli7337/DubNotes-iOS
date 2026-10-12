import SwiftUI

/// A notebook cover: the colour with the chosen pattern drawn over it in translucent white.
/// Mirrors covers.ts; an unknown pattern falls back to the plain colour.
struct CoverView: View {
    let cover: Notebook.Cover?
    var isBoard = false

    var body: some View {
        if let cover {
            ZStack {
                Color(hex: cover.color)
                Canvas { context, size in
                    Self.drawPattern(cover.pattern, in: &context, size: size)
                }
            }
        } else {
            Rectangle()
                .fill(Color(.tertiarySystemFill))
                .overlay {
                    Image(systemName: isBoard ? "square.grid.2x2" : "book.closed")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                }
        }
    }

    private static func drawPattern(_ pattern: String?, in context: inout GraphicsContext, size: CGSize) {
        let ink = GraphicsContext.Shading.color(.white.opacity(0.4))
        switch pattern {
        case "dots":
            for y in stride(from: 7.0, to: size.height + 14, by: 14.0) {
                for x in stride(from: 7.0, to: size.width + 14, by: 14.0) {
                    context.fill(Path(ellipseIn: CGRect(x: x - 2, y: y - 2, width: 4, height: 4)), with: ink)
                }
            }
        case "grid":
            var path = Path()
            for x in stride(from: 0.0, through: size.width, by: 16.0) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0.0, through: size.height, by: 16.0) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: ink, lineWidth: 1)
        case "stripes":
            // 6pt stripes every 16pt measured across the stripe, at 45 degrees.
            var path = Path()
            for x in stride(from: -size.height, through: size.width, by: 16 * 2.0.squareRoot()) {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(path, with: ink, lineWidth: 6)
        case "waves":
            var path = Path()
            for ty in stride(from: 0.0, to: size.height, by: 16.0) {
                for tx in stride(from: 0.0, to: size.width, by: 32.0) {
                    path.move(to: CGPoint(x: tx, y: ty + 8))
                    path.addQuadCurve(to: CGPoint(x: tx + 16, y: ty + 8), control: CGPoint(x: tx + 8, y: ty))
                    path.addQuadCurve(to: CGPoint(x: tx + 32, y: ty + 8), control: CGPoint(x: tx + 24, y: ty + 16))
                }
            }
            context.stroke(path, with: ink, lineWidth: 2)
        case "chevron":
            var path = Path()
            for ty in stride(from: 0.0, to: size.height, by: 14.0) {
                for tx in stride(from: 0.0, to: size.width, by: 20.0) {
                    path.move(to: CGPoint(x: tx, y: ty + 12))
                    path.addLine(to: CGPoint(x: tx + 10, y: ty + 2))
                    path.addLine(to: CGPoint(x: tx + 20, y: ty + 12))
                }
            }
            context.stroke(path, with: ink, lineWidth: 2)
        default:
            break
        }
    }
}

extension Color {
    /// `#rgb` or `#rrggbb`. Anything else renders as grey rather than failing.
    init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        guard s.count == 6, Scanner(string: s).scanHexInt64(&value) else {
            self = .gray
            return
        }
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}
