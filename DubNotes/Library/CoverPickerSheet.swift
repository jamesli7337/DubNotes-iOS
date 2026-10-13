import SwiftUI

/// Cover picker: palette colours × built-in patterns, applied as soon as they are tapped (covers.ts).
struct CoverPickerSheet: View {
    let store: LibraryStore
    let notebookId: String

    @Environment(\.dismiss) private var dismiss

    private var cover: Notebook.Cover? { store.notebook(notebookId)?.cover }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    CoverView(cover: cover, isBoard: store.notebook(notebookId)?.isBoard ?? false)
                        .frame(height: 140)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .listRowInsets(EdgeInsets())
                }
                Section("Colour") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 44), spacing: 12)], spacing: 12) {
                        Button { store.setCover(notebookId, nil) } label: {
                            Image(systemName: "slash.circle")
                                .font(.title2)
                                .frame(width: 40, height: 40)
                                .overlay(Circle().strokeBorder(cover == nil ? Color.accentColor : Color(.separator), lineWidth: cover == nil ? 3 : 1))
                        }
                        .accessibilityLabel("No cover")
                        ForEach(CoverOptions.colors, id: \.self) { c in
                            Button {
                                store.setCover(notebookId, CoverOptions.picking(color: c, from: cover))
                            } label: {
                                Circle().fill(Color(hex: c))
                                    .frame(width: 40, height: 40)
                                    .overlay(Circle().strokeBorder(cover?.color == c ? Color.accentColor : Color.clear, lineWidth: 3).padding(-3))
                            }
                            .accessibilityLabel("Cover \(c)")
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 4)
                }
                Section("Pattern") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: 12)], spacing: 12) {
                        patternTile(nil, label: "Plain")
                        ForEach(CoverOptions.patterns, id: \.self) { patternTile($0, label: $0.capitalized) }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle("Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func patternTile(_ pattern: String?, label: String) -> some View {
        let color = cover?.color ?? CoverOptions.colors[0]
        let selected = cover != nil && cover?.pattern == pattern
        return Button {
            store.setCover(notebookId, CoverOptions.picking(pattern: pattern, from: cover))
        } label: {
            ZStack {
                CoverView(cover: Notebook.Cover(color: color, pattern: pattern))
                Text(pattern == nil ? label : "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) pattern")
    }
}
