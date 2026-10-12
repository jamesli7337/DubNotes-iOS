import SwiftUI

struct RootView: View {
    @AppStorage(Appearance.storageKey) private var appearance = Appearance.system

    var body: some View {
        LibraryView()
            .preferredColorScheme(appearance.colorScheme)
    }
}
