import PencilKit
import UIKit

// Selection, transform drags and the actions behind the selection callout (Duplicate, Cut, Copy, Paste,
// Delete) plus recolouring.
extension PageView {
    // MARK: State

    func selectedItems() -> [PageItem] {
        if let xf { return xf.startItems }
        let ids = selectedIds
        return session.doc.items(of: pageId).filter { ids.contains($0.id) }
    }

    var hasSelection: Bool { !selectedIds.isEmpty }

    /// Selects exactly these ids; one selection at a time across the notebook.
    func select(ids: Set<String>) {
        selectedIds = ids
        refreshSelection()
        column?.selectionChanged(on: self)
    }

    func clearSelection() {
        guard !selectedIds.isEmpty || selectionFrame != nil else { return }
        selectedIds = []
        selectionFrame = nil
        xf = nil
        if !hiddenIds.isEmpty {
            hiddenIds = []
            back?.hiddenIds = []
            back?.setNeedsDisplay()
            reloadInk()
        }
        overlay.setNeedsDisplay()
        column?.selectionChanged(on: self)
    }

    /// Drops ids that no longer exist (after an undo, an erase, a delete).
    func pruneSelection() {
        guard !selectedIds.isEmpty else { return }
        let live = Set(session.doc.items(of: pageId).map(\.id))
        let kept = selectedIds.intersection(live)
        if kept == selectedIds { refreshSelection(); return }
        selectedIds = kept
        refreshSelection()
        column?.selectionChanged(on: self)
    }

    /// Recomputes the frame and handles for the current selection.
    func refreshSelection() {
        let items = selectedItems()
        if selectedIds.isEmpty || items.isEmpty {
            selectionFrame = nil
        } else {
            selectionFrame = Geometry.itemsFrame(items)
            selectionStyle = SelectionStyle.style(for: items)
        }
        overlay.setNeedsDisplay()
    }

    var selectionInfo: SelectionInfo? {
        let items = selectedItems()
        guard !items.isEmpty else { return nil }
        var pen = false, hi = false
        for case .stroke(let s) in items {
            if s.tool == .pen { pen = true } else { hi = true }
        }
        return SelectionInfo(pageId: pageId, count: items.count, hasPen: pen, hasHighlighter: hi)
    }

    // MARK: Transform drag

    func beginTransform(_ handle: SelectionHandle, at pt: Pt) {
        let items = selectedItems()
        guard let frame = Geometry.itemsFrame(items), !items.isEmpty else {
            mode = .dismiss
            return
        }
        selectionStyle = SelectionStyle.style(for: items)
        var image: UIImage?
        var imageRect = CGRect.zero
        let strokes = items.compactMap { item -> Stroke? in
            if case .stroke(let s) = item { return s } else { return nil }
        }
        if !strokes.isEmpty {
            let drawing = StrokeConverter.drawing(strokes, paper: currentPage.paper)
            imageRect = drawing.bounds.insetBy(dx: -4, dy: -4)
            if !imageRect.isNull && imageRect.width > 0 && imageRect.height > 0 {
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    image = drawing.image(from: imageRect, scale: 2)
                }
            }
        }
        xf = TransformDrag(handle: handle, style: selectionStyle, startFrame: frame, startItems: items, pressPt: pt,
                           preview: items, strokeImage: image, strokeImageRect: imageRect)
        mode = .transform
        // lift the originals off the page; the overlay draws them while they move
        hiddenIds = Set(items.map(\.id))
        back?.hiddenIds = hiddenIds
        back?.setNeedsDisplay()
        reloadInk()
        overlay.setNeedsDisplay()
    }

    func updateTransform(to pt: Pt) {
        guard var drag = xf else { return }
        let start = drag.startFrame
        var frame = start
        switch drag.handle {
        case .move:
            frame = SelectionMath.moved(start, dx: pt.x - drag.pressPt.x, dy: pt.y - drag.pressPt.y)
        case .corner, .edge:
            frame = SelectionMath.resized(start, handle: drag.handle, to: pt, aspect: drag.style.aspect)
        case .rotate:
            frame = SelectionMath.rotated(start, to: pt)
        }
        // keep a text box's width-only resize from changing its type size (corner drags scale it)
        var items = Geometry.transformItems(drag.startItems, from: start, to: frame)
        if case .edge = drag.handle {
            items = zip(drag.startItems, items).map { orig, moved in
                if case .element(let o) = orig, case .text(let ot) = o.content, case .element(var m) = moved {
                    m.content = .text(PageElement.Text(text: ot.text, color: ot.color, fontSize: ot.fontSize, bg: ot.bg))
                    m.h = TextLayout.height(of: ot, width: m.w)
                    return .element(m)
                }
                return moved
            }
        }
        drag.preview = items
        xf = drag
        selectionFrame = frame
        overlay.setNeedsDisplay()
        column?.selectionFrameChanged(on: self)
    }

    func endTransform(commit: Bool) {
        guard let drag = xf else { return }
        xf = nil
        hiddenIds = []
        back?.hiddenIds = []
        let changed = commit && drag.preview != drag.startItems
        if changed {
            // pages and text boxes were laid out against the old frame; keep stroke ids stable
            session.replace(before: drag.startItems, after: drag.preview, on: pageId)
            selectedIds = Set(drag.preview.map(\.id))
        } else {
            reload()
        }
        refreshSelection()
        column?.selectionChanged(on: self)
    }

    // MARK: Actions

    func deleteSelection() {
        let ids = selectedIds
        guard !ids.isEmpty else { return }
        selectedIds = []
        selectionFrame = nil
        session.remove(ids: ids, from: pageId)
        overlay.setNeedsDisplay()
        column?.selectionChanged(on: self)
    }

    func copySelection() -> Bool {
        let items = selectedItems()
        guard !items.isEmpty else { return false }
        session.copy(items, from: pageId)
        column?.selectionChanged(on: self)
        return true
    }

    func cutSelection() {
        if copySelection() { deleteSelection() }
    }

    func duplicateSelection() {
        let items = selectedItems()
        guard !items.isEmpty else { return }
        let copies = NotebookSession.clone(items, pageId: pageId, notebookId: session.doc.id,
                                           dx: NotebookSession.pasteOffset, dy: NotebookSession.pasteOffset,
                                           startingAt: LibraryStore.now())
        session.add(copies, to: pageId)
        select(ids: Set(copies.map(\.id)))
    }

    func paste(at point: Pt? = nil) {
        let items = session.pasteItems(onto: pageId, at: point)
        guard !items.isEmpty else { return }
        session.add(items, to: pageId)
        select(ids: Set(items.map(\.id)))
    }

    /// Recolours the selected pen or highlighter strokes.
    func recolorSelection(_ tool: InkTool, color: String) {
        let kind: Stroke.Tool = tool == .pen ? .pen : .highlighter
        let before = selectedItems()
        let after: [PageItem] = before.map { item in
            if case .stroke(var s) = item, s.tool == kind {
                s.color = color
                return .stroke(s)
            }
            return item
        }
        session.replace(before: before, after: after, on: pageId)
        refreshSelection()
    }

    /// Where a frame sits in this view's coordinates, for placing the callout.
    var selectionBounds: CGRect? {
        guard let f = selectionFrame else { return nil }
        let r = Geometry.aabb(Geometry.frameCorners(f))
        return CGRect(x: r.x, y: r.y, width: r.w, height: r.h)
    }

    // MARK: Insert image

    /// Puts a loaded image in the middle of the page, selected.
    func insertImage(src: String, naturalWidth: Double, naturalHeight: Double) {
        let page = currentPage
        // on a board the image is sized like a normal page's and dropped in the middle of what is on screen
        let vis = isBoard ? (column?.visibleRect(in: self) ?? .zero) : .zero
        let sizeW = isBoard ? PageUnits.width : page.pageWidth
        let sizeH = isBoard ? PageUnits.height : page.pageHeight
        let size = PageSizing.insertedImageSize(naturalW: naturalWidth, naturalH: naturalHeight, pageW: sizeW, pageH: sizeH)
        let midX = isBoard ? (vis.isEmpty ? NotebookDocument.boardChunkSize / 2 : Double(vis.midX)) : page.pageWidth / 2
        let midY = isBoard ? (vis.isEmpty ? NotebookDocument.boardChunkSize / 2 : Double(vis.midY)) : page.pageHeight / 2
        let el = PageElement(id: UUID().uuidString, pageId: pageId, notebookId: session.doc.id,
                             x: midX - size.w / 2, y: midY - size.h / 2, w: size.w, h: size.h,
                             rotation: 0, createdAt: LibraryStore.now(), content: .image(PageElement.Image(src: src)))
        session.add([.element(el)], to: pageId)
        select(ids: [el.id])
    }
}
