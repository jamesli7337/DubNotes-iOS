import Foundation
import Observation

/// In-memory library, seeded from the bundled sample backup. Nothing is persisted yet.
@Observable
final class LibraryStore {
    var notebooks: [Notebook] = []
    var loadError: String?
    private var pageCounts: [String: Int] = [:]
    private var itemCounts: [String: Int] = [:]

    init() {
        guard let url = Bundle.main.url(forResource: "backup-sample", withExtension: "json") else {
            loadError = "backup-sample.json is missing from the app bundle."
            return
        }
        do {
            let backup = try BackupCodec.decode(Data(contentsOf: url)).backup
            notebooks = backup.notebooks
            for page in backup.pages { pageCounts[page.notebookId, default: 0] += 1 }
            for stroke in backup.strokes { itemCounts[stroke.notebookId, default: 0] += 1 }
            for element in backup.elements { itemCounts[element.notebookId, default: 0] += 1 }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func rename(_ id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let i = notebooks.firstIndex(where: { $0.id == id }) else { return }
        notebooks[i].name = trimmed
    }

    func delete(_ id: String) {
        notebooks.removeAll { $0.id == id }
    }

    /// Top-right badge text: page count, or item count for a board.
    func sizeLabel(for nb: Notebook) -> String {
        if nb.isBoard {
            let n = itemCounts[nb.id, default: 0]
            return n == 0 ? "Empty" : "\(n) item\(n == 1 ? "" : "s")"
        }
        let n = max(pageCounts[nb.id, default: 0], 1)
        return "\(n) page\(n == 1 ? "" : "s")"
    }
}
