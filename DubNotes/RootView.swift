import SwiftUI

struct RootView: View {
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system
    @Environment(\.scenePhase) private var scenePhase
    @State private var store = LibraryStore()

    var body: some View {
        LibraryView(store: store)
            .preferredColorScheme(appearance.colorScheme)
            .onChange(of: scenePhase) { _, phase in
                // autosave runs on a short timer; leaving the app must not wait for it
                if phase != .active { store.flushNow() }
            }
    }
}
