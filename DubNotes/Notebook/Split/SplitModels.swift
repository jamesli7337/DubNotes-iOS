import Foundation

/// A rectangle for a floating split pane or image overlay, in points.
struct FloatRect: Codable, Equatable {
    var x: Double
    var y: Double
    var w: Double
    var h: Double

    static let defaultRect = FloatRect(x: 80, y: 120, w: 420, h: 560)
    static let minW = 220.0
    static let minH = 200.0

    /// Keeps the rectangle inside a container of the given size, never smaller than the minimum.
    func clamped(in size: (w: Double, h: Double)) -> FloatRect {
        let w = min(max(self.w, Self.minW), max(size.w, Self.minW))
        let h = min(max(self.h, Self.minH), max(size.h, Self.minH))
        let x = min(max(self.x, 0), max(size.w - w, 0))
        let y = min(max(self.y, 0), max(size.h - h, 0))
        return FloatRect(x: x, y: y, w: w, h: h)
    }
}

/// A split-screen reference shown beside (or over) the notebook being edited: another notebook's pages, a
/// reference PDF, or an image floating over the page. Belongs to the notebook it was opened in.
struct SplitState: Codable, Equatable {
    enum Kind: String, Codable { case page, image, pdf }

    var kind: Kind
    /// Page splits: the notebook being shown.
    var notebookId: String?
    /// PDF and image splits: the file's own name, shown in the pane header.
    var fileName: String?
    /// File extension of the stored payload (pdf / png / jpg …).
    var payloadExtension: String?
    var floating = false
    var float = FloatRect.defaultRect
    /// Width of a docked pane as a fraction of the screen.
    var fraction = 0.45

    static let fractionRange = 0.25...0.7
}

/// Persistence for splits, per host notebook. The state is small and lives in `UserDefaults`; a reference
/// file's bytes go in their own folder, deliberately outside the notebook's files and its backup.
enum SplitStore {
    static func key(_ hostId: String) -> String { "dubnotes.split.\(hostId)" }

    static func load(hostId: String, defaults: UserDefaults = .standard) -> SplitState? {
        guard let data = defaults.data(forKey: key(hostId)) else { return nil }
        return try? JSONDecoder().decode(SplitState.self, from: data)
    }

    static func save(_ state: SplitState?, hostId: String, defaults: UserDefaults = .standard) {
        if let state, let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: key(hostId))
        } else {
            defaults.removeObject(forKey: key(hostId))
        }
    }

    static var payloadDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DubNotes/SplitReferences", isDirectory: true)
    }

    static func payloadURL(hostId: String, ext: String, directory: URL = payloadDirectory) -> URL {
        directory.appendingPathComponent("\(hostId).\(ext)")
    }

    /// Stores a reference file for a host notebook, replacing any earlier one.
    static func writePayload(_ data: Data, hostId: String, ext: String, directory: URL = payloadDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        removePayload(hostId: hostId, directory: directory)
        let url = payloadURL(hostId: hostId, ext: ext, directory: directory)
        try data.write(to: url, options: .atomic)
        return url
    }

    static func removePayload(hostId: String, directory: URL = payloadDirectory) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for n in names where n.hasPrefix("\(hostId).") { try? FileManager.default.removeItem(at: directory.appendingPathComponent(n)) }
    }
}
