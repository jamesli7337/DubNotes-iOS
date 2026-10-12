import SwiftUI

/// Lists every folder as an indented tree (root first, as "All items"); picking one moves the notebook there.
struct MoveToSheet: View {
    let store: LibraryStore
    let notebook: Notebook

    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let folder: Folder?
        let depth: Int
        var id: String { folder?.id ?? "root" }
    }

    private var rows: [Row] {
        var out = [Row(folder: nil, depth: 0)]
        func walk(_ parent: String?, _ depth: Int) {
            for f in store.folderList(parent) {
                out.append(Row(folder: f, depth: depth))
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 1)
        return out
    }

    var body: some View {
        NavigationStack {
            List(rows) { row in
                Button {
                    store.moveNotebook(notebook.id, to: row.folder?.id)
                    dismiss()
                } label: {
                    HStack {
                        Label(row.folder?.name ?? "All items", systemImage: "folder")
                        Spacer()
                        if notebook.folderId == row.folder?.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                    .padding(.leading, CGFloat(row.depth) * 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Move “\(notebook.name)” to")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
