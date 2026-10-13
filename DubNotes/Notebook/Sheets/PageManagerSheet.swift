import SwiftUI

/// Every page as a thumbnail: tap to jump, drag to reorder, duplicate, delete, or Select several to move or
/// delete them together. Thumbnails render once per open and are kept for the rest of the session.
struct PageManagerSheet: View {
    let session: NotebookSession
    @Environment(\.dismiss) private var dismiss

    @State private var thumbs: [String: UIImage] = [:]
    @State private var selecting = false
    @State private var selected = Set<String>()
    @State private var deleting: DeleteRequest?
    @State private var moving = false

    private struct DeleteRequest: Identifiable {
        let ids: [String]
        var id: String { ids.joined(separator: ",") }
    }

    private var pages: [Page] { session.doc.pages }

    /// Pages that can be selected: every page but the trailing blank the notebook keeps for itself.
    private var selectableIds: [String] {
        var ids = pages.map(\.id)
        if let last = ids.last, session.doc.isBlank(last) { ids.removeLast() }
        return ids
    }

    var body: some View {
        let _ = session.structureRevision // pages come from a plain object; this makes the grid follow reorders and deletes
        VStack(spacing: 0) {
            header
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 18, alignment: .top)], spacing: 22) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { i, page in card(page, number: i + 1) }
                }
                .padding(20)
            }
            if selecting { selectionBar }
        }
        .background(Color(.systemBackground))
        .confirmationDialog(deleteTitle, isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { req in
            Button(req.ids.count == 1 ? "Delete page" : "Delete pages", role: .destructive) { performDelete(req.ids) }
        } message: { _ in
            Text("Their strokes and content will be removed from this notebook.")
        }
        .confirmationDialog("Move to…", isPresented: $moving, titleVisibility: .visible) {
            ForEach(moveTargets, id: \.label) { t in Button(t.label) { performMove(at: t.at) } }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pages").font(.title2.weight(.semibold))
                Text("Tap to jump to a page · hold and drag to reorder").font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Button(selecting ? "Done" : "Select") { setSelecting(!selecting) }
            Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }
                .accessibilityLabel("Close")
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
    }

    private func setSelecting(_ on: Bool) {
        selecting = on
        selected = []
    }

    // MARK: Cards

    private func card(_ page: Page, number: Int) -> some View {
        let selectable = selectableIds.contains(page.id)
        let isSelected = selected.contains(page.id)
        let aspect = page.pageWidth / page.pageHeight
        return VStack(spacing: 8) {
            Button {
                if selecting {
                    guard selectable else { return }
                    if isSelected { selected.remove(page.id) } else { selected.insert(page.id) }
                } else {
                    dismiss()
                    session.goToPage(page.id)
                }
            } label: {
                VStack(spacing: 8) {
                    ZStack {
                        Rectangle().fill(Color(.tertiarySystemFill))
                        if let image = thumbs[page.id] {
                            Image(uiImage: image).resizable().scaledToFill()
                        }
                    }
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isSelected ? Color.accentColor : Color(.separator), lineWidth: isSelected ? 3 : 0.5))
                    .overlay(alignment: .topTrailing) {
                        if selecting && selectable {
                            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                .font(.title2)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                                .background(Circle().fill(.background))
                                .padding(8)
                        }
                    }
                    Text("Page \(number)").font(.subheadline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Go to page \(number)")
            .draggable(page.id)
            .dropDestination(for: String.self) { items, _ in
                guard !selecting, let dragged = items.first, dragged != page.id else { return false }
                session.reorder(to: pages.map(\.id).moving(dragged, before: page.id))
                return true
            }

            HStack(spacing: 18) {
                Button {
                    session.duplicatePage(page.id)
                    thumbs[page.id] = nil
                } label: { Image(systemName: "plus.square.on.square") }
                    .accessibilityLabel("Duplicate page")
                Button { deleting = DeleteRequest(ids: [page.id]) } label: { Image(systemName: "trash") }
                    .accessibilityLabel("Delete page")
            }
            .buttonStyle(.borderless)
            .disabled(selecting)
            .opacity(selecting ? 0.3 : 1)
        }
        .task(id: page.id) { await loadThumb(page) }
    }

    private func loadThumb(_ page: Page) async {
        if thumbs[page.id] != nil { return }
        let doc = session.doc
        let source = PageRenderer.Source(page: page, strokes: doc.strokes(of: page.id), elements: doc.elements(of: page.id))
        let image = await Task.detached(priority: .userInitiated) { PageRenderer.thumbnail(source, width: 420) }.value
        thumbs[page.id] = image
    }

    // MARK: Selection bar

    private var selectionBar: some View {
        HStack(spacing: 16) {
            Text(selected.count == 1 ? "1 selected" : "\(selected.count) selected").foregroundStyle(.secondary)
            Spacer()
            Button("Select all") { selected = Set(selectableIds) }
                .disabled(selected.count >= selectableIds.count)
            Button("Move") { moving = true }.disabled(selected.isEmpty)
            Button("Delete", role: .destructive) { deleting = DeleteRequest(ids: pages.map(\.id).filter { selected.contains($0) }) }
                .disabled(selected.isEmpty)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.regularMaterial)
    }

    // MARK: Delete / move

    private var deleteTitle: String {
        guard let req = deleting else { return "" }
        if req.ids.count == 1, let p = pages.first(where: { $0.id == req.ids[0] }) { return "Delete page \(p.index + 1)?" }
        return "Delete \(req.ids.count) pages?"
    }

    private func performDelete(_ ids: [String]) {
        for id in ids { thumbs[id] = nil }
        if ids.count == 1 { session.deletePage(ids[0]) } else { session.deletePages(ids) }
        selected = selected.subtracting(ids)
    }

    private struct MoveTarget { let label: String; let at: Int }

    /// Where a multi-select Move can put the pages: the start, the end, or before any page that isn't moving.
    private var moveTargets: [MoveTarget] {
        let ids = pages.map(\.id)
        let rest = ids.filter { !selected.contains($0) }
        let endAt = (ids.last.map { session.doc.isBlank($0) && !selected.contains($0) } ?? false) ? max(rest.count - 1, 0) : rest.count
        var out = [MoveTarget(label: "Start", at: 0), MoveTarget(label: "End", at: endAt)]
        for (at, id) in rest.enumerated() {
            if at == endAt && endAt < rest.count { continue } // the trailing blank: "Before" it is "End"
            if let n = ids.firstIndex(of: id) { out.append(MoveTarget(label: "Before page \(n + 1)", at: at)) }
        }
        return out
    }

    private func performMove(at: Int) {
        let ids = pages.map(\.id)
        let picked = ids.filter { selected.contains($0) } // keeps their relative order
        let rest = ids.filter { !selected.contains($0) }
        let after = Array(rest[0..<min(at, rest.count)]) + picked + Array(rest[min(at, rest.count)...])
        if after != ids { session.reorder(to: after) }
        selected = []
    }
}
