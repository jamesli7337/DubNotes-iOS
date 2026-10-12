import Foundation

/// A non-ink item: a box in page units plus kind-specific content.
struct PageElement: Codable, Equatable {
    struct Text: Equatable {
        var text: String
        var color: String
        var fontSize: Double
        /// Literal CSS tint behind the text (v8); never "auto".
        var bg: String?
    }
    struct Image: Equatable {
        /// `data:` URL, stored inline.
        var src: String
    }
    struct Shape: Equatable {
        enum Kind: String, Codable { case line, arrow, rect, ellipse, triangle }
        var shape: Kind
        var color: String
        var size: Double
        /// Triangle vertices as fractions of the box.
        var pts: [[Double]]?
    }
    struct Tape: Equatable {
        var color: String
    }
    struct Bubble: Equatable {
        enum Outline: String, Codable { case ellipse, roundrect }
        var outline: Outline
        var color: String
        var size: Double
        var members: [String]
    }
    struct Connector: Equatable {
        enum Node: String, Codable { case n, e, s, w }
        struct Anchor: Codable, Equatable {
            var bubbleId: String
            var node: Node
        }
        var a: Anchor
        var b: Anchor
        var color: String
        var size: Double
        var ax: Double
        var ay: Double
        var bx: Double
        var by: Double
    }

    enum Content: Equatable {
        case text(Text)
        case image(Image)
        case shape(Shape)
        case tape(Tape)
        case bubble(Bubble)
        case connector(Connector)
    }

    /// The `kind` strings this app understands. Anything else is skipped on import.
    static let knownKinds: Set<String> = ["text", "image", "shape", "tape", "bubble", "connector"]

    var id: String
    var pageId: String
    var notebookId: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    /// Radians about the box centre.
    var rotation: Double
    var createdAt: Double
    var content: Content

    private enum CodingKeys: String, CodingKey {
        case id, pageId, notebookId, kind, x, y, w, h, rotation, createdAt
        case text, color, fontSize, bg
        case src
        case shape, size, pts
        case outline, members
        case a, b, ax, ay, bx, by
    }

    init(id: String, pageId: String, notebookId: String, x: Double, y: Double, w: Double, h: Double,
         rotation: Double = 0, createdAt: Double, content: Content) {
        self.id = id; self.pageId = pageId; self.notebookId = notebookId
        self.x = x; self.y = y; self.w = w; self.h = h
        self.rotation = rotation; self.createdAt = createdAt; self.content = content
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        pageId = try c.decode(String.self, forKey: .pageId)
        notebookId = try c.decode(String.self, forKey: .notebookId)
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        w = try c.decode(Double.self, forKey: .w)
        h = try c.decode(Double.self, forKey: .h)
        rotation = try c.decode(Double.self, forKey: .rotation)
        createdAt = try c.decode(Double.self, forKey: .createdAt)

        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            content = .text(Text(text: try c.decode(String.self, forKey: .text),
                                 color: try c.decode(String.self, forKey: .color),
                                 fontSize: try c.decode(Double.self, forKey: .fontSize),
                                 bg: try c.decodeIfPresent(String.self, forKey: .bg)))
        case "image":
            content = .image(Image(src: try c.decode(String.self, forKey: .src)))
        case "shape":
            content = .shape(Shape(shape: try c.decode(Shape.Kind.self, forKey: .shape),
                                   color: try c.decode(String.self, forKey: .color),
                                   size: try c.decode(Double.self, forKey: .size),
                                   pts: try c.decodeIfPresent([[Double]].self, forKey: .pts)))
        case "tape":
            content = .tape(Tape(color: try c.decode(String.self, forKey: .color)))
        case "bubble":
            content = .bubble(Bubble(outline: try c.decode(Bubble.Outline.self, forKey: .outline),
                                     color: try c.decode(String.self, forKey: .color),
                                     size: try c.decode(Double.self, forKey: .size),
                                     members: try c.decode([String].self, forKey: .members)))
        case "connector":
            content = .connector(Connector(a: try c.decode(Connector.Anchor.self, forKey: .a),
                                           b: try c.decode(Connector.Anchor.self, forKey: .b),
                                           color: try c.decode(String.self, forKey: .color),
                                           size: try c.decode(Double.self, forKey: .size),
                                           ax: try c.decode(Double.self, forKey: .ax),
                                           ay: try c.decode(Double.self, forKey: .ay),
                                           bx: try c.decode(Double.self, forKey: .bx),
                                           by: try c.decode(Double.self, forKey: .by)))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c,
                                                   debugDescription: "unknown element kind '\(kind)'")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(pageId, forKey: .pageId)
        try c.encode(notebookId, forKey: .notebookId)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(w, forKey: .w)
        try c.encode(h, forKey: .h)
        try c.encode(rotation, forKey: .rotation)
        try c.encode(createdAt, forKey: .createdAt)

        switch content {
        case .text(let t):
            try c.encode("text", forKey: .kind)
            try c.encode(t.text, forKey: .text)
            try c.encode(t.color, forKey: .color)
            try c.encode(t.fontSize, forKey: .fontSize)
            try c.encodeIfPresent(t.bg, forKey: .bg)
        case .image(let i):
            try c.encode("image", forKey: .kind)
            try c.encode(i.src, forKey: .src)
        case .shape(let s):
            try c.encode("shape", forKey: .kind)
            try c.encode(s.shape, forKey: .shape)
            try c.encode(s.color, forKey: .color)
            try c.encode(s.size, forKey: .size)
            try c.encodeIfPresent(s.pts, forKey: .pts)
        case .tape(let t):
            try c.encode("tape", forKey: .kind)
            try c.encode(t.color, forKey: .color)
        case .bubble(let b):
            try c.encode("bubble", forKey: .kind)
            try c.encode(b.outline, forKey: .outline)
            try c.encode(b.color, forKey: .color)
            try c.encode(b.size, forKey: .size)
            try c.encode(b.members, forKey: .members)
        case .connector(let k):
            try c.encode("connector", forKey: .kind)
            try c.encode(k.a, forKey: .a)
            try c.encode(k.b, forKey: .b)
            try c.encode(k.color, forKey: .color)
            try c.encode(k.size, forKey: .size)
            try c.encode(k.ax, forKey: .ax)
            try c.encode(k.ay, forKey: .ay)
            try c.encode(k.bx, forKey: .bx)
            try c.encode(k.by, forKey: .by)
        }
    }
}
