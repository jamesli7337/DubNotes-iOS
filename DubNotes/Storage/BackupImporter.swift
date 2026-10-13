import Foundation

/// Restoring a backup adds its contents to the library as new copies; it never replaces anything. Every id is
/// replaced with a fresh one and every reference between records follows.
enum BackupImporter {
    struct Result {
        var backup: Backup
        var warnings: [String]
    }

    /// `newId` is injectable so tests can be deterministic.
    static func makeCopies(of source: Backup, newId: () -> String = { UUID().uuidString }) -> Result {
        var warnings: [String] = []
        var folderMap: [String: String] = [:]
        var notebookMap: [String: String] = [:]
        var pageMap: [String: String] = [:]
        var assetMap: [String: String] = [:]
        var itemMap: [String: String] = [:]

        for f in source.folders { folderMap[f.id] = newId() }
        for n in source.notebooks { notebookMap[n.id] = newId() }
        for a in source.assets { assetMap[a.id] = newId() }
        for s in source.strokes { itemMap[s.id] = newId() }
        for e in source.elements { itemMap[e.id] = newId() }

        var out = Backup()
        out.exportedAt = source.exportedAt

        out.folders = source.folders.map { f in
            var c = f
            c.id = folderMap[f.id] ?? f.id
            c.parentId = f.parentId.flatMap { folderMap[$0] }
            return c
        }
        out.dividers = source.dividers.map { d in
            var c = d
            c.id = newId()
            c.folderId = d.folderId.flatMap { folderMap[$0] }
            return c
        }
        out.notebooks = source.notebooks.map { n in
            var c = n
            c.id = notebookMap[n.id] ?? n.id
            c.folderId = n.folderId.flatMap { folderMap[$0] }
            return c
        }
        for a in source.assets {
            guard let nb = notebookMap[a.notebookId] else {
                warnings.append("Skipped asset \(a.name): its notebook is not in the backup.")
                continue
            }
            var c = a
            c.id = assetMap[a.id] ?? a.id
            c.notebookId = nb
            out.assets.append(c)
        }

        for p in source.pages {
            guard let nb = notebookMap[p.notebookId] else {
                warnings.append("Skipped page \(p.id): its notebook is not in the backup.")
                continue
            }
            var c = p
            c.notebookId = nb
            if let col = p.col, let row = p.row {
                c.id = "\(nb):\(col),\(row)" // board chunks are addressed by their cell
            } else {
                c.id = newId()
            }
            if case .pdf(let assetId, let page)? = p.background {
                if let mapped = assetMap[assetId] {
                    c.background = .pdf(assetId: mapped, page: page)
                } else {
                    c.background = nil
                    warnings.append("Page \(p.id) pointed at a missing PDF; its background was dropped.")
                }
            }
            pageMap[p.id] = c.id
            out.pages.append(c)
        }

        for s in source.strokes {
            guard let page = pageMap[s.pageId], let nb = notebookMap[s.notebookId] else { continue }
            var c = s
            c.id = itemMap[s.id] ?? s.id
            c.pageId = page
            c.notebookId = nb
            out.strokes.append(c)
        }

        for e in source.elements {
            guard let page = pageMap[e.pageId], let nb = notebookMap[e.notebookId] else { continue }
            var c = e
            c.id = itemMap[e.id] ?? e.id
            c.pageId = page
            c.notebookId = nb
            switch e.content {
            case .bubble(var b):
                b.members = b.members.compactMap { itemMap[$0] }
                c.content = .bubble(b)
            case .connector(var k):
                if let a = itemMap[k.a.bubbleId], let b = itemMap[k.b.bubbleId] {
                    k.a.bubbleId = a
                    k.b.bubbleId = b
                    c.content = .connector(k)
                } else {
                    continue // a link to half a pair has no meaning
                }
            default:
                break
            }
            out.elements.append(c)
        }
        out.exportedAt = source.exportedAt
        return Result(backup: out, warnings: warnings)
    }
}
