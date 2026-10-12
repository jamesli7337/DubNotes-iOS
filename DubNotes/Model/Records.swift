import Foundation

/// Default page size in page units. A page may carry its own `w`/`h`.
enum PageUnits {
    static let width = 820.0
    static let height = 1060.0
}

struct Paper: Codable, Equatable {
    enum Template: String, Codable { case blank, ruled, grid, dot }
    enum Spacing: String, Codable { case narrow, medium, wide }
    enum Color: String, Codable { case white, cream, dark }

    var template: Template
    var spacing: Spacing
    var color: Color

    static let `default` = Paper(template: .blank, spacing: .medium, color: .white)
}

struct Notebook: Codable, Equatable {
    enum Kind: String, Codable { case pages, board }
    struct Cover: Codable, Equatable {
        var color: String
        /// dots | grid | stripes | waves | chevron. Kept as a string so an unknown pattern survives a round trip.
        var pattern: String?
    }

    var id: String
    var name: String
    /// Absent means a paged notebook.
    var kind: Kind?
    var folderId: String?
    var order: Double
    var cover: Cover?
    var createdAt: Double
    var updatedAt: Double

    var isBoard: Bool { kind == .board }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, folderId, order, cover, createdAt, updatedAt
    }

    init(id: String, name: String, kind: Kind? = nil, folderId: String? = nil, order: Double = 0,
         cover: Cover? = nil, createdAt: Double, updatedAt: Double) {
        self.id = id; self.name = name; self.kind = kind; self.folderId = folderId; self.order = order
        self.cover = cover; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        order = try c.decode(Double.self, forKey: .order)
        cover = try c.decodeIfPresent(Cover.self, forKey: .cover)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(folderId, forKey: .folderId) // explicit null = library root
        try c.encode(order, forKey: .order)
        try c.encodeIfPresent(cover, forKey: .cover)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

struct Folder: Codable, Equatable {
    var id: String
    var name: String
    var parentId: String?
    var createdAt: Double
    var updatedAt: Double

    private enum CodingKeys: String, CodingKey { case id, name, parentId, createdAt, updatedAt }

    init(id: String, name: String, parentId: String? = nil, createdAt: Double, updatedAt: Double) {
        self.id = id; self.name = name; self.parentId = parentId
        self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        parentId = try c.decodeIfPresent(String.self, forKey: .parentId)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        updatedAt = try c.decode(Double.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(parentId, forKey: .parentId)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

struct Divider: Codable, Equatable {
    var id: String
    var folderId: String?
    var label: String
    var order: Double
    var createdAt: Double

    private enum CodingKeys: String, CodingKey { case id, folderId, label, order, createdAt }

    init(id: String, folderId: String? = nil, label: String, order: Double, createdAt: Double) {
        self.id = id; self.folderId = folderId; self.label = label; self.order = order; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        label = try c.decode(String.self, forKey: .label)
        order = try c.decode(Double.self, forKey: .order)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(folderId, forKey: .folderId)
        try c.encode(label, forKey: .label)
        try c.encode(order, forKey: .order)
        try c.encode(createdAt, forKey: .createdAt)
    }
}

/// Drawn over the paper fill, under everything else.
enum PageBackground: Codable, Equatable {
    /// v5: a `data:` URL of a pre-rendered page image, fitted inside the page.
    case image(src: String)
    /// v7: 1-based page of a stored PDF asset, drawn full-bleed.
    case pdf(assetId: String, page: Int)

    private enum CodingKeys: String, CodingKey { case src, assetId, page }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let assetId = try c.decodeIfPresent(String.self, forKey: .assetId) {
            self = .pdf(assetId: assetId, page: try c.decode(Int.self, forKey: .page))
        } else {
            self = .image(src: try c.decode(String.self, forKey: .src))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .image(let src):
            try c.encode(src, forKey: .src)
        case .pdf(let assetId, let page):
            try c.encode(assetId, forKey: .assetId)
            try c.encode(page, forKey: .page)
        }
    }
}

struct Page: Codable, Equatable {
    var id: String
    var notebookId: String
    var index: Int
    var paper: Paper
    var background: PageBackground?
    /// Own size in page units when it differs from 820x1060 (PDF pages).
    var w: Double?
    var h: Double?
    /// Board storage chunk cell; present together or not at all.
    var col: Int?
    var row: Int?
    var createdAt: Double
    var updatedAt: Double

    var pageWidth: Double { w ?? PageUnits.width }
    var pageHeight: Double { h ?? PageUnits.height }
}

/// One raw input sample, serialised as `[x, y, pressure]`.
struct StrokePoint: Codable, Equatable {
    var x: Double
    var y: Double
    var pressure: Double

    init(x: Double, y: Double, pressure: Double = 0.5) {
        self.x = x; self.y = y; self.pressure = pressure
    }

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        x = try c.decode(Double.self)
        y = try c.decode(Double.self)
        pressure = try c.isAtEnd ? 0.5 : c.decode(Double.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(x)
        try c.encode(y)
        try c.encode(pressure)
    }
}

struct Stroke: Codable, Equatable {
    enum Tool: String, Codable { case pen, highlighter }

    var id: String
    var pageId: String
    var notebookId: String
    var tool: Tool
    /// A CSS colour, or the literal `"auto"` (resolved at render time from the paper).
    var color: String
    var size: Double
    var points: [StrokePoint]
    var createdAt: Double
}

struct Asset: Codable, Equatable {
    enum Kind: String, Codable { case pdf }

    var id: String
    var notebookId: String
    var kind: Kind
    var name: String
    var pages: Int
    var data: Data

    private enum CodingKeys: String, CodingKey { case id, notebookId, kind, name, pages, dataBase64 }

    init(id: String, notebookId: String, kind: Kind = .pdf, name: String, pages: Int, data: Data) {
        self.id = id; self.notebookId = notebookId; self.kind = kind
        self.name = name; self.pages = pages; self.data = data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        notebookId = try c.decode(String.self, forKey: .notebookId)
        kind = try c.decode(Kind.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        pages = try c.decode(Int.self, forKey: .pages)
        let b64 = try c.decode(String.self, forKey: .dataBase64)
        guard let bytes = Data(base64Encoded: b64) else {
            throw DecodingError.dataCorruptedError(forKey: .dataBase64, in: c,
                                                   debugDescription: "asset \(id) has invalid base64")
        }
        data = bytes
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(notebookId, forKey: .notebookId)
        try c.encode(kind, forKey: .kind)
        try c.encode(name, forKey: .name)
        try c.encode(pages, forKey: .pages)
        try c.encode(data.base64EncodedString(), forKey: .dataBase64)
    }
}
