import XCTest
@testable import DubNotes

/// Builders for small records, and a scratch directory per test.
enum Make {
    static func notebook(_ id: String = "nb1", name: String = "Notes", folderId: String? = nil, order: Double = 0,
                         updatedAt: Double = 1000) -> Notebook {
        Notebook(id: id, name: name, folderId: folderId, order: order, createdAt: 1000, updatedAt: updatedAt)
    }

    static func page(_ id: String, nb: String = "nb1", index: Int = 0, paper: Paper = .default) -> Page {
        Page(id: id, notebookId: nb, index: index, paper: paper, createdAt: 1000, updatedAt: 1000)
    }

    static func stroke(_ id: String, page: String = "p1", nb: String = "nb1", points: [(Double, Double)] = [(0, 0), (10, 0)],
                       tool: Stroke.Tool = .pen, color: String = "auto", size: Double = 4, at: Double = 1) -> Stroke {
        Stroke(id: id, pageId: page, notebookId: nb, tool: tool, color: color, size: size,
               points: points.map { StrokePoint(x: $0.0, y: $0.1, pressure: 0.5) }, createdAt: at)
    }

    static func text(_ id: String, page: String = "p1", nb: String = "nb1", x: Double = 10, y: Double = 10,
                     w: Double = 100, h: Double = 26, at: Double = 2) -> PageElement {
        PageElement(id: id, pageId: page, notebookId: nb, x: x, y: y, w: w, h: h, createdAt: at,
                    content: .text(PageElement.Text(text: "hi", color: "auto", fontSize: 20, bg: nil)))
    }

    static func shape(_ id: String, page: String = "p1", nb: String = "nb1", kind: PageElement.Shape.Kind = .rect,
                      x: Double = 0, y: Double = 0, w: Double = 100, h: Double = 50, at: Double = 3) -> PageElement {
        PageElement(id: id, pageId: page, notebookId: nb, x: x, y: y, w: w, h: h, createdAt: at,
                    content: .shape(PageElement.Shape(shape: kind, color: "#000000", size: 2, pts: nil)))
    }

    static func tape(_ id: String, page: String = "p1", nb: String = "nb1", at: Double = 4) -> PageElement {
        PageElement(id: id, pageId: page, notebookId: nb, x: 0, y: 0, w: 50, h: 20, createdAt: at,
                    content: .tape(PageElement.Tape(color: "#fbbf24")))
    }

    /// A document with `count` pages `p0…`, the last one blank unless `fillLast`.
    static func document(pages count: Int = 3, fillLast: Bool = false) -> NotebookDocument {
        let pages = (0..<count).map { page("p\($0)", index: $0) }
        var strokes: [Stroke] = []
        for i in 0..<(fillLast ? count : count - 1) { strokes.append(stroke("s\(i)", page: "p\(i)")) }
        return NotebookDocument(notebook: notebook(), pages: pages, strokes: strokes)
    }

    /// Points on a circle (page units).
    static func circle(cx: Double, cy: Double, r: Double, n: Int = 60, turns: Double = 1.02) -> [Pt] {
        (0...n).map { i in
            let a = Double(i) / Double(n) * Double.pi * 2 * turns
            return Pt(cx + r * cos(a), cy + r * sin(a))
        }
    }

    /// A polyline through corners, with `per` samples along each side.
    static func polygon(_ corners: [Pt], per: Int = 20, closed: Bool = true) -> [Pt] {
        var out: [Pt] = []
        let n = corners.count
        let sides = closed ? n : n - 1
        for s in 0..<sides {
            let a = corners[s], b = corners[(s + 1) % n]
            for i in 0..<per {
                let t = Double(i) / Double(per)
                out.append(Pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t))
            }
        }
        out.append(closed ? corners[0] : corners[n - 1])
        return out
    }
}

class ScratchTestCase: XCTestCase {
    var scratch: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false // later lines index into results; stop at the first failure instead of trapping
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("DubNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    func fixtureData() throws -> Data {
        if let url = Bundle(for: ScratchTestCase.self).url(forResource: "backup-sample", withExtension: "json") {
            return try Data(contentsOf: url)
        }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/backup-sample.json")
        return try Data(contentsOf: url)
    }
}
