import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
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

    private struct OpenNotebook: Identifiable { let id: String }

    private enum ImportKind { case pdf, backup }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    let store: LibraryStore
    @State private var selection: String? = LibraryView.rootID
    @State private var prefs = LibraryPreferences.load()
    @State private var showingNew = false
    @State private var showingSettings = false
    @State private var moving: MoveRequest?
    @State private var coverFor: MoveRequest?
    @State private var opening: OpenNotebook?
    @State private var deletion: Deletion?
    @State private var prompt: Prompt?
    @State private var promptText = ""
    @State private var importerOpen = false
    @State private var importerKind = ImportKind.pdf
    @State private var exporting = false
    @State private var exportDocument = BackupDocument(data: Data())
    @State private var notice: Notice?

    init(store: LibraryStore) {
        self.store = store
    }

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
                let nb = store.createNotebook(name: name, folderId: currentID, paper: paper, kind: kind)
                opening = OpenNotebook(id: nb.id)
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsSheet() }
        .sheet(item: $moving) { req in
            if let nb = store.notebook(req.id) { MoveToSheet(store: store, notebook: nb) }
        }
        .sheet(item: $coverFor) { req in
            CoverPickerSheet(store: store, notebookId: req.id)
        }
        .fullScreenCover(item: $opening) { open in
            NotebookScreen(store: store, notebookId: open.id) { opening = nil }
        }
        .fileImporter(isPresented: $importerOpen,
                      allowedContentTypes: importerKind == .pdf ? [.pdf] : [.json]) { result in
            handleImport(result, kind: importerKind)
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentType: .json,
                      defaultFilename: backupFileName()) { result in
            if case .failure(let error) = result {
                notice = Notice(title: "Export failed", message: error.localizedDescription)
            }
        }
        .alert(item: $notice) { n in
            Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("OK")))
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
        .onChange(of: prefs) { _, new in new.save() }
        .onChange(of: store.folders) { _, folders in
            prefs.prune(existing: Set(folders.map(\.id)))
        }
    }

    // MARK: Import, export, restore

    private func startImport(_ kind: ImportKind) {
        importerKind = kind
        importerOpen = true
    }

    private func handleImport(_ result: Result<URL, Error>, kind: ImportKind) {
        do {
            let url = try result.get()
            let data = try readPickedFile(url)
            switch kind {
            case .pdf:
                let made = try PDFImport.makeNotebook(name: url.lastPathComponent, data: data)
                let nb = try store.addNotebook(made.doc, assets: [made.asset], folderId: currentID)
                opening = OpenNotebook(id: nb.id)
            case .backup:
                let s = try store.importBackup(data)
                var message = "Added \(s.notebooks) notebook\(s.notebooks == 1 ? "" : "s") as new copies. Nothing already in your library was changed."
                if !s.warnings.isEmpty { message += "\n\n" + s.warnings.prefix(5).joined(separator: "\n") }
                notice = Notice(title: "Backup restored", message: message)
            }
        } catch {
            let title = kind == .pdf ? "Import failed" : "Restore failed"
            notice = Notice(title: title, message: error.localizedDescription)
        }
    }

    private func startExport() {
        do {
            exportDocument = BackupDocument(data: try store.exportBackup())
            exporting = true
        } catch {
            notice = Notice(title: "Export failed", message: error.localizedDescription)
        }
    }

    private func ask(_ title: String, placeholder: String, value: String = "", confirm: String,
                     action: @escaping (String) -> Void) {
        promptText = value
        prompt = Prompt(title: title, placeholder: placeholder, confirm: confirm, action: action)
    }

    // MARK: Sidebar

    private var treeRows: [TreeRow] {
        let expanded = prefs.openFolders.union(store.folderPath(currentID).map(\.id))
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
        let isOpen = f.map { prefs.openFolders.contains($0.id) || store.folderPath(currentID).contains($0) } ?? true
        return HStack(spacing: 2) {
            Button {
                if let f {
                    if prefs.openFolders.contains(f.id) { prefs.openFolders.remove(f.id) } else { prefs.openFolders.insert(f.id) }
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
            if let parent { prefs.openFolders.insert(parent) }
            selection = made.id
        }
    }

    private func deleteFolder(_ f: Folder) {
        let leaving = store.folderPath(currentID).contains(f)
        store.deleteFolder(f.id)
        prefs.openFolders.remove(f.id)
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
        LibraryPreferences.sorted(list, by: prefs.sort)
    }

    /// "Manual order" keeps dividers in place; any other sort re-orders just the notebooks and drops them.
    private var segments: [Segment] {
        let items = store.folderItems(currentID)
        if prefs.sort != .manual && notebooksHere.count > 1 { return [Segment(divider: nil, notebooks: sorted(notebooksHere))] }
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
                if currentID == nil, let recent = store.recent.first { continueWork(recent) }
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
                            if prefs.layout == .grid {
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { startImport(.pdf) } label: { Label("Import", systemImage: "square.and.arrow.down") }.labelStyle(.titleAndIcon)
                Button { startExport() } label: { Label("Export", systemImage: "arrow.up.right.square") }.labelStyle(.titleAndIcon)
                Button { startImport(.backup) } label: { Label("Restore", systemImage: "tray.and.arrow.down") }.labelStyle(.titleAndIcon)
                Button { showingSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                    .labelStyle(.iconOnly)
            }
        }
        .safeAreaInset(edge: .bottom) { newDock }
    }

    // MARK: Continue work

    /// The most recently edited notebook, anywhere, as a wide card above the list (root only).
    private func continueWork(_ nb: Notebook) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                Text("CONTINUE WORK")
                    .font(.caption.weight(.bold))
                    .tracking(0.9)
                    .foregroundStyle(.secondary)
            }
            Button { open(nb) } label: {
                HStack(spacing: 16) {
                    NotebookThumb(store: store, notebook: nb)
                        .frame(width: 84, height: 108)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(store.sizeLabel(for: nb)).font(.footnote).foregroundStyle(.secondary)
                        Text(nb.name).font(.title3.bold()).lineLimit(2)
                        Text("Edited \(Self.dateLabel(nb.updatedAt))").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(18)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Continue \(nb.name)")
        }
    }

    private func open(_ nb: Notebook) {
        opening = OpenNotebook(id: nb.id)
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
                Picker("Layout", selection: $prefs.layout) {
                    ForEach(LibraryPreferences.Layout.allCases, id: \.self) { Image(systemName: $0.symbol).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if notebooksHere.count > 1 {
                Menu {
                    Picker("Sort", selection: $prefs.sort) {
                        ForEach(LibraryPreferences.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(prefs.sort.rawValue)
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
            NotebookThumb(store: store, notebook: nb, inset: 10, cornerRadius: 0)
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
        .onTapGesture { open(nb) }
        .contextMenu { actions(nb) }
    }

    private func row(_ nb: Notebook) -> some View {
        let type = nb.isBoard ? "board" : "notebook"
        return HStack(spacing: 16) {
            NotebookThumb(store: store, notebook: nb)
                .frame(width: 72, height: 96)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.sizeLabel(for: nb)).font(.footnote).foregroundStyle(.secondary)
                Text(nb.name).font(.headline).lineLimit(1)
                Text(Self.dateLabel(nb.updatedAt)).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                Button {
                    ask("Rename \(type)", placeholder: "Name", value: nb.name, confirm: "Rename") { store.rename(nb.id, to: $0) }
                } label: { Image(systemName: "pencil").frame(width: 36, height: 36) }
                    .accessibilityLabel("Rename \(type)")
                Button { deletion = .notebook(nb) } label: { Image(systemName: "trash").frame(width: 36, height: 36) }
                    .accessibilityLabel("Delete \(type)")
                Menu { actions(nb) } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                    .accessibilityLabel("\(type.capitalized) actions")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
        .onTapGesture { open(nb) }
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
        Button { coverFor = MoveRequest(id: nb.id) } label: { Label("Cover…", systemImage: "paintpalette") }
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

    /// "today, 2:35 PM", "yesterday, 9:10 AM" or "Oct 10", like the web library's relative dates.
    private static func dateLabel(_ ms: Double) -> String {
        let date = Date(timeIntervalSince1970: ms / 1000)
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "today, \(time)" }
        if cal.isDateInYesterday(date) { return "yesterday, \(time)" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
