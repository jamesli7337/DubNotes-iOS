import UIKit

/// The floating pill over a selection: Duplicate, Cut, Copy, [Paste], Delete — like iOS's own text-selection
/// callout, which isn't reachable for canvas content. An empty lasso gets a pill with only Paste.
final class CalloutView: UIVisualEffectView {
    struct Action {
        let title: String
        let enabled: Bool
        let run: () -> Void
    }

    private let stack = UIStackView()

    init() {
        super.init(effect: UIBlurEffect(style: .systemThickMaterial))
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 0.5
        layer.borderColor = UIColor.separator.cgColor
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func setActions(_ actions: [Action]) {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (i, a) in actions.enumerated() {
            if i > 0 {
                let sep = UIView()
                sep.backgroundColor = .separator
                sep.translatesAutoresizingMaskIntoConstraints = false
                sep.widthAnchor.constraint(equalToConstant: 0.5).isActive = true
                sep.heightAnchor.constraint(equalToConstant: 20).isActive = true
                stack.addArrangedSubview(sep)
            }
            var config = UIButton.Configuration.plain()
            config.title = a.title
            config.baseForegroundColor = a.title == "Delete" ? .systemRed : .label
            config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14)
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { c in
                var c = c
                c.font = UIFont.systemFont(ofSize: 15, weight: .medium)
                return c
            }
            let button = UIButton(configuration: config, primaryAction: UIAction { _ in a.run() })
            button.isEnabled = a.enabled
            stack.addArrangedSubview(button)
        }
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize { stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }

    /// The pill's natural size, for placing it before it has been laid out.
    func fittingSize() -> CGSize {
        stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    }
}
