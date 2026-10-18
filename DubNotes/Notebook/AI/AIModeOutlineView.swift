import UIKit

/// The violet outline drawn around the current page while AI mode is on, with an "AI mode" label at its top
/// right (in the row where the "Page N" label sits). It lives in the column's zoomed content view, ignores touches.
final class AIModeOutlineView: UIView {
    private static let inset: CGFloat = 3
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.borderWidth = 3
        layer.cornerRadius = 6 + Self.inset
        label.text = "AI mode"
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.sizeToFit()
        addSubview(label)
        refreshColors()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        refreshColors()
    }

    private func refreshColors() {
        let color = AITheme.uiVioletText.resolvedColor(with: traitCollection)
        layer.borderColor = color.cgColor
        label.textColor = color
    }

    /// Wraps `pageFrame` (in the column's content space); `labelRowHeight` is the strip above the page.
    func place(around pageFrame: CGRect, labelRowHeight: CGFloat) {
        frame = pageFrame.insetBy(dx: -Self.inset, dy: -Self.inset)
        label.frame = CGRect(x: bounds.width - label.bounds.width - Self.inset - 2,
                             y: -labelRowHeight + (labelRowHeight - label.bounds.height) / 2 + Self.inset,
                             width: label.bounds.width, height: label.bounds.height)
    }
}
