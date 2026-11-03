import Foundation

/// Chooses the library the app starts with. A normal launch uses the real one. In DEBUG builds only, the launch
/// argument `-ui-tour` swaps in a separate, freshly emptied storage folder filled by restoring a backup, so the
/// CI screenshot tour always sees the same data. Release builds do not contain this code path.
enum AppLaunch {
    static func makeStore() -> LibraryStore {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-tour") { return tourStore() }
        #endif
        return LibraryStore()
    }

    #if DEBUG
    /// The backup comes from the UI test: base64 in `UI_TOUR_BACKUP_BASE64`, or a file path in `UI_TOUR_BACKUP_PATH`.
    private static func tourBackup() -> Data? {
        let env = ProcessInfo.processInfo.environment
        if let b64 = env["UI_TOUR_BACKUP_BASE64"], let data = Data(base64Encoded: b64) { return data }
        if let path = env["UI_TOUR_BACKUP_PATH"] { return try? Data(contentsOf: URL(fileURLWithPath: path)) }
        return nil
    }

    /// `@State` may evaluate its initial value more than once; the tour folder must only be wiped and filled once.
    private static var cachedTour: LibraryStore?

    private static func tourStore() -> LibraryStore {
        if let cachedTour { return cachedTour }
        // the same preferences and tool settings every time
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("UITour", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        let store = LibraryStore(files: FileStore(root: root))
        if let data = tourBackup() { _ = try? store.importBackup(data) }
        // a second paged notebook, so "Split screen page" has something to offer; made to look older than the
        // restored one so the Continue work card still shows the restored notebook
        let extra = store.createNotebook(name: "Chemistry", folderId: nil,
                                         paper: Paper(template: .grid, spacing: .medium, color: .white), kind: .pages)
        if let i = store.notebooks.firstIndex(where: { $0.id == extra.id }) { store.notebooks[i].updatedAt = 4500 }
        cachedTour = store
        return store
    }
    #endif
}
