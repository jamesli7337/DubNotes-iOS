import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Opens a notebook full screen. A board's canvas isn't built (its data is kept), so it shows a notice.
struct NotebookScreen: View {
    let store: LibraryStore
    let notebookId: String
    let onClose: () -> Void

    @State private var session: NotebookSession?
    @State private var failed = false

    var body: some View {
        Group {
            if let session {
                if session.doc.notebook.isBoard {
                    BoardPlaceholder(name: session.title) { close(session) }
                } else {
                    NotebookContent(session: session) { close(session) }
                }
            } else if failed {
                ContentUnavailableView("Can’t open this notebook", systemImage: "exclamationmark.triangle",
                                       description: Text("Its files could not be read."))
                    .overlay(alignment: .topLeading) { Button("Back", action: onClose).padding() }
            } else {
                Color(.systemBackground)
            }
        }
        .onAppear {
            guard session == nil else { return }
            if let s = NotebookSession(library: store, notebookId: notebookId) { session = s } else { failed = true }
        }
    }

    private func close(_ s: NotebookSession) {
        s.close()
        onClose()
    }
}

private struct BoardPlaceholder: View {
    let name: String
    let onBack: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(name, systemImage: "square.grid.2x2")
        } description: {
            Text("Boards can’t be opened in this version. Everything on this board is kept and will appear when board support arrives.")
        } actions: {
            Button("Back to library", action: onBack).buttonStyle(.borderedProminent)
        }
    }
}

/// The notebook editor: top bar, dock, the page column, and the split pane.
struct NotebookContent: View {
    private enum Sheet: Identifiable {
        case paper(Page)
        case pages
        case notebookPicker
        case share(URL)

        var id: String {
            switch self {
            case .paper(let p): return "paper-\(p.id)"
            case .pages: return "pages"
            case .notebookPicker: return "picker"
            case .share(let u): return "share-\(u.path)"
            }
        }
    }

    private enum ImporterPurpose { case pdfPages, splitPDF }
    private enum PhotoPurpose { case insert, splitImage }

    private struct Notice: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    let session: NotebookSession
    let onBack: () -> Void

    @State private var sheet: Sheet?
    @State private var optionsOpen = false
    @State private var eraserMenu = false
    @State private var renaming = false
    @State private var renameText = ""
    @State private var importerOpen = false
    @State private var importerPurpose = ImporterPurpose.pdfPages
    @State private var photosOpen = false
    @State private var photoPurpose = PhotoPurpose.insert
    @State private var photoItem: PhotosPickerItem?
    @State private var busy: String?
    @State private var notice: Notice?
    @State private var split: SplitState?
    @State private var topChromeHeight: CGFloat = 0
    @State private var bottomChromeHeight: CGFloat = 0

    private var settings: ToolSettings { session.settings }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(.systemGroupedBackground).ignoresSafeArea()
                HStack(spacing: 0) {
                    PageColumnRepresentable(session: session, settings: session.settings, guideKind: session.guideKind,
                                            guidePageId: session.guidePageId, paperRevision: session.structureRevision,
                                            topInset: topChromeHeight, bottomInset: bottomChromeHeight)
                        .ignoresSafeArea(edges: [.top, .bottom])
                    if let s = split, !s.floating, s.kind != .image { dockedPane(s, width: geo.size.width) }
                }
                chrome(width: geo.size.width)
                if let s = split, s.floating || s.kind == .image { floatingPane(s, container: geo.size) }
                if let busy {
                    ZStack {
                        Color.black.opacity(0.25).ignoresSafeArea()
                        VStack(spacing: 10) {
                            ProgressView()
                            Text(busy).font(.subheadline)
                        }
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .paper(let page): PaperSheet(session: session, page: page)
            case .pages: PageManagerSheet(session: session).presentationDetents([.large])
            case .notebookPicker: NotebookPickerSheet(session: session) { id in startPageSplit(id) }
            case .share(let url): ShareSheet(url: url)
            }
        }
        .fileImporter(isPresented: $importerOpen, allowedContentTypes: [.pdf]) { result in handleImport(result) }
        .photosPicker(isPresented: $photosOpen, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            handlePhoto(item)
        }
        .alert("Rename notebook", isPresented: $renaming) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { session.rename(renameText) }
        }
        .alert(item: $notice) { n in Alert(title: Text(n.title), message: Text(n.message), dismissButton: .default(Text("OK"))) }
        .confirmationDialog("Eraser", isPresented: $eraserMenu, titleVisibility: .hidden) {
            ForEach(EraserMode.allCases, id: \.self) { mode in
                Button("\(mode.label) — \(mode.sub)") {
                    var s = session.settings
                    s.eraserMode = mode
                    session.settings = s
                }
            }
        }
        .onAppear { split = SplitStore.load(hostId: session.doc.id) }
        .onChange(of: split) { _, new in SplitStore.save(new, hostId: session.doc.id) }
    }

    // MARK: Chrome

    /// The two islands (back + title, actions) and the dock, which sits inline between them when there is room,
    /// under them otherwise, or along the bottom edge when docked there.
    @ViewBuilder
    private func chrome(width: CGFloat) -> some View {
        VStack(spacing: 8) {
            Group {
                if settings.dockPosition == .top {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) {
                            leftIsland
                            Spacer(minLength: 0)
                            dock
                            Spacer(minLength: 0)
                            rightIsland
                        }
                        VStack(spacing: 8) {
                            HStack(alignment: .top) {
                                leftIsland
                                Spacer(minLength: 0)
                                rightIsland
                            }
                            dock
                        }
                    }
                } else {
                    HStack(alignment: .top) {
                        leftIsland
                        Spacer(minLength: 0)
                        rightIsland
                    }
                }
            }
            .background(HeightReader { topChromeHeight = $0 + 8 + 14 })
            Spacer(minLength: 0)
            if settings.dockPosition == .bottom {
                dock.background(HeightReader { bottomChromeHeight = $0 + 10 + 14 })
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .onChange(of: settings.dockPosition) { _, pos in
            if pos == .top { bottomChromeHeight = 0 }
        }
    }

    private var dock: some View {
        DockView(session: session, optionsOpen: $optionsOpen) { eraserMenu = true }
            .gesture(
                LongPressGesture(minimumDuration: 0.35)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onEnded { value in
                        // hold the dock still, then drag it to the other edge
                        if case .second(true, let drag?) = value {
                            var s = session.settings
                            s.dockPosition = drag.translation.height > 60 ? .bottom : (drag.translation.height < -60 ? .top : s.dockPosition)
                            session.settings = s
                        }
                    }
            )
    }

    private var leftIsland: some View {
        HStack(spacing: 4) {
            Button(action: onBack) { Image(systemName: "arrow.left").frame(width: 40, height: 40) }
                .accessibilityLabel("Back to library")
            Button {
                renameText = session.title
                renaming = true
            } label: {
                Text(session.title).font(.headline).lineLimit(1).padding(.trailing, 12)
            }
            .accessibilityLabel("Rename notebook")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .frame(height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
    }

    private var rightIsland: some View {
        HStack(spacing: 0) {
            Menu {
                Button { sheet = .notebookPicker } label: { Label("Split screen page", systemImage: "book") }
                Button { photoPurpose = .splitImage; photosOpen = true } label: { Label("Split screen image", systemImage: "photo") }
                Button { importerPurpose = .splitPDF; importerOpen = true } label: { Label("Split screen PDF", systemImage: "doc.richtext") }
            } label: { islandIcon("rectangle.split.2x1") }
                .accessibilityLabel("Split screen")
            Menu {
                Button { importerPurpose = .pdfPages; importerOpen = true } label: { Label("Import PDF pages", systemImage: "square.and.arrow.down") }
                Button { photoPurpose = .insert; photosOpen = true } label: { Label("Insert image", systemImage: "photo") }
            } label: { islandIcon("square.and.arrow.down") }
                .accessibilityLabel("Import")
            Menu { exportMenu } label: { islandIcon("square.and.arrow.up") }
                .accessibilityLabel("Export")
            Button { sheet = .pages } label: { islandIcon("square.grid.2x2") }
                .accessibilityLabel("Manage pages")
            Button {
                if let page = session.currentPage { sheet = .paper(page) }
            } label: { islandIcon("list.clipboard") }
                .accessibilityLabel("Customize paper")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .frame(height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(.separator), lineWidth: 0.5))
    }

    private func islandIcon(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 18)).frame(width: 44, height: 40).contentShape(Rectangle())
    }

    // MARK: Export

    @ViewBuilder
    private var exportMenu: some View {
        if let page = session.currentPage {
            let n = page.index + 1
            Button { export(.pdf, pages: [page], name: "\(session.title) - page \(n)") } label: { Label("Page \(n) as PDF", systemImage: "square.and.arrow.up") }
            Button { export(.pdf, pages: session.doc.contentPages, name: session.title) } label: { Label("Whole notebook as PDF", systemImage: "square.and.arrow.up") }
            Button { export(.png, pages: [page], name: "\(session.title) - page \(n)") } label: { Label("Page \(n) as PNG", systemImage: "square.and.arrow.up") }
            Button { export(.jpeg, pages: [page], name: "\(session.title) - page \(n)") } label: { Label("Page \(n) as JPEG", systemImage: "square.and.arrow.up") }
        }
    }

    private func export(_ format: Exporter.Format, pages: [Page], name: String) {
        session.column?.deactivateAll() // commit any open text edit first so it is included
        busy = "Exporting…"
        let sources = pages.map { Exporter.source($0, in: session.doc) }
        let title = session.title
        Task {
            do {
                let url = try await Task.detached(priority: .userInitiated) {
                    try Exporter.export(sources: sources, title: title, format: format, fileName: name)
                }.value
                busy = nil
                sheet = .share(url)
            } catch {
                busy = nil
                notice = Notice(title: "Export failed", message: error.localizedDescription)
            }
        }
    }

    // MARK: Import

    private func handleImport(_ result: Result<URL, Error>) {
        switch importerPurpose {
        case .pdfPages:
            importPDFPages(result)
        case .splitPDF:
            do {
                let url = try result.get()
                let data = try readPickedFile(url)
                guard PDFAssets.pageSizes(of: data) != nil else { throw PDFImportError.unreadable }
                _ = try SplitStore.writePayload(data, hostId: session.doc.id, ext: "pdf")
                split = SplitState(kind: .pdf, fileName: url.lastPathComponent, payloadExtension: "pdf")
            } catch {
                notice = Notice(title: "Can’t open that PDF", message: error.localizedDescription)
            }
        }
    }

    private func importPDFPages(_ result: Result<URL, Error>) {
        busy = "Importing PDF…"
        do {
            let url = try result.get()
            let data = try readPickedFile(url)
            let after = session.currentPage?.index ?? (session.doc.pages.count - 1)
            try PDFImport.appendPages(to: session.doc, data: data, name: url.lastPathComponent, afterIndex: after, files: session.library.files)
            busy = nil
            session.pagesAdded()
        } catch {
            busy = nil
            notice = Notice(title: "Import failed", message: error.localizedDescription)
        }
    }

    private func handlePhoto(_ item: PhotosPickerItem) {
        let purpose = photoPurpose
        busy = purpose == .insert ? "Adding image…" : "Opening image…"
        Task {
            defer { busy = nil }
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                notice = Notice(title: "Could not insert image", message: "That file could not be read.")
                return
            }
            switch purpose {
            case .insert:
                let loaded = await Task.detached { ImageImport.load(data) }.value
                guard let loaded else {
                    notice = Notice(title: "Could not insert image", message: "That file could not be read as an image.")
                    return
                }
                session.column?.insertImage(src: loaded.src, width: loaded.width, height: loaded.height)
            case .splitImage:
                guard UIImage(data: data) != nil else {
                    notice = Notice(title: "Could not open image", message: "That file could not be read as an image.")
                    return
                }
                let ext = ImageImport.sniff(data) == .jpeg ? "jpg" : "png"
                let payload = ext == "png" && ImageImport.sniff(data) != .png ? (UIImage(data: data)?.pngData() ?? data) : data
                do {
                    _ = try SplitStore.writePayload(payload, hostId: session.doc.id, ext: ext)
                    split = SplitState(kind: .image, fileName: "Image", payloadExtension: ext, floating: true)
                } catch {
                    notice = Notice(title: "Could not open image", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: Split screen

    private func startPageSplit(_ notebookId: String) {
        SplitStore.removePayload(hostId: session.doc.id)
        split = SplitState(kind: .page, notebookId: notebookId)
    }

    private func closeSplit() {
        SplitStore.removePayload(hostId: session.doc.id)
        split = nil
    }

    private func splitBinding() -> Binding<SplitState>? {
        guard split != nil else { return nil }
        return Binding(get: { split ?? SplitState(kind: .page) }, set: { split = $0 })
    }

    @ViewBuilder
    private func dockedPane(_ s: SplitState, width: CGFloat) -> some View {
        if let binding = splitBinding() {
            let w = width * CGFloat(min(max(s.fraction, SplitState.fractionRange.lowerBound), SplitState.fractionRange.upperBound))
            HStack(spacing: 0) {
                Rectangle().fill(Color(.separator)).frame(width: 1)
                    .overlay {
                        // a wider invisible strip to grab
                        Color.clear.frame(width: 24).contentShape(Rectangle())
                            .gesture(DragGesture(coordinateSpace: .global).onChanged { g in
                                let f = 1 - Double(g.location.x / max(width, 1))
                                var next = binding.wrappedValue
                                next.fraction = min(max(f, SplitState.fractionRange.lowerBound), SplitState.fractionRange.upperBound)
                                binding.wrappedValue = next
                            })
                    }
                SplitPaneView(session: session, state: binding, onClose: closeSplit)
                    .frame(width: w)
            }
            .ignoresSafeArea(edges: [.top, .bottom])
        }
    }

    @ViewBuilder
    private func floatingPane(_ s: SplitState, container: CGSize) -> some View {
        if let binding = splitBinding() {
            FloatingBox(rect: Binding(get: { binding.wrappedValue.float }, set: { v in
                var next = binding.wrappedValue
                next.float = v
                binding.wrappedValue = next
            }), container: container) {
                SplitPaneView(session: session, state: binding, onClose: closeSplit)
            }
        }
    }
}

/// Reports the height of whatever it is the background of.
struct HeightReader: View {
    let onChange: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { onChange(geo.size.height) }
                .onChange(of: geo.size.height) { _, h in onChange(h) }
        }
    }
}

