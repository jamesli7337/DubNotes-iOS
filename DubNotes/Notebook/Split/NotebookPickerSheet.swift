import SwiftUI

/// "Split screen page": choose a notebook to show beside this one. Boards are left out; the pane scrolls a
/// column of pages, which a board doesn't have.
struct NotebookPickerSheet: View {
    let session: NotebookSession
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    private var candidates: [Notebook] {
        session.library.recent.filter { !$0.isBoard && $0.id != session.doc.id }
    }

    var body: some View {
        NavigationStack {
            List {
                if candidates.isEmpty {
                    Text("There are no other notebooks to show.").foregroundStyle(.secondary)
                }
                ForEach(candidates, id: \.id) { nb in
                    Button {
                        onPick(nb.id)
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            NotebookThumb(store: session.library, notebook: nb)
                                .frame(width: 44, height: 58)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(nb.name).font(.headline)
                                Text(session.library.sizeLabel(for: nb)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Choose a notebook to split screen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
