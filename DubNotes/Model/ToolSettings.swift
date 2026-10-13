import Foundation

enum ToolKind: String, Codable, CaseIterable {
    case pen, highlighter, eraser, lasso, text, shapes, tape, laser, hand
}

enum EraserMode: String, Codable, CaseIterable {
    case whole, partial

    var label: String { self == .whole ? "Whole stroke" : "Partial" }
    var sub: String { self == .whole ? "Removes any stroke you touch" : "Removes only the parts you touch" }
}

/// How the lasso selects: a freehand loop, or a box / circle dragged from corner to corner.
enum LassoShape: String, Codable, CaseIterable {
    case free, box, circle
}

/// What the Shapes tool places on a drag.
enum PlacedShape: String, Codable, CaseIterable {
    case rect, ellipse, triangle, arrow
}

enum DockPosition: String, Codable {
    case top, bottom
}

enum InkTool: String {
    case pen, highlighter
}

/// Current tool, per-tool colour and size, swatch rows and dock layout; persisted between launches.
/// Port of tools.ts, with `UserDefaults` standing in for `localStorage`.
struct ToolSettings: Codable, Equatable {
    static let penColors = [PaperStyle.autoColor, "#2563eb", "#dc2626", "#059669", "#d97706"]
    static let highlighterColors = ["#fde047", "#fca5a5", "#86efac", "#93c5fd", "#f0abfc"]
    static let penSizeRange = 0.5...12.0
    static let highlighterSizeRange = 4.0...40.0
    static let customColorsMax = 8
    static let textDefaultSize = 20.0
    static let textDefaultWidth = 260.0
    static let laserColor = "#ef4444"
    static let laserFadeSeconds = 3.5
    static let defaultOrder: [ToolKind] = ToolKind.allCases

    var kind: ToolKind = .pen
    var penColor = ToolSettings.penColors[0]
    var penSize = 4.5
    var highlighterColor = ToolSettings.highlighterColors[0]
    var highlighterSize = 24.0
    var textColor = ToolSettings.penColors[0]
    var eraserMode: EraserMode = .whole
    var shapeKind: PlacedShape = .rect
    var lassoShape: LassoShape = .free
    /// Every swatch shown for a tool, presets and user-added colours interleaved in on-screen order.
    /// Position 0 is the tool's primary colour. Pen swatches also serve text and shapes.
    var penSwatches = ToolSettings.penColors
    var highlighterSwatches = ToolSettings.highlighterColors
    /// Presets dragged off the swatch row, offered back from the "add colour" popover.
    var penDeletedPresets: [String] = []
    var highlighterDeletedPresets: [String] = []
    var toolOrder: [ToolKind] = ToolSettings.defaultOrder
    var dockPosition: DockPosition = .top

    init() {}

    // MARK: Per-tool access

    static func presets(_ tool: InkTool) -> [String] { tool == .pen ? penColors : highlighterColors }
    static func sizeRange(_ tool: InkTool) -> ClosedRange<Double> { tool == .pen ? penSizeRange : highlighterSizeRange }

    func swatches(_ tool: InkTool) -> [String] { tool == .pen ? penSwatches : highlighterSwatches }
    func deletedPresets(_ tool: InkTool) -> [String] { tool == .pen ? penDeletedPresets : highlighterDeletedPresets }
    func color(_ tool: InkTool) -> String { tool == .pen ? penColor : highlighterColor }
    func size(_ tool: InkTool) -> Double { tool == .pen ? penSize : highlighterSize }

    mutating func setColor(_ tool: InkTool, _ c: String) {
        if tool == .pen { penColor = c } else { highlighterColor = c }
    }

    mutating func setSize(_ tool: InkTool, _ v: Double) {
        let r = Self.sizeRange(tool)
        let clamped = min(max(v, r.lowerBound), r.upperBound)
        if tool == .pen { penSize = clamped } else { highlighterSize = clamped }
    }

    private mutating func setSwatches(_ tool: InkTool, _ list: [String]) {
        if tool == .pen { penSwatches = list } else { highlighterSwatches = list }
    }

    private mutating func setDeleted(_ tool: InkTool, _ list: [String]) {
        if tool == .pen { penDeletedPresets = list } else { highlighterDeletedPresets = list }
    }

    private static func isPreset(_ tool: InkTool, _ c: String) -> Bool { presets(tool).contains(c) }

    // MARK: Swatch row

    /// Appends a user-picked colour (deduplicated); once the cap is hit the longest-standing custom colour goes.
    mutating func addCustomColor(_ tool: InkTool, hex: String) {
        let c = hex.lowercased()
        var list = swatches(tool).filter { $0 != c }
        let customCount = list.filter { !Self.isPreset(tool, $0) }.count
        if customCount >= Self.customColorsMax, let evict = list.firstIndex(where: { !Self.isPreset(tool, $0) }) {
            list.remove(at: evict)
        }
        list.append(c)
        setSwatches(tool, list)
    }

    /// Removes a swatch. The primary colour (position 0) can't be removed. A preset goes to the deleted list
    /// (offered back later); a custom colour is dropped for good.
    mutating func removeSwatch(_ tool: InkTool, _ color: String) {
        let list = swatches(tool)
        if list.first == color { return }
        setSwatches(tool, list.filter { $0 != color })
        if Self.isPreset(tool, color) {
            setDeleted(tool, [color] + deletedPresets(tool).filter { $0 != color })
        }
    }

    /// Commits a reordering of a swatch row; `order` must hold exactly the colours currently in the row.
    mutating func setSwatchOrder(_ tool: InkTool, _ order: [String]) {
        let current = swatches(tool)
        guard order.count == current.count, current.allSatisfy({ order.contains($0) }) else { return }
        setSwatches(tool, order)
    }

    /// Brings a deleted preset back at the end of the row.
    mutating func restorePreset(_ tool: InkTool, _ color: String) {
        setDeleted(tool, deletedPresets(tool).filter { $0 != color })
        if !swatches(tool).contains(color) { setSwatches(tool, swatches(tool) + [color]) }
    }

    /// Resets pen / highlighter / text ink to each tool's primary colour (when leaving a notebook).
    mutating func resetActiveColorsToPrimary() {
        penColor = penSwatches[0]
        highlighterColor = highlighterSwatches[0]
        textColor = penSwatches[0]
    }

    // MARK: Tool order

    /// Commits a reordering of the dock. `order` only has to hold the tools that were on screen: each is dealt
    /// back into the slots those tools already occupied.
    mutating func setToolOrder(_ order: [ToolKind]) {
        let moving = Set(order)
        guard order.count == moving.count, order.allSatisfy({ toolOrder.contains($0) }) else { return }
        var next: [ToolKind] = []
        var i = 0
        for k in toolOrder {
            if moving.contains(k) {
                next.append(order[i])
                i += 1
            } else {
                next.append(k)
            }
        }
        toolOrder = next
    }

    /// Drops duplicates, then appends any tool the stored order predates.
    static func cleanToolOrder(_ v: [ToolKind]) -> [ToolKind] {
        var out: [ToolKind] = []
        for k in v where !out.contains(k) { out.append(k) }
        for k in defaultOrder where !out.contains(k) { out.append(k) }
        return out
    }

    // MARK: Cleaning

    private static func cleanSwatches(_ v: [String], _ tool: InkTool) -> [String] {
        var out: [String] = []
        for c in v {
            guard c == PaperStyle.autoColor || RGB(hex: c) != nil else { continue }
            let norm = c == PaperStyle.autoColor ? c : c.lowercased()
            if !out.contains(norm) { out.append(norm) }
        }
        return out.isEmpty ? presets(tool) : out
    }

    /// Repairs whatever was stored: ranges, duplicates, an active colour that is no longer in its row.
    mutating func clean() {
        penSize = min(max(penSize, Self.penSizeRange.lowerBound), Self.penSizeRange.upperBound)
        highlighterSize = min(max(highlighterSize, Self.highlighterSizeRange.lowerBound), Self.highlighterSizeRange.upperBound)
        penSwatches = Self.cleanSwatches(penSwatches, .pen)
        highlighterSwatches = Self.cleanSwatches(highlighterSwatches, .highlighter)
        penDeletedPresets = penDeletedPresets.filter { Self.penColors.contains($0) }
        highlighterDeletedPresets = highlighterDeletedPresets.filter { Self.highlighterColors.contains($0) }
        toolOrder = Self.cleanToolOrder(toolOrder)
        if !penSwatches.contains(penColor) { penColor = penSwatches[0] }
        if !highlighterSwatches.contains(highlighterColor) { highlighterColor = highlighterSwatches[0] }
        if !penSwatches.contains(textColor) { textColor = penSwatches[0] }
    }

    // MARK: Codable (tolerant of missing or unknown keys)

    private enum CodingKeys: String, CodingKey {
        case kind, penColor, penSize, highlighterColor, highlighterSize, textColor, eraserMode, shapeKind, lassoShape
        case penSwatches, highlighterSwatches, penDeletedPresets, highlighterDeletedPresets, toolOrder, dockPosition
    }

    init(from decoder: Decoder) throws {
        self.init()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = (try? c.decodeIfPresent(ToolKind.self, forKey: .kind)) ?? kind
        penColor = (try? c.decodeIfPresent(String.self, forKey: .penColor)) ?? penColor
        penSize = (try? c.decodeIfPresent(Double.self, forKey: .penSize)) ?? penSize
        highlighterColor = (try? c.decodeIfPresent(String.self, forKey: .highlighterColor)) ?? highlighterColor
        highlighterSize = (try? c.decodeIfPresent(Double.self, forKey: .highlighterSize)) ?? highlighterSize
        textColor = (try? c.decodeIfPresent(String.self, forKey: .textColor)) ?? textColor
        eraserMode = (try? c.decodeIfPresent(EraserMode.self, forKey: .eraserMode)) ?? eraserMode
        shapeKind = (try? c.decodeIfPresent(PlacedShape.self, forKey: .shapeKind)) ?? shapeKind
        lassoShape = (try? c.decodeIfPresent(LassoShape.self, forKey: .lassoShape)) ?? lassoShape
        penSwatches = (try? c.decodeIfPresent([String].self, forKey: .penSwatches)) ?? penSwatches
        highlighterSwatches = (try? c.decodeIfPresent([String].self, forKey: .highlighterSwatches)) ?? highlighterSwatches
        penDeletedPresets = (try? c.decodeIfPresent([String].self, forKey: .penDeletedPresets)) ?? penDeletedPresets
        highlighterDeletedPresets = (try? c.decodeIfPresent([String].self, forKey: .highlighterDeletedPresets)) ?? highlighterDeletedPresets
        if let names = try? c.decodeIfPresent([String].self, forKey: .toolOrder) {
            toolOrder = names.compactMap(ToolKind.init(rawValue:))
        }
        dockPosition = (try? c.decodeIfPresent(DockPosition.self, forKey: .dockPosition)) ?? dockPosition
        clean()
    }

    // MARK: Persistence

    static let storageKey = "dubnotes.tools"

    static func load(from defaults: UserDefaults = .standard) -> ToolSettings {
        guard let data = defaults.data(forKey: storageKey),
              let s = try? JSONDecoder().decode(ToolSettings.self, from: data) else {
            var fresh = ToolSettings()
            fresh.clean()
            return fresh
        }
        return s
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey) }
    }
}

extension Array where Element: Equatable {
    /// The list with `item` taken out and put in front of `target`. Unchanged if either is missing or they match.
    func moving(_ item: Element, before target: Element) -> [Element] {
        guard item != target, contains(item), contains(target) else { return self }
        var out = self
        out.removeAll { $0 == item }
        guard let at = out.firstIndex(of: target) else { return self }
        out.insert(item, at: at)
        return out
    }

    /// The list with `item` moved to the end.
    func movingToEnd(_ item: Element) -> [Element] {
        guard contains(item) else { return self }
        var out = self
        out.removeAll { $0 == item }
        out.append(item)
        return out
    }
}
