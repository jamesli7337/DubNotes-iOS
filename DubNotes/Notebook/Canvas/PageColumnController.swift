import SwiftUI
import UIKit

/// The column of pages: one zoomable scroll view holding every page top to bottom, a "Page N" label over each.
/// Only pages near the viewport carry heavy layers (canvas, drawing); the rest are paper-coloured placeholders.
final class PageColumnController: NSObject, UIScrollViewDelegate {
    static let zoomMin: CGFloat = 0.5
    static let zoomMax: CGFloat = 3
    /// Gap kept between page edges and the viewport sides, at the fit-to-width zoom.
    static let sideMargin: CGFloat = 12
    static let labelHeight: CGFloat = 26
    static let pageGap: CGFloat = 18
    static let topPad: CGFloat = 4
    /// Preload band around the viewport, in screen points, and the cap on it in page units.
    static let mountMarginScreen: CGFloat = 1200
    static let mountMarginMax: CGFloat = 1400
    static let maxMountedPages = 5

    private struct Slot {
        let view: PageView
        let label: UILabel
    }

    unowned let session: NotebookSession
    let container = UIView()
    let scrollView = ColumnScrollView()
    private let content = UIView()
    private var slots: [String: Slot] = [:]
    private var order: [String] = []
    private var callout: CalloutView?
    private var emptyLasso: (view: PageView, frame: ItemFrame)?
    private var suppressSelection = false
    private var didInitialZoom = false
    private var keyboardHeight: CGFloat = 0
    private var lastToolSignature = ""
    private let aiOutline = AIModeOutlineView()

    var topInset: CGFloat = 0 { didSet { if topInset != oldValue { applyInsets() } } }
    var bottomInset: CGFloat = 0 { didSet { if bottomInset != oldValue { applyInsets() } } }
    var zoom: CGFloat { scrollView.zoomScale }

    init(session: NotebookSession) {
        self.session = session
        super.init()
        scrollView.delegate = self
        scrollView.controller = self
        scrollView.minimumZoomScale = Self.zoomMin
        scrollView.maximumZoomScale = Self.zoomMax
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.keyboardDismissMode = .interactive
        scrollView.backgroundColor = .clear
        scrollView.addSubview(content)
        scrollView.addGestureRecognizer(PencilSpy(target: nil, action: nil))
        container.backgroundColor = .clear
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(scrollView)
        session.column = self
        PencilDetector.onSeen = { [weak self] in self?.applyTouchPolicy() }
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        syncPages()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: Pages

    /// Reconciles the page views against the document: gone pages are torn down, new ones built, order restored.
    func syncPages() {
        let pages = session.doc.pages
        let wanted = Set(pages.map(\.id))
        for (id, slot) in slots where !wanted.contains(id) {
            slot.view.unmount()
            slot.view.removeFromSuperview()
            slot.label.removeFromSuperview()
            slots[id] = nil
        }
        for p in pages where slots[p.id] == nil {
            let v = PageView(pageId: p.id, session: session)
            v.column = self
            v.isUserInteractionEnabled = !session.aiMode
            let l = UILabel()
            l.font = UIFont.systemFont(ofSize: 13, weight: .medium)
            l.textColor = .secondaryLabel
            content.addSubview(l)
            content.addSubview(v)
            slots[p.id] = Slot(view: v, label: l)
        }
        order = pages.map(\.id)
        relayout()
        updateMounted()
        syncSelectionAfterStructure()
    }

    private func syncSelectionAfterStructure() {
        if let sel = session.selection, slots[sel.pageId] == nil { session.selection = nil }
        updateCallout()
    }

    /// Repaints these pages from the document.
    func refresh(pageIds: [String]) {
        var layoutChanged = false
        for id in pageIds {
            guard let slot = slots[id], let page = session.doc.page(id) else { continue }
            let sizeChanged = abs(slot.view.bounds.width - CGFloat(page.pageWidth)) > 0.5
                || abs(slot.view.bounds.height - CGFloat(page.pageHeight)) > 0.5
            if sizeChanged { layoutChanged = true }
            if slot.view.mounted { slot.view.reload() } else { slot.view.paperChanged() }
        }
        if layoutChanged { relayout() }
        updateCallout()
    }

    func paperChanged() {
        for slot in slots.values { slot.view.paperChanged() }
    }

    private func relayout() {
        let pages = session.doc.pages
        let maxW = pages.map { CGFloat($0.pageWidth) }.max() ?? CGFloat(PageUnits.width)
        let contentW = maxW + Self.sideMargin * 2
        var y = Self.topPad
        for (i, p) in pages.enumerated() {
            guard let slot = slots[p.id] else { continue }
            let w = CGFloat(p.pageWidth), h = CGFloat(p.pageHeight)
            let x = (contentW - w) / 2
            slot.label.text = "Page \(i + 1)"
            slot.label.frame = CGRect(x: x + 2, y: y, width: w, height: Self.labelHeight)
            y += Self.labelHeight
            slot.view.bounds = CGRect(x: 0, y: 0, width: w, height: h)
            slot.view.frame = CGRect(x: x, y: y, width: w, height: h)
            y += h + Self.pageGap
        }
        contentSize = CGSize(width: contentW, height: y)
        applyContentSize()
        updateAIOutline()
    }

    private var contentSize = CGSize.zero

    private func applyContentSize() {
        let z = scrollView.zoomScale
        content.bounds = CGRect(origin: .zero, size: contentSize)
        content.center = CGPoint(x: contentSize.width * z / 2, y: contentSize.height * z / 2)
        scrollView.contentSize = CGSize(width: contentSize.width * z, height: contentSize.height * z)
        applyInsets()
    }

    private func applyInsets() {
        let slack = max((scrollView.bounds.width - scrollView.contentSize.width) / 2, 0)
        let insets = UIEdgeInsets(top: topInset, left: slack, bottom: bottomInset + keyboardHeight + scrollView.bounds.height * 0.4, right: slack)
        if scrollView.contentInset != insets { scrollView.contentInset = insets }
    }

    // MARK: Layout from the scroll view

    func didLayout() {
        guard scrollView.bounds.width > 0 else { return }
        if !didInitialZoom {
            didInitialZoom = true
            // open fitted to the width when the page is wider than the screen, 100% otherwise
            let firstW = CGFloat(session.doc.pages.first?.pageWidth ?? PageUnits.width)
            let fit = min(1, (scrollView.bounds.width - Self.sideMargin * 2) / firstW)
            scrollView.zoomScale = max(Self.zoomMin, fit > 0 ? fit : 1)
            applyContentSize()
            scrollView.contentOffset = CGPoint(x: -scrollView.contentInset.left, y: -scrollView.contentInset.top)
        }
        applyInsets()
        updateMounted()
        updateCallout()
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        applyInsets()
        updateMounted()
        updateCallout()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        for slot in slots.values { slot.view.updateScale() }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateMounted()
        updateCurrentPage()
        updateCallout()
    }

    // MARK: Mounting

    private func visibleRect() -> CGRect {
        scrollView.convert(scrollView.bounds, to: content)
    }

    /// Mounts the pages near the viewport (nearest five at most) and tears the rest down.
    func updateMounted() {
        guard scrollView.bounds.height > 0 else { return }
        let z = max(scrollView.zoomScale, 0.1)
        let margin = min(Self.mountMarginScreen / z, Self.mountMarginMax)
        let vis = visibleRect()
        let band = vis.insetBy(dx: -margin, dy: -margin)
        let midY = vis.midY
        var near: [(id: String, dist: CGFloat)] = []
        for id in order {
            guard let v = slots[id]?.view else { continue }
            if v.frame.intersects(band) { near.append((id, abs(v.frame.midY - midY))) }
        }
        near.sort { $0.dist < $1.dist }
        let keep = Set(near.prefix(Self.maxMountedPages).map { $0.id })
        for id in order {
            guard let v = slots[id]?.view else { continue }
            if keep.contains(id) {
                if !v.mounted {
                    v.mount()
                    v.updateScale()
                    if session.aiMode { fadeForAIMode(v) }
                }
            } else if v.mounted {
                v.unmount()
            }
        }
    }

    private func updateCurrentPage() {
        let midY = visibleRect().midY
        var best: String?
        var bestD = CGFloat.infinity
        for id in order {
            guard let v = slots[id]?.view else { continue }
            let d = v.frame.minY <= midY && midY <= v.frame.maxY ? 0 : min(abs(v.frame.minY - midY), abs(v.frame.maxY - midY))
            if d < bestD { bestD = d; best = id }
        }
        if let b = best, session.currentPageId != b {
            session.currentPageId = b
            updateAIOutline()
        }
    }

    // MARK: AI mode

    /// Page content fades under the outline; paper colour stays (it is the page view's own background).
    private static let aiFadeAlpha: CGFloat = 0.25

    private func fadeForAIMode(_ v: PageView) {
        let alpha: CGFloat = session.aiMode ? Self.aiFadeAlpha : 1
        for sub in v.subviews { sub.alpha = alpha }
    }

    /// Called after `session.aiMode` flips: stops (or restores) page input, fades the content, shows the outline.
    func aiModeChanged() {
        let on = session.aiMode
        for slot in slots.values {
            slot.view.isUserInteractionEnabled = !on
            fadeForAIMode(slot.view)
        }
        if on {
            content.addSubview(aiOutline)
        } else {
            aiOutline.removeFromSuperview()
        }
        updateAIOutline()
    }

    private func updateAIOutline() {
        guard session.aiMode, let id = session.currentPage?.id, let v = slots[id]?.view else {
            aiOutline.isHidden = true
            return
        }
        aiOutline.isHidden = false
        aiOutline.place(around: v.frame, labelRowHeight: Self.labelHeight)
        content.bringSubviewToFront(aiOutline)
    }

    func scrollToPage(_ id: String) {
        guard let v = slots[id]?.view else { return }
        let z = scrollView.zoomScale
        let y = v.frame.minY * z - topInset - 14
        let maxY = max(scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom, -topInset)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(max(y, -topInset), maxY)), animated: true)
    }

    // MARK: Tools

    /// Which touches pan the column, for the current tool. The Hand tool pans with the Pencil too; tools that
    /// take a drag of their own use two fingers to pan until a Pencil has been seen (a finger then drives them,
    /// the way a mouse does on the web).
    func applyTouchPolicy() {
        let kind = session.settings.kind
        var types: [UITouch.TouchType] = [.direct, .indirectPointer]
        if kind == .hand { types.append(.pencil) }
        scrollView.panGestureRecognizer.allowedTouchTypes = types.map { NSNumber(value: $0.rawValue) }
        let fingerTools: Set<ToolKind> = [.shapes, .tape, .laser, .lasso, .text]
        scrollView.panGestureRecognizer.minimumNumberOfTouches = (fingerTools.contains(kind) && !PencilDetector.seen) ? 2 : 1
    }

    /// Called when tool settings, the guide or the document's paper changed.
    func toolsChanged(signature: String) {
        guard signature != lastToolSignature else { return }
        lastToolSignature = signature
        applyTouchPolicy()
        for slot in slots.values where slot.view.mounted { slot.view.toolChanged() }
        updateCallout()
    }

    func syncGuides() {
        for slot in slots.values {
            slot.view.syncGuide()
            if session.aiMode { fadeForAIMode(slot.view) }
        }
    }

    // MARK: Selection and callout

    func deactivateAll() {
        for slot in slots.values {
            slot.view.commitEdit()
            slot.view.clearSelection()
        }
        hideCallout()
    }

    func cancelPendingInput() -> Bool {
        for slot in slots.values where slot.view.cancelInput() { return true }
        return false
    }

    func clearSelectionIfStale() {
        for slot in slots.values { slot.view.pruneSelection() }
    }

    func selectionChanged(on view: PageView) {
        if suppressSelection { return }
        emptyLasso = nil
        if view.hasSelection {
            suppressSelection = true
            for slot in slots.values where slot.view !== view && slot.view.hasSelection { slot.view.clearSelection() }
            suppressSelection = false
            session.selection = view.selectionInfo
        } else if session.selection?.pageId == view.pageId {
            session.selection = nil
        }
        updateCallout()
    }

    func selectionFrameChanged(on view: PageView) {
        positionCallout()
    }

    func emptyLassoSelected(on view: PageView, frame: ItemFrame) {
        emptyLasso = (view, frame)
        updateCallout()
    }

    /// A new press anywhere closes the empty-lasso "Paste" pill.
    func pressBegan() {
        if emptyLasso != nil { hideCallout() }
    }

    func hideCallout() {
        emptyLasso = nil
        callout?.removeFromSuperview()
        callout = nil
    }

    private var calloutSubject: (view: PageView, rect: CGRect, isEmpty: Bool)? {
        if let sel = session.selection, let v = slots[sel.pageId]?.view, let r = v.selectionBounds, v.hasSelection {
            return (v, r, false)
        }
        if let e = emptyLasso {
            return (e.view, CGRect(x: e.frame.x, y: e.frame.y, width: e.frame.w, height: e.frame.h), true)
        }
        return nil
    }

    private func updateCallout() {
        let kind = session.settings.kind
        guard let subject = calloutSubject, kind == .lasso || kind == .tape else {
            callout?.removeFromSuperview()
            callout = nil
            return
        }
        if callout == nil {
            let c = CalloutView()
            container.addSubview(c)
            callout = c
        }
        let view = subject.view
        let clipboardHas = !session.clipboard.isEmpty
        if subject.isEmpty {
            callout?.setActions([.init(title: "Paste", enabled: clipboardHas) { [weak self, weak view] in
                guard let self, let view, let e = self.emptyLasso else { return }
                view.paste(at: Pt(e.frame.x + e.frame.w / 2, e.frame.y + e.frame.h / 2))
                self.hideCallout()
            }])
        } else {
            var actions: [CalloutView.Action] = [
                .init(title: "Duplicate", enabled: true) { [weak view] in view?.duplicateSelection() },
                .init(title: "Cut", enabled: true) { [weak view] in view?.cutSelection() },
                .init(title: "Copy", enabled: true) { [weak view] in _ = view?.copySelection() },
            ]
            if clipboardHas { actions.append(.init(title: "Paste", enabled: true) { [weak view] in view?.paste() }) }
            actions.append(.init(title: "Delete", enabled: true) { [weak view] in view?.deleteSelection() })
            callout?.setActions(actions)
        }
        callout?.layoutIfNeeded()
        positionCallout()
    }

    /// Centres the callout above the selection, flipping below when there is no room, and hides it when the
    /// selection has scrolled out of view.
    private func positionCallout() {
        guard let callout, let subject = calloutSubject else { return }
        let box = container.convert(subject.rect, from: subject.view)
        let size = callout.fittingSize()
        let margin: CGFloat = 8, gap: CGFloat = 10
        let visibleArea = container.bounds.inset(by: UIEdgeInsets(top: topInset + margin, left: margin, bottom: bottomInset + margin, right: margin))
        if !box.intersects(container.bounds) {
            callout.isHidden = true
            return
        }
        callout.isHidden = false
        var y = box.minY - gap - size.height
        if y < visibleArea.minY { y = box.maxY + gap }
        y = min(max(y, visibleArea.minY), max(visibleArea.maxY - size.height, visibleArea.minY))
        var x = box.midX - size.width / 2
        x = min(max(x, margin), container.bounds.width - size.width - margin)
        callout.frame = CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Actions for the dock and menus

    private var selectedView: PageView? { session.selection.flatMap { slots[$0.pageId]?.view } }
    private var currentView: PageView? { session.currentPageId.flatMap { slots[$0]?.view } ?? order.first.flatMap { slots[$0]?.view } }

    func recolorSelection(_ tool: InkTool, color: String) { selectedView?.recolorSelection(tool, color: color) }

    func deleteSelection() { selectedView?.deleteSelection() }

    func pasteIntoCurrentPage() { currentView?.paste() }

    /// Drops a loaded image in the middle of the page in view and switches to the lasso so it can be moved.
    func insertImage(src: String, width: Double, height: Double) {
        guard let v = currentView else { return }
        deactivateAll()
        var s = session.settings
        if s.kind != .lasso { s.kind = .lasso }
        session.settings = s
        v.insertImage(src: src, naturalWidth: width, naturalHeight: height)
    }

    // MARK: Text editing and the keyboard

    func editorFrameChanged(on view: PageView, rect: CGRect) {
        let inScroll = scrollView.convert(rect, from: view)
        scrollView.scrollRectToVisible(inScroll.insetBy(dx: 0, dy: -40), animated: false)
    }

    @objc private func keyboardChanged(_ note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              let window = container.window else { return }
        let local = container.convert(container.bounds, to: window)
        let overlap = max(local.maxY - end.minY, 0)
        keyboardHeight = overlap
        applyInsets()
    }
}

/// A scroll view that tells its controller when it has been laid out.
final class ColumnScrollView: UIScrollView {
    weak var controller: PageColumnController?
    private var lastSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != lastSize {
            lastSize = bounds.size
            controller?.didLayout()
        }
    }
}

/// Hosts the column in SwiftUI. Tool, guide and inset changes arrive as properties so SwiftUI tracks them.
struct PageColumnRepresentable: UIViewRepresentable {
    let session: NotebookSession
    let settings: ToolSettings
    let guideKind: GuideKind?
    let guidePageId: String?
    let paperRevision: Int
    let topInset: CGFloat
    let bottomInset: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var controller: PageColumnController?
    }

    func makeUIView(context: Context) -> UIView {
        let c = PageColumnController(session: session)
        context.coordinator.controller = c
        return c.container
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let c = context.coordinator.controller else { return }
        c.topInset = topInset
        c.bottomInset = bottomInset
        c.syncGuides()
        c.toolsChanged(signature: signature)
    }

    private var signature: String {
        let s = settings
        return [s.kind.rawValue, s.penColor, "\(s.penSize)", s.highlighterColor, "\(s.highlighterSize)", s.eraserMode.rawValue,
                s.lassoShape.rawValue, s.shapeKind.rawValue, s.textColor, "\(paperRevision)", guideKind?.rawValue ?? "-"].joined(separator: "|")
    }
}
