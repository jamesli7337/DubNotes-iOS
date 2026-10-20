import UIKit

// In-place text editing: a UITextView laid over the box while it is edited, committed back as an element.
extension PageView {
    func newText(at pt: Pt) -> PageElement {
        let s = settings
        let size = ToolSettings.textDefaultSize
        let page = currentPage
        let lineH = size * TextLayout.lineHeightFactor
        // a board has no page edge to keep the box inside
        let w = isBoard ? ToolSettings.textDefaultWidth : max(min(ToolSettings.textDefaultWidth, page.pageWidth - pt.x), 60)
        let y = isBoard ? pt.y - lineH * 0.5 : min(max(pt.y - lineH * 0.5, 0), page.pageHeight - size)
        let t = PageElement.Text(text: "", color: s.textColor, fontSize: size, bg: nil)
        return PageElement(id: UUID().uuidString, pageId: pageId, notebookId: session.doc.id,
                           x: pt.x, y: y,
                           w: w, h: lineH, rotation: 0, createdAt: LibraryStore.now(), content: .text(t))
    }

    private func configure(_ tv: UITextView, for el: PageElement, text t: PageElement.Text) {
        let paper = currentPage.paper
        let lineH = CGFloat(t.fontSize * TextLayout.lineHeightFactor)
        let para = NSMutableParagraphStyle()
        para.minimumLineHeight = lineH
        para.maximumLineHeight = lineH
        tv.typingAttributes = [.font: TextLayout.font(t.fontSize),
                               .foregroundColor: ElementRenderer.ink(t.color, paper),
                               .paragraphStyle: para]
        tv.font = TextLayout.font(t.fontSize)
        tv.textColor = ElementRenderer.ink(t.color, paper)
    }

    /// Opens the editor over `el` (an existing text element, or a brand-new empty one).
    func startEdit(_ el: PageElement, isNew: Bool) {
        guard case .text(let t) = el.content else { return }
        commitEdit()
        let tv = UITextView(frame: .zero)
        tv.backgroundColor = .clear
        tv.isScrollEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer.lineFragmentPadding = 0
        tv.autocorrectionType = .no
        tv.spellCheckingType = .no
        tv.autocapitalizationType = .none
        tv.delegate = self
        tv.accessibilityLabel = "Text box"
        configure(tv, for: el, text: t)
        tv.text = t.text
        editor = TextEdit(textView: tv, element: el, isNew: isNew)
        addSubview(tv)
        layoutEditor()
        hiddenIds.insert(el.id)
        back?.hiddenIds = hiddenIds
        back?.setNeedsDisplay()
        selectedIds = [el.id]
        refreshSelection()
        column?.selectionChanged(on: self)
        tv.becomeFirstResponder()
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
    }

    private func layoutEditor() {
        guard let ed = editor, case .text(let t) = ed.element.content else { return }
        let h = max(ed.element.h, t.fontSize * TextLayout.lineHeightFactor)
        ed.textView.transform = .identity
        ed.textView.frame = CGRect(x: ed.element.x, y: ed.element.y, width: ed.element.w, height: h)
        ed.textView.transform = CGAffineTransform(rotationAngle: CGFloat(ed.element.rotation))
        column?.editorFrameChanged(on: self, rect: ed.textView.frame)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard var ed = editor, textView === ed.textView, case .text(let t) = ed.element.content else { return }
        ed.element.h = TextLayout.layout(textView.text, fontSize: t.fontSize, maxWidth: ed.element.w).height
        editor = ed
        layoutEditor()
        if var f = selectionFrame {
            f.h = ed.element.h
            selectionFrame = f
            overlay.setNeedsDisplay()
        }
    }

    /// Commits the open edit: an empty new box is dropped, an emptied old one is deleted, anything else is saved.
    func commitEdit() {
        guard let ed = editor, case .text(let old) = ed.element.content else { return }
        editor = nil
        let text = ed.textView.text ?? ""
        ed.textView.resignFirstResponder()
        ed.textView.removeFromSuperview()
        hiddenIds.remove(ed.element.id)
        back?.hiddenIds = hiddenIds

        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if !ed.isNew, let existing = session.doc.item(ed.element.id, on: pageId) {
                session.remove(ids: [existing.id], from: pageId)
            } else {
                reload()
            }
            selectedIds = []
            selectionFrame = nil
            overlay.setNeedsDisplay()
            column?.selectionChanged(on: self)
            return
        }

        var next = ed.element
        next.content = .text(PageElement.Text(text: text, color: old.color, fontSize: old.fontSize, bg: old.bg))
        next.h = TextLayout.layout(text, fontSize: old.fontSize, maxWidth: next.w).height
        if ed.isNew {
            session.add([.element(next)], to: pageId)
        } else if let current = session.doc.item(next.id, on: pageId) {
            session.replace(before: [current], after: [.element(next)], on: pageId)
        }
        selectedIds = [next.id]
        refreshSelection()
        column?.selectionChanged(on: self)
    }

    /// A tap outside while editing; the page column calls this when the keyboard should go away.
    func endEditing() {
        commitEdit()
    }
}
