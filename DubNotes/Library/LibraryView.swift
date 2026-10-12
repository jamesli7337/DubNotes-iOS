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

    private enum Deletion {
        case notebook(Notebook)
        case folder(Folder)
    }

    private struct Prompt {
        let title: String
        let placeholder: String
        let confirm: String
        let action: (String) -> Void
    }

    /// Notebooks following a divider (or the leading ones, with no divider) — the grid spans a divider's full row.
    private struct Segment: Identifiable {
        let divider: Divider?
        var notebooks: [Notebook]
        var id: String { divider?.id ?? "head" }
    }

    private struct TreeRow: Identifiable {
        let folder: Folder?
        let depth: Int
        var id: String { folder?.id ?? LibraryView.rootID }
    }

    private struct MoveRequest: Identifiable { let id: String }

    private static let rootID = "root"

    @State private var store = LibraryStore()
    @State private var layout = Layout.grid
    @State private var sort = Sort.manual
    @State private var selection: String? = LibraryView.rootID
    @State private var openFolders: Set<String> = []
    @State private var showingNew = false
    @State private var showingSettings = false
    @State private var moving: MoveRequest?
    @State private var deletion: Deletion?
    @State private var prompt: Prompt?
    @State private var promptText = ""

    private var currentID: String? {
        guard let selection, selection != Self.rootID, store.folder(selection) != nil else { return nil }
        return selection
    }

    // MARK: Body

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack { content }
        }
        .sheet(isPresented: $showingNew) {
            NewNotebookSheet { name, paper, kind in
                store.createNotebook(name: name, folderId: currentID, paper: paper, kind: kind)
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsSheet() }
        .sheet(item: $moving) { req in
            if let nb = store.notebook(req.id) { MoveToSheet(store: store, notebook: nb) }
        }
        .alert(prompt?.title ?? "", isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
               presenting: prompt) { p in
            TextField(p.placeholder, text: $promptText)
            Button("Cancel", role: .cancel) {}
            Button(p.confirm) { p.action(promptText) }
        }
        .confirmationDialog(deletionTitle, isPresented: Binding(get: { deletion != nil },
                                                                set: { if !$0 { deletion = nil } }),
                            titleVisibility: .visible, presenting: deletion) { d in
            switch d {
            case .notebook(let nb):
                Button("Delete", role: .destructive) { store.delete(nb.id) }
            case .folder(let f):
                Button("Delete folder", role: .destructive) { deleteFolder(f) }
            }
        } message: { d in
            Text(deletionMessage(d))
        }
    }

    private func ask(_ title: String, placeholder: String, value: String = "", confirm: String,
                     action: @escaping (String) -> Void) {
        promptText = value
        prompt = Prompt(title: title, placeholder: placeholder, confirm: confirm, action: action)
    }

    // MARK: Sidebar

    private var treeRows: [TreeRow] {
        let expanded = openFolders.union(store.folderPath(currentID).map(\.id))
        var rows = [TreeRow(folder: nil, depth: 0)]
        func walk(_ parent: String?, _ depth: Int) {
            for f in store.folderList(parent) {
                rows.append(TreeRow(folder: f, depth: depth))
                if expanded.contains(f.id) { walk(f.id, depth + 1) }
            }
        }
        walk(nil, 1)
        return rows
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("Library") {
                ForEach(treeRows) { row in treeRow(row).tag(row.id) }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Library")
    }

    private func treeRow(_ row: TreeRow) -> some View {
        let f = row.folder
        let hasChildren = f.map { !store.folderList($0.id).isEmpty } ?? false
        let isOpen = f.map { openFolders.contains($0.id) || store.folderPath(currentID).contains($0) } ?? true
        return HStack(spacing: 2) {
            Button {
                if let f {
                    if openFolders.contains(f.id) { openFolders.remove(f.id) } else { openFolders.insert(f.id) }
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 26, height: 32)
            }
            .buttonStyle(.borderless)
            .opacity(hasChildren ? 1 : 0)
            .disabled(!hasChildren)

            Label(f?.name ?? "All items", systemImage: isOpen && hasChildren ? "folder.fill" : "folder")
                .lineLimit(1)
            Spacer(minLength: 4)
            Text("\(store.notebookCount(f?.id))")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 1)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Menu { folderMenu(f) } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 30)
            }
            .buttonStyle(.borderless)
        }
        .padding(.leading, CGFloat(row.depth) * 16)
        .contextMenu { folderMenu(f) }
    }

    @ViewBuilder
    private func folderMenu(_ f: Folder?) -> some View {
        Button { newFolder(in: f?.id) } label: {
            Label(f == nil ? "New folder" : "New subfolder", systemImage: "folder.badge.plus")
        }
        if let f {
            Button {
                ask("Rename folder", placeholder: "Folder name", value: f.name, confirm: "Rename") {
                    store.renameFolder(f.id, to: $0)
                }
            } label: { Label("Rename", systemImage: "pencil") }
            Button(role: .destructive) { deletion = .folder(f) } label: {
                Label("Delete folder", systemImage: "trash")
            }
        }
    }

    private func newFolder(in parent: String?) {
        ask("New folder", placeholder: "Folder name", confirm: "Create") { name in
            let made = store.createFolder(name: name, parentId: parent)
            if let parent { openFolders.insert(parent) }
            selection = made.id
        }
    }

    private func deleteFolder(_ f: Folder) {
        let leaving = store.folderPath(currentID).contains(f)
        store.deleteFolder(f.id)
        openFolders.remove(f.id)
        if leaving { selection = f.parentId ?? Self.rootID }
    }

    // MARK: Delete confirmation text

    private var deletionTitle: String {
        switch deletion {
        case .notebook(let nb): return "Delete “\(nb.name)”?"
        case .folder(let f): return "Delete folder “\(f.name)”?"
        case nil: return ""
        }
    }

    private func deletionMessage(_ d: Deletion) -> String {
        switch d {
        case .notebook(let nb):
            return nb.isBoard ? "Everything on it will be removed." : "All of its pages and drawings will be removed."
        case .folder(let f):
            let direct = store.notebooks.filter { $0.folderId == f.id }.count
            let subs = store.folderList(f.id).count
            let total = store.notebookCount(f.id)
            if direct == 0 && subs == 0 { return "It is empty." }
            let parentName = f.parentId.flatMap { store.folder($0)?.name } ?? (f.parentId == nil ? "All items" : "its parent")
            func n(_ k: Int, _ one: String) -> String { "\(k) \(one)\(k == 1 ? "" : "s")" }
            var text = "It holds \(n(direct, "item")) and \(n(subs, "subfolder"))"
            if total > direct { text += " (\(n(total - direct, "more item")) inside them)" }
            return text + ". Nothing will be deleted with it — everything moves up to “\(parentName)”."
        }
    }

    // MARK: Content

    private var notebooksHere: [Notebook] {
        store.folderItems(currentID).compactMap {
            if case .notebook(let nb) = $0 { return nb } else { return nil }
        }
    }

    private func sorted(_ list: [Notebook]) -> [Notebook] {
        switch sort {
        case .manual: return list
        case .updated: return list.sorted { $0.updatedAt > $1.updatedAt }
        case .created: return list.sorted { $0.createdAt > $1.createdAt }
        case .name: return list.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    /// "Manual order" keeps dividers in place; any other sort re-orders just the notebooks and drops them.
    private var segments: [Segment] {
        let items = store.folderItems(currentID)
        if sort != .manual && notebooksHere.count > 1 { return [Segment(divider: nil, notebooks: sorted(notebooksHere))] }
        var out = [Segment(divider: nil, notebooks: [])]
        for item in items {
            switch item {
            case .notebook(let nb): out[out.count - 1].notebooks.append(nb)
            case .divider(let d): out.append(Segment(divider: d, notebooks: []))
            }
        }
        return out
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let error = store.loadError {
                    Text(error).foregroundStyle(.red)
                } else if store.folderItems(currentID).isEmpty {
                    Text(currentID == nil ? "Nothing here yet. Tap “New” to start." : "Nothing in this folder yet.")
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                } else {
                    ForEach(segments) { seg in
                        if let d = seg.divider { dividerRow(d) }
                        if !seg.notebooks.isEmpty {
                            if layout == .grid {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 216), spacing: 18)], spacing: 18) {
                                    ForEach(seg.notebooks, id: \.id) { card($0) }
                                }
                            } else {
                                LazyVStack(spacing: 10) {
                                    ForEach(seg.notebooks, id: \.id) { row($0) }
                                }
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(currentID.flatMap { store.folder($0)?.name } ?? "DubNotes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
            }
        }
        .safeAreaInset(edge: .bottom) { newDock }
    }

    // MARK: New button

    /// The web's floating dock: a frosted capsule centred at the bottom holding "+ New" and "New folder".
    private var newDock: some View {
        HStack(spacing: 10) {
            Button { showingNew = true } label: {
                Label("New", systemImage: "plus").padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            Button { newFolder(in: currentID) } label: {
                Label("New folder", systemImage: "folder.badge.plus").padding(.horizontal, 8)
            }
            .buttonStyle(.bordered)
            .tint(.primary)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator)))
        .padding(.bottom, 10)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Text(currentID == nil ? "All items" : "Items").font(.title2.bold())
            Text("\(notebooksHere.count)")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
            Spacer()
            if !notebooksHere.isEmpty {
                Picker("Layout", selection: $layout) {
                    ForEach(Layout.allCases, id: \.self) { Image(systemName: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if notebooksHere.count > 1 {
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
    }

    // MARK: Dividers

    private func dividerRow(_ d: Divider) -> some View {
        HStack(spacing: 10) {
            Text(d.label.uppercased())
                .font(.caption.weight(.bold))
                .tracking(0.9)
                .foregroundStyle(.secondary)
            Rectangle().fill(Color(.separator)).frame(height: 1)
            Menu {
                Button {
                    ask("Rename divider", placeholder: "Label", value: d.label, confirm: "Rename") {
                        store.renameDivider(d.id, to: $0)
                    }
                } label: { Label("Rename", systemImage: "pencil") }
                Button { store.moveItem(d.id, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
                Button { store.moveItem(d.id, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
                Button(role: .destructive) { store.deleteDivider(d.id) } label: {
                    Label("Delete divider", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis").frame(width: 30, height: 30)
            }
        }
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
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
        let type = nb.isBoard ? "board" : "notebook"
        Button {
            ask("Rename \(type)", placeholder: "Name", value: nb.name, confirm: "Rename") { store.rename(nb.id, to: $0) }
        } label: { Label("Rename", systemImage: "pencil") }
        Button { moving = MoveRequest(id: nb.id) } label: { Label("Move to folder…", systemImage: "folder") }
        Button {
            ask("New divider", placeholder: "Label", confirm: "Add") {
                store.createDivider(folderId: nb.folderId, label: $0, aboveNotebookId: nb.id)
            }
        } label: { Label("Add divider above", systemImage: "rectangle.split.1x2") }
        Button { store.moveItem(nb.id, by: -1) } label: { Label("Move up", systemImage: "arrow.up") }
        Button { store.moveItem(nb.id, by: 1) } label: { Label("Move down", systemImage: "arrow.down") }
        Button(role: .destructive) { deletion = .notebook(nb) } label: { Label("Delete", systemImage: "trash") }
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
