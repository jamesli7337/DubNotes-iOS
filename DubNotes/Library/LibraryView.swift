import SwiftUI

struct LibraryView: View {
    enum Layout: String, CaseIterable {
        case grid, list
        var symbol: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    }

    enum Sort: String, CaseIterable {
        case manual = "Manual order"
        case updated = "Date modified"
        case created = "Date created"
        case name = "Name (A–Z)"
    }

    @State private var store = LibraryStore()
    @State private var layout = Layout.grid
    @State private var sort = Sort.manual
    @State private var showingNew = false
    @State private var renaming: Notebook?
    @State private var renameText = ""
    @State private var deleting: Notebook?

    private var sorted: [Notebook] {
        switch sort {
        case .manual: return store.notebooks.sorted { $0.order < $1.order }
        case .updated: return store.notebooks.sorted { $0.updatedAt > $1.updatedAt }
        case .created: return store.notebooks.sorted { $0.createdAt > $1.createdAt }
        case .name: return store.notebooks.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    if let error = store.loadError {
                        Text(error).foregroundStyle(.red)
                    } else if store.notebooks.isEmpty {
                        ContentUnavailableView("Nothing here yet", systemImage: "book.closed",
                                               description: Text("Tap New to start."))
                    } else if layout == .grid {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 216), spacing: 18)], spacing: 18) {
                            ForEach(sorted, id: \.id) { nb in card(nb) }
                        }
                    } else {
                        LazyVStack(spacing: 10) {
                            ForEach(sorted, id: \.id) { nb in row(nb) }
                        }
                    }
                }
                .padding(24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("DubNotes")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingNew = true } label: { Label("New", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                }
            }
            .sheet(isPresented: $showingNew) { NewNotebookPlaceholder() }
            .alert("Rename notebook", isPresented: Binding(get: { renaming != nil },
                                                           set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Cancel", role: .cancel) {}
                Button("Rename") {
                    if let nb = renaming { store.rename(nb.id, to: renameText) }
                }
            }
            .confirmationDialog(deleting.map { "Delete “\($0.name)”?" } ?? "",
                                isPresented: Binding(get: { deleting != nil },
                                                     set: { if !$0 { deleting = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let nb = deleting { store.delete(nb.id) }
                }
            } message: {
                Text("All of its pages and drawings will be removed.")
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("All items").font(.title2.bold())
            Text("\(store.notebooks.count)")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Spacer()
            Picker("Layout", selection: $layout) {
                ForEach(Layout.allCases, id: \.self) { Image(systemName: $0.symbol).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(sort.rawValue)
                    Image(systemName: "chevron.down").font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .tint(.primary)
        }
    }

    // MARK: Cards

    private func card(_ nb: Notebook) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CoverView(cover: nb.cover, isBoard: nb.isBoard)
                .frame(height: 168)
                .overlay(alignment: .topTrailing) { badge(nb).padding(9) }
            VStack(alignment: .leading, spacing: 4) {
                Text(nb.name).font(.headline).lineLimit(1)
                Text(Self.dateLabel(nb.updatedAt)).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu { actions(nb) }
    }

    private func row(_ nb: Notebook) -> some View {
        HStack(spacing: 16) {
            CoverView(cover: nb.cover, isBoard: nb.isBoard)
                .frame(width: 72, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(store.sizeLabel(for: nb)).font(.footnote).foregroundStyle(.secondary)
                Text(nb.name).font(.headline).lineLimit(1)
                Text(Self.dateLabel(nb.updatedAt)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contextMenu { actions(nb) }
    }

    private func badge(_ nb: Notebook) -> some View {
        Text(store.sizeLabel(for: nb))
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background(.regularMaterial, in: Capsule())
    }

    @ViewBuilder
    private func actions(_ nb: Notebook) -> some View {
        Button { renameText = nb.name; renaming = nb } label: { Label("Rename", systemImage: "pencil") }
        Button(role: .destructive) { deleting = nb } label: { Label("Delete", systemImage: "trash") }
    }

    /// "Today", "Yesterday" or "Oct 10", like the web library's relative dates.
    private static func dateLabel(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

private struct NewNotebookPlaceholder: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView("New notebook", systemImage: "book.closed",
                                   description: Text("Coming soon."))
                .navigationTitle("New")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}
