import SwiftUI
import UIKit

/// A notebook's preview tile: the first page rendered small, with the cover colour and pattern framing it when
/// the notebook has a cover (the web's `.has-cover` thumbnail). An empty notebook shows the page's paper.
struct NotebookThumb: View {
    let store: LibraryStore
    let notebook: Notebook
    var inset: CGFloat = 7
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?

    private var page: Page? { store.firstPage(of: notebook.id) }

    private var key: String {
        "\(notebook.id)-\(page?.id ?? "none")-\(page?.updatedAt ?? 0)-\(store.contentRevision)"
    }

    var body: some View {
        ZStack {
            if let cover = notebook.cover {
                CoverView(cover: cover, isBoard: notebook.isBoard)
            } else {
                Rectangle().fill(Color(.tertiarySystemFill))
            }
            pagePreview
                .padding(notebook.cover == nil ? 0 : inset)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
        .task(id: key) { await load() }
    }

    @ViewBuilder
    private var pagePreview: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: notebook.cover == nil ? 0 : 4, style: .continuous))
                .shadow(color: .black.opacity(notebook.cover == nil ? 0 : 0.25), radius: 3, y: 1)
        } else if notebook.isBoard {
            Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
        } else {
            Color.clear
        }
    }

    private func load() async {
        guard let page, !notebook.isBoard else { return }
        let files = store.files
        let loaded: UIImage = await withCheckedContinuation { cont in
            ThumbnailLoader.shared.load(files: files, page: page, key: key, width: 240) { cont.resume(returning: $0) }
        }
        image = loaded
    }
}
