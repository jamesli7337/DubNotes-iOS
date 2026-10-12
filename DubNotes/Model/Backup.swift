import Foundation

/// A whole backup file, always at the current format version once decoded.
struct Backup: Codable, Equatable {
    static let app = "noteapp"
    static let currentVersion = 11

    var exportedAt: String?
    var notebooks: [Notebook]
    var pages: [Page]
    var strokes: [Stroke]
    var elements: [PageElement]
    var folders: [Folder]
    var dividers: [Divider]
    var assets: [Asset]

    init(exportedAt: String? = nil, notebooks: [Notebook] = [], pages: [Page] = [], strokes: [Stroke] = [],
         elements: [PageElement] = [], folders: [Folder] = [], dividers: [Divider] = [], assets: [Asset] = []) {
        self.exportedAt = exportedAt; self.notebooks = notebooks; self.pages = pages
        self.strokes = strokes; self.elements = elements; self.folders = folders
        self.dividers = dividers; self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case app, version, exportedAt, notebooks, pages, strokes, elements, folders, dividers, assets
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exportedAt = try c.decodeIfPresent(String.self, forKey: .exportedAt)
        notebooks = try c.decodeIfPresent([Notebook].self, forKey: .notebooks) ?? []
        pages = try c.decodeIfPresent([Page].self, forKey: .pages) ?? []
        strokes = try c.decodeIfPresent([Stroke].self, forKey: .strokes) ?? []
        elements = try c.decodeIfPresent([PageElement].self, forKey: .elements) ?? []
        folders = try c.decodeIfPresent([Folder].self, forKey: .folders) ?? []
        dividers = try c.decodeIfPresent([Divider].self, forKey: .dividers) ?? []
        assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(Backup.app, forKey: .app)
        try c.encode(Backup.currentVersion, forKey: .version)
        try c.encodeIfPresent(exportedAt, forKey: .exportedAt)
        try c.encode(notebooks, forKey: .notebooks)
        try c.encode(pages, forKey: .pages)
        try c.encode(strokes, forKey: .strokes)
        try c.encode(elements, forKey: .elements)
        try c.encode(folders, forKey: .folders)
        try c.encode(dividers, forKey: .dividers)
        try c.encode(assets, forKey: .assets)
    }
}

enum BackupError: Error, Equatable, LocalizedError {
    case notJSON
    case notNoteApp
    case invalidVersion
    case newerVersion(found: Int, supported: Int)
    case malformed(String)

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return "This file is not a DubNotes backup (it is not a JSON object)."
        case .notNoteApp:
            return "This file is not a DubNotes backup (its \"app\" field is not \"noteapp\")."
        case .invalidVersion:
            return "This backup has a missing or invalid version number."
        case .newerVersion(let found, let supported):
            return "This backup is format version \(found), but this app only understands up to version \(supported). Update the app and try again."
        case .malformed(let detail):
            return "This backup is damaged or incomplete: \(detail)"
        }
    }
}

struct BackupImportResult {
    var backup: Backup
    /// The version the file declared before it was upgraded.
    var sourceVersion: Int
    /// Non-fatal problems, e.g. skipped elements of an unknown kind.
    var warnings: [String]
}

enum BackupCodec {
    static func decode(_ data: Data) throws -> BackupImportResult {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let root = any as? [String: Any] else { throw BackupError.notJSON }
        guard root["app"] as? String == Backup.app else { throw BackupError.notNoteApp }
        guard let version = root["version"] as? Int, version >= 1 else { throw BackupError.invalidVersion }
        guard version <= Backup.currentVersion else {
            throw BackupError.newerVersion(found: version, supported: Backup.currentVersion)
        }

        var migrated = BackupMigration.migrate(root, from: version)

        var warnings: [String] = []
        var kept: [[String: Any]] = []
        for el in migrated["elements"] as? [[String: Any]] ?? [] {
            if let kind = el["kind"] as? String, PageElement.knownKinds.contains(kind) {
                kept.append(el)
            } else {
                let id = el["id"] as? String ?? "?"
                let kind = el["kind"] as? String ?? "(none)"
                warnings.append("Skipped element \(id): unknown kind '\(kind)'.")
            }
        }
        migrated["elements"] = kept

        do {
            let clean = try JSONSerialization.data(withJSONObject: migrated)
            let backup = try JSONDecoder().decode(Backup.self, from: clean)
            return BackupImportResult(backup: backup, sourceVersion: version, warnings: warnings)
        } catch let error as DecodingError {
            throw BackupError.malformed(describe(error))
        } catch {
            throw BackupError.malformed(error.localizedDescription)
        }
    }

    static func encode(_ backup: Backup) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(backup)
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ ctx: DecodingError.Context) -> String {
            ctx.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let ctx):
            return "missing \"\(key.stringValue)\" at \(path(ctx))"
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
            return "\(ctx.debugDescription) at \(path(ctx))"
        @unknown default:
            return error.localizedDescription
        }
    }
}
