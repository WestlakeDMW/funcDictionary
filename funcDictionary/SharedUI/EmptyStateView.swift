import UIKit


final class EmptyStateView: UIView {
    private let stackView = UIStackView()

    init(
        symbolName: String,
        title: String,
        message: String,
        actions: [(title: String, identifier: String, handler: () -> Void)] = []
    ) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        accessibilityIdentifier = "empty-state"

        let imageView = UIImageView(image: UIImage(systemName: symbolName))
        imageView.tintColor = .secondaryLabel
        imageView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 42,
            weight: .regular
        )
        imageView.accessibilityElementsHidden = true

        let titleLabel = UILabel()
        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textAlignment = .center
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        titleLabel.text = title

        let messageLabel = UILabel()
        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textAlignment = .center
        messageLabel.textColor = .secondaryLabel
        messageLabel.numberOfLines = 0
        messageLabel.text = message

        stackView.axis = .vertical
        stackView.alignment = .fill
        stackView.spacing = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(messageLabel)

        for action in actions {
            let button = UIButton(configuration: .bordered())
            button.configuration?.title = action.title
            button.configuration?.image = UIImage(systemName: "arrow.right")
            button.configuration?.imagePadding = 8
            button.configuration?.cornerStyle = .medium
            button.accessibilityIdentifier = action.identifier
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            button.addAction(UIAction { _ in action.handler() }, for: .primaryActionTriggered)
            stackView.addArrangedSubview(button)
        }

        addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.widthAnchor.constraint(lessThanOrEqualToConstant: 420)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}