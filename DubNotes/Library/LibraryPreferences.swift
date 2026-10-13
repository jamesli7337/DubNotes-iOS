import Foundation

/// What the library remembers between launches: which folder rows are expanded, grid or list, and the sort.
/// The web keeps these in `localStorage` (`noteapp.folders.open`, `noteapp.notebooks.view`,
/// `noteapp.notebooks.sort`); here they live in `UserDefaults`.
struct LibraryPreferences: Equatable {
    enum Layout: String, CaseIterable {
        case grid, list
        var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    }

    enum Sort: String, CaseIterable {
        case manual = "Manual order"
        case updated = "Date modified"
        case created = "Date created"
        case name = "Name (A–Z)"
    }

    static let openKey = "dubnotes.folders.open"
    static let layoutKey = "dubnotes.notebooks.view"
    static let sortKey = "dubnotes.notebooks.sort"

    var openFolders: Set<String> = []
    var layout: Layout = .grid
    var sort: Sort = .manual

    static func load(from defaults: UserDefaults = .standard) -> LibraryPreferences {
        var p = LibraryPreferences()
        if let data = defaults.data(forKey: openKey),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            p.openFolders = Set(ids)
        }
        p.layout = defaults.string(forKey: layoutKey).flatMap(Layout.init(rawValue:)) ?? .grid
        p.sort = defaults.string(forKey: sortKey).flatMap(Sort.init(rawValue:)) ?? .manual
        return p
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(openFolders.sorted()) { defaults.set(data, forKey: Self.openKey) }
        defaults.set(layout.rawValue, forKey: Self.layoutKey)
        defaults.set(sort.rawValue, forKey: Self.sortKey)
    }

    /// Drops folder ids that no longer exist, so the stored set doesn't grow forever.
    mutating func prune(existing: Set<String>) {
        openFolders = openFolders.intersection(existing)
    }

    /// Orders notebooks for a non-manual sort; `manual` leaves the list as given.
    static func sorted(_ list: [Notebook], by sort: Sort) -> [Notebook] {
        switch sort {
        case .manual: return list
        case .updated: return list.sorted { $0.updatedAt > $1.updatedAt }
        case .created: return list.sorted { $0.createdAt > $1.createdAt }
        case .name: return list.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }
}

/// Cover colours and patterns offered by the cover picker (covers.ts).
enum CoverOptions {
    static let colors = ["#1b2a4a", "#0e7490", "#047857", "#b45309", "#be123c", "#6d28d9", "#374151", "#d97706"]
    static let patterns = ["dots", "grid", "stripes", "waves", "chevron"]

    /// The cover after tapping a colour: the pattern is kept.
    static func picking(color: String, from cover: Notebook.Cover?) -> Notebook.Cover {
        Notebook.Cover(color: color, pattern: cover?.pattern)
    }

    /// The cover after tapping a pattern; with no cover yet, the first colour is used. `nil` is "Plain".
    static func picking(pattern: String?, from cover: Notebook.Cover?) -> Notebook.Cover {
        Notebook.Cover(color: cover?.color ?? colors[0], pattern: pattern)
    }
}
