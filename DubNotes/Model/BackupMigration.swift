import Foundation

/// Upgrades a parsed backup (untyped JSON) to format v11, following the
/// "Migration" section of DATA_FORMAT.md. Steps are gated on the file's
/// declared version; v6 -> v11 added only optional fields and element kinds,
/// so nothing needs rewriting past v6.
enum BackupMigration {
    typealias Record = [String: Any]

    static func migrate(_ root: Record, from version: Int) -> Record {
        var root = root
        var notebooks = records(root["notebooks"])
        var pages = records(root["pages"])
        var strokes = records(root["strokes"])
        var elements = records(root["elements"])
        var folders = records(root["folders"])
        var dividers = records(root["dividers"])

        if version < 2 {
            // Template moves from the notebook onto each page as `paper`.
            var templates: [String: String] = [:]
            for i in notebooks.indices {
                if let id = notebooks[i]["id"] as? String, let t = notebooks[i]["template"] as? String {
                    templates[id] = t
                }
                notebooks[i].removeValue(forKey: "template")
            }
            for i in pages.indices where !(pages[i]["paper"] is Record) {
                let old = (pages[i]["notebookId"] as? String).flatMap { templates[$0] }
                let template: String
                switch old {
                case "lined": template = "ruled"
                case "grid": template = "grid"
                default: template = "blank"
                }
                pages[i]["paper"] = ["template": template, "spacing": "medium", "color": "white"]
            }
        }

        if version < 3 {
            for i in strokes.indices where strokes[i]["color"] as? String == "#1f2530" {
                strokes[i]["color"] = "auto"
            }
        }

        if version < 4 {
            for i in elements.indices where !(elements[i]["rotation"] is Double) {
                elements[i]["rotation"] = 0
            }
        }

        if version < 6 {
            let folderIds = Set(folders.compactMap { $0["id"] as? String })
            for i in folders.indices {
                if let p = folders[i]["parentId"] as? String, folderIds.contains(p) { continue }
                folders[i]["parentId"] = NSNull()
            }
            for i in dividers.indices {
                if let f = dividers[i]["folderId"] as? String, folderIds.contains(f) { continue }
                dividers[i]["folderId"] = NSNull()
            }
            for i in notebooks.indices {
                if let f = notebooks[i]["folderId"] as? String, folderIds.contains(f) { continue }
                notebooks[i]["folderId"] = NSNull()
            }
            // Number notebooks without `order` most-recently-edited first.
            let unordered = notebooks.indices.filter { !(notebooks[$0]["order"] is Double) }
            let ranked = unordered.sorted { l, r in
                let lu = notebooks[l]["updatedAt"] as? Double ?? 0
                let ru = notebooks[r]["updatedAt"] as? Double ?? 0
                return lu != ru ? lu > ru : l < r
            }
            for (rank, i) in ranked.enumerated() { notebooks[i]["order"] = rank }
        }

        root["notebooks"] = notebooks
        root["pages"] = pages
        root["strokes"] = strokes
        root["elements"] = elements
        root["folders"] = folders
        root["dividers"] = dividers
        return root
    }

    private static func records(_ any: Any?) -> [Record] {
        (any as? [Any])?.compactMap { $0 as? Record } ?? []
    }
}
