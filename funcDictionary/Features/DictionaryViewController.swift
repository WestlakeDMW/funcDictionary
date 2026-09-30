import UIKit
import UniformTypeIdentifiers

@MainActor
final class DictionaryViewController: UIViewController {
    private enum Section: Hashable {
        case cluster(String)
        case standalone
    }

    private let store: AppStore
    private var project: Project?
    private var definitions: [Definition] = []
    private var definitionByID: [String: Definition] = [:]
    private var clusters: [Cluster] = []
    private var clusterByID: [String: Cluster] = [:]
    private var collapsedClusterIDs: Set<String> = []
    private var expandedIDs: Set<String> = []
    private var selectedDefinitionID: String?
    private var emptyState: EmptyStateView?
    private let collectionView: UICollectionView
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!

    init(store: AppStore, project: Project? = nil) {
        self.store = store
        self.project = project
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.showsSeparators = false
        configuration.backgroundColor = .systemGroupedBackground
        self.collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration)
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(
                barButtonSystemItem: .search,
                target: self,
                action: #selector(openSearch)
            ),
            UIBarButtonItem(
                title: "Review",
                style: .plain,
                target: self,
                action: #selector(openReview)
            )
        ]
        navigationItem.leftBarButtonItems = [
            UIBarButtonItem(
                title: "Import",
                style: .plain,
                target: self,
                action: #selector(importDelta)
            ),
            UIBarButtonItem(
                title: "Export",
                style: .plain,
                target: self,
                action: #selector(exportSnapshot)
            )
        ]
        navigationItem.rightBarButtonItems?[0].accessibilityIdentifier = "dictionary-search-button"
        navigationItem.rightBarButtonItems?[1].accessibilityIdentifier = "dictionary-review-button"
        navigationItem.leftBarButtonItems?[0].accessibilityIdentifier = "dictionary-import-button"
        navigationItem.leftBarButtonItems?[1].accessibilityIdentifier = "dictionary-export-button"

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .systemGroupedBackground
        collectionView.delegate = self
        collectionView.register(DefinitionCardCell.self, forCellWithReuseIdentifier: DefinitionCardCell.reuseIdentifier)
        collectionView.register(ClusterHeaderCell.self, forCellWithReuseIdentifier: ClusterHeaderCell.reuseIdentifier)
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        dataSource = UICollectionViewDiffableDataSource<Section, String>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, identifier in
            guard let self else { return nil }
            if let clusterID = Self.clusterID(from: identifier),
               let cluster = self.clusterByID[clusterID],
               let cell = collectionView.dequeueReusableCell(
                   withReuseIdentifier: ClusterHeaderCell.reuseIdentifier,
                   for: indexPath
               ) as? ClusterHeaderCell {
                cell.configure(
                    cluster: cluster,
                    collapsed: self.collapsedClusterIDs.contains(cluster.id)
                )
                return cell
            }
            guard let definitionID = Self.definitionID(from: identifier),
                  let definition = self.definitionByID[definitionID],
                  let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: DefinitionCardCell.reuseIdentifier,
                    for: indexPath
                  ) as? DefinitionCardCell else { return nil }
            cell.configure(
                definition: definition,
                expanded: self.expandedIDs.contains(definitionID),
                onTogglePin: { [weak self] in self?.togglePin(for: definitionID) },
                onReview: { [weak self] in self?.openReview() },
                onCopy: { [weak self] in self?.copyDefinition(for: definitionID) },
                onSendToAgent: { [weak self] in self?.sendToAgent(for: definitionID) }
            )
            return cell
        }

        let emptyState = EmptyStateView(
            symbolName: "books.vertical",
            title: "No Definitions Yet",
            message: "Create a project or import a validated Agent delta to start building its dictionary."
        )
        view.addSubview(emptyState)
        self.emptyState = emptyState
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    func setProject(_ project: Project?) {
        self.project = project
        selectedDefinitionID = nil
        expandedIDs.removeAll()
        reload()
    }

    private func reload() {
        title = project?.name ?? "Dictionary"
        guard let project else {
            definitions = []
            definitionByID = [:]
            clusters = []
            clusterByID = [:]
            applySnapshot()
            emptyState?.isHidden = false
            collectionView.isHidden = true
            return
        }
        do {
            let storedDefinitions = try store.repository.definitions(in: project.id)
            let calculatedAt = Date()
            definitions = storedDefinitions.map { definition in
                var enriched = definition
                enriched.changeHeat = ChangeHeatEngine.calculate(
                    for: definition,
                    in: storedDefinitions,
                    now: calculatedAt
                )
                enriched.lifecycle = LifecycleEngine.evaluate(
                    definition: definition,
                    in: storedDefinitions,
                    now: calculatedAt
                )
                return enriched
            }
            let definitionIDs = Set(definitions.map(\.id))
            clusters = try store.repository.clusters(in: project.id)
                .filter { cluster in
                    (cluster.status == .approved || cluster.status == .adjusted)
                        && cluster.definitionIDs.count >= 2
                        && cluster.definitionIDs.allSatisfy { definitionIDs.contains($0) }
                        && definitionIDs.contains(cluster.primaryDefinitionID)
                }
        } catch {
            definitions = []
            clusters = []
        }
        definitionByID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        clusterByID = Dictionary(uniqueKeysWithValues: clusters.map { ($0.id, $0) })
        applySnapshot()
        let isEmpty = definitions.isEmpty
        emptyState?.isHidden = !isEmpty
        collectionView.isHidden = isEmpty
    }

    private func applySnapshot(reloading identifier: String? = nil) {
        guard dataSource != nil else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        let clusterSections = clusters.map { Section.cluster($0.id) }
        snapshot.appendSections(clusterSections + [.standalone])
        var clusteredDefinitionIDs = Set<String>()
        var displayedClusterDefinitionIDs = Set<String>()
        for cluster in clusters {
            let headerID = Self.clusterItemID(for: cluster.id)
            snapshot.appendItems([headerID], toSection: .cluster(cluster.id))
            let memberIDs = cluster.definitionIDs.filter { definitionByID[$0] != nil }
            clusteredDefinitionIDs.formUnion(memberIDs)
            guard !collapsedClusterIDs.contains(cluster.id) else { continue }
            let uniqueMemberIDs = memberIDs.filter { displayedClusterDefinitionIDs.insert($0).inserted }
            snapshot.appendItems(uniqueMemberIDs, toSection: .cluster(cluster.id))
        }
        let standaloneIDs = definitions.map(\.id).filter { !clusteredDefinitionIDs.contains($0) }
        snapshot.appendItems(standaloneIDs, toSection: .standalone)
        if let identifier, dataSource.snapshot().itemIdentifiers.contains(identifier), snapshot.indexOfItem(identifier) != nil {
            snapshot.reloadItems([identifier])
        }
        dataSource.apply(snapshot, animatingDifferences: true)
    }

    private func toggleCluster(_ clusterID: String) {
        if collapsedClusterIDs.contains(clusterID) {
            collapsedClusterIDs.remove(clusterID)
        } else {
            collapsedClusterIDs.insert(clusterID)
        }
        applySnapshot()
    }

    private func toggleExpanded(for identifier: String) {
        if expandedIDs.contains(identifier) {
            expandedIDs.remove(identifier)
        } else {
            expandedIDs.insert(identifier)
        }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.applySnapshot(reloading: identifier)
        }
    }

    private func togglePin(for identifier: String) {
        guard var definition = definitionByID[identifier], let project else { return }
        switch definition.humanPriority?.level {
        case nil:
            definition.humanPriority = HumanPriority(
                level: .important,
                label: "Pinned by Human",
                note: "Pinned from the dictionary card."
            )
        case .important:
            definition.humanPriority = HumanPriority(
                level: .critical,
                label: "Critical by Human",
                note: "Critical definitions require protected change review."
            )
        case .critical:
            definition.humanPriority = nil
        }
        definition.updatedAt = Date()
        do {
            try store.repository.save(definition: definition, in: project.id)
            reload()
        } catch {
            let alert = UIAlertController(title: "Could Not Update Pin", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    @objc private func openSearch() {
        navigationController?.pushViewController(SearchViewController(store: store, project: project), animated: true)
    }

    @objc private func openReview() {
        navigationController?.pushViewController(ProposalReviewViewController(store: store, project: project), animated: true)
    }

    func openReviewFromMenu() {
        openReview()
    }

    func copyContextFromMenu() {
        guard let selectedDefinitionID else {
            presentError(title: "Select a Definition", message: "Select a definition card before using Copy Context.")
            return
        }
        copyDefinition(for: selectedDefinitionID)
    }

    func sendToAgentFromMenu() {
        guard let selectedDefinitionID else {
            presentError(title: "Select a Definition", message: "Select a definition card before using Send to Agent.")
            return
        }
        sendToAgent(for: selectedDefinitionID)
    }

    @objc private func importDelta() {
        guard project != nil else {
            presentError(title: "Choose a Project", message: "Import is available after selecting a project.")
            return
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.json], asCopy: true)
        picker.delegate = self
        present(picker, animated: true)
    }

    @objc private func exportSnapshot() {
        guard let project else {
            presentError(title: "Choose a Project", message: "Export is available after selecting a project.")
            return
        }
        do {
            let snapshot = ProjectSnapshot(
                project: project,
                definitions: definitions,
                clusters: try store.repository.clusters(in: project.id),
                agentContext: definitions.first.map {
                    AgentContextBuilder.make(for: $0, definitions: definitions)
                } ?? .empty,
                revision: try store.repository.currentRevision(in: project.id)
            )
            let exchangeRoot = applicationSupportDirectory().appendingPathComponent(".funcdictionary", isDirectory: true)
            var jpegDataBySnapshotID: [String: Data] = [:]
            if let snapshotAssets = store.snapshotAssets {
                for metadata in definitions.flatMap(\.snapshots) {
                    if let asset = try? snapshotAssets.read(snapshotID: metadata.id, projectID: project.id) {
                        jpegDataBySnapshotID[metadata.id] = asset.jpegData
                    }
                }
            }
            let urls = try FileExchangeStore(directory: ExchangeDirectory(rootURL: exchangeRoot)).write(
                snapshot: snapshot,
                jpegDataBySnapshotID: jpegDataBySnapshotID
            )
            guard let snapshotURL = urls.first(where: { $0.lastPathComponent == "snapshot.json" }) else { return }
            let activity = UIActivityViewController(activityItems: [snapshotURL], applicationActivities: nil)
            if let popover = activity.popoverPresentationController {
                popover.barButtonItem = navigationItem.leftBarButtonItems?.last
            }
            present(activity, animated: true)
        } catch {
            presentError(title: "Could Not Export", message: error.localizedDescription)
        }
    }

    private func copyDefinition(for identifier: String) {
        guard let definition = definitionByID[identifier] else { return }
        let readable = [
            definition.identity.canonicalName,
            "Display: \(definition.identity.displayName)",
            "Symbol: \(definition.codeLocator.symbol)",
            "Func: \(definition.codeLocator.function)",
            "File: \(definition.codeLocator.file)"
        ].joined(separator: "\n")
        let alert = UIAlertController(title: "Copy Definition Context", message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Readable Context", style: .default) { _ in
            UIPasteboard.general.string = readable
            UIAccessibility.post(notification: .announcement, argument: "Readable definition context copied")
        })
        alert.addAction(UIAlertAction(title: "Structured JSON", style: .default) { [weak self] _ in
            guard let self else { return }
            do {
                let context = AgentContextBuilder.make(for: definition, definitions: self.definitions)
                UIPasteboard.general.string = String(decoding: try JSONCodec.encode(context), as: UTF8.self)
                UIAccessibility.post(notification: .announcement, argument: "Structured definition context copied")
            } catch {
                self.presentError(title: "Could Not Copy JSON", message: error.localizedDescription)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        }
        present(alert, animated: true)
    }

    private func sendToAgent(for identifier: String) {
        guard let definition = definitionByID[identifier], let project else { return }
        do {
            let context = AgentContextBuilder.make(for: definition, definitions: definitions)
            let payload = AgentContextExchangeFile(
                schemaVersion: SchemaVersion.current,
                projectID: project.id,
                revision: try store.repository.currentRevision(in: project.id),
                agentContext: context
            )
            let data = try JSONCodec.encode(payload)
            let activity = UIActivityViewController(
                activityItems: [String(decoding: data, as: UTF8.self)],
                applicationActivities: nil
            )
            if let popover = activity.popoverPresentationController {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            }
            present(activity, animated: true)
        } catch {
            presentError(title: "Could Not Prepare Agent Context", message: error.localizedDescription)
        }
    }

    private func presentError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    private func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static func clusterItemID(for clusterID: String) -> String {
        "cluster-item:\(clusterID)"
    }

    private static func clusterID(from itemID: String) -> String? {
        let prefix = "cluster-item:"
        guard itemID.hasPrefix(prefix) else { return nil }
        return String(itemID.dropFirst(prefix.count))
    }

    private static func definitionID(from itemID: String) -> String? {
        clusterID(from: itemID) == nil ? itemID : nil
    }
}

extension DictionaryViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let identifier = dataSource.itemIdentifier(for: indexPath) else { return }
        collectionView.deselectItem(at: indexPath, animated: true)
        if let clusterID = Self.clusterID(from: identifier) {
            toggleCluster(clusterID)
        } else if let definitionID = Self.definitionID(from: identifier) {
            selectedDefinitionID = definitionID
            toggleExpanded(for: definitionID)
        }
    }
}

extension DictionaryViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first, let project else { return }
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            try DictionarySchemaValidator.validateJSONData(data)
            let delta = try JSONCodec.decode(DictionaryDelta.self, from: data)
            try DictionarySchemaValidator.validate(delta: delta)
            let result = try store.repository.apply(delta: delta, in: project.id)
            reload()
            let message = result.alreadyApplied
                ? "This Delta was already imported."
                : "Imported revision \(result.newRevision)."
            let alert = UIAlertController(title: "Import Complete", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        } catch {
            presentError(title: "Could Not Import Delta", message: error.localizedDescription)
        }
    }
}

@MainActor
private final class ClusterHeaderCell: UICollectionViewCell {
    static let reuseIdentifier = "cluster-header-cell"

    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let disclosureImageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .tertiarySystemGroupedBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous
        contentView.layer.masksToBounds = true
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 0
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0
        disclosureImageView.tintColor = .secondaryLabel
        disclosureImageView.setContentHuggingPriority(.required, for: .horizontal)

        let labels = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 2
        let stack = UIStackView(arrangedSubviews: [labels, disclosureImageView])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(cluster: Cluster, collapsed: Bool) {
        titleLabel.text = cluster.name
        let primaryName = cluster.definitionIDs.contains(cluster.primaryDefinitionID)
            ? "Primary: \(cluster.primaryDefinitionID)"
            : "Primary unavailable"
        detailLabel.text = "\(cluster.definitionIDs.count) definitions · \(primaryName)"
        disclosureImageView.image = UIImage(systemName: collapsed ? "chevron.right" : "chevron.down")
        accessibilityIdentifier = "cluster-\(cluster.id)"
        accessibilityLabel = "\(cluster.name), \(cluster.definitionIDs.count) definitions"
        accessibilityValue = collapsed ? "Collapsed" : "Expanded"
        accessibilityHint = "Double tap to \(collapsed ? "expand" : "collapse") cluster"
    }
}

@MainActor
private final class DefinitionCardCell: UICollectionViewCell {
    static let reuseIdentifier = "definition-card-cell"

    private let nameLabel = UILabel()
    private let kindLabel = UILabel()
    private let summaryLabel = UILabel()
    private let detailLabel = UILabel()
    private let pinButton = UIButton(type: .system)
    private let reviewButton = UIButton(type: .system)
    private let copyButton = UIButton(type: .system)
    private let agentButton = UIButton(type: .system)
    private let actionStack = UIStackView()
    private var pinHandler: (() -> Void)?
    private var reviewHandler: (() -> Void)?
    private var copyHandler: (() -> Void)?
    private var agentHandler: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        pinHandler = nil
        reviewHandler = nil
        copyHandler = nil
        agentHandler = nil
    }

    func configure(
        definition: Definition,
        expanded: Bool,
        onTogglePin: @escaping () -> Void,
        onReview: @escaping () -> Void,
        onCopy: @escaping () -> Void,
        onSendToAgent: @escaping () -> Void
    ) {
        nameLabel.text = definition.identity.displayName
        kindLabel.text = definition.identity.kind.rawValue
        summaryLabel.text = definition.function.purpose
        detailLabel.text = detailText(for: definition)
        detailLabel.isHidden = !expanded
        actionStack.isHidden = !expanded
        let priority = definition.humanPriority?.level
        pinButton.setTitle(
            priority == .critical ? "Critical" : priority == .important ? "Pinned" : "Pin",
            for: .normal
        )
        pinButton.accessibilityLabel = priority == .critical
            ? "Unpin critical definition"
            : priority == .important
                ? "Mark definition critical"
                : "Pin definition"
        pinButton.accessibilityIdentifier = "pin-button-\(definition.id)"
        reviewButton.accessibilityIdentifier = "review-button-\(definition.id)"
        copyButton.accessibilityIdentifier = "copy-button-\(definition.id)"
        agentButton.accessibilityIdentifier = "send-to-agent-button-\(definition.id)"
        accessibilityIdentifier = "definition-card-\(definition.id)"
        let lifecycle = definition.lifecycle?.state.rawValue ?? "Lifecycle not evaluated"
        let priorityLabel = definition.humanPriority?.level.rawValue ?? "not pinned"
        let heat = definition.changeHeat.map { "Change Heat \(Int($0.percentile * 100)) percentile" }
            ?? "Change Heat not evaluated"
        accessibilityLabel = "\(definition.identity.displayName), \(definition.identity.kind.rawValue). \(definition.function.purpose). \(lifecycle). \(priorityLabel). \(heat)."
        accessibilityHint = expanded ? "Double tap to collapse details" : "Double tap to expand details"
        pinHandler = onTogglePin
        reviewHandler = onReview
        copyHandler = onCopy
        agentHandler = onSendToAgent
    }

    private func setup() {
        backgroundColor = .clear
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 14
        contentView.layer.cornerCurve = .continuous
        contentView.layer.masksToBounds = true
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 14, trailing: 16)

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.numberOfLines = 0

        kindLabel.font = .preferredFont(forTextStyle: .caption1)
        kindLabel.adjustsFontForContentSizeCategory = true
        kindLabel.textColor = .secondaryLabel
        kindLabel.textAlignment = .right

        summaryLabel.font = .preferredFont(forTextStyle: .subheadline)
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.textColor = .secondaryLabel
        summaryLabel.numberOfLines = 0

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 0

        let titleStack = UIStackView(arrangedSubviews: [nameLabel, kindLabel])
        titleStack.axis = .horizontal
        titleStack.alignment = .firstBaseline
        titleStack.spacing = 12
        nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        kindLabel.setContentHuggingPriority(.required, for: .horizontal)

        pinButton.setTitle("Pin", for: .normal)
        pinButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        pinButton.addAction(UIAction { [weak self] _ in self?.pinHandler?() }, for: .primaryActionTriggered)
        reviewButton.setTitle("Review", for: .normal)
        reviewButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        reviewButton.accessibilityLabel = "Review definition"
        reviewButton.addAction(UIAction { [weak self] _ in self?.reviewHandler?() }, for: .primaryActionTriggered)
        copyButton.setTitle("Copy", for: .normal)
        copyButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        copyButton.accessibilityLabel = "Copy definition context"
        copyButton.addAction(UIAction { [weak self] _ in self?.copyHandler?() }, for: .primaryActionTriggered)
        agentButton.setTitle("Send to Agent", for: .normal)
        agentButton.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
        agentButton.accessibilityLabel = "Send definition context to Agent"
        agentButton.addAction(UIAction { [weak self] _ in self?.agentHandler?() }, for: .primaryActionTriggered)
        for button in [pinButton, reviewButton, copyButton, agentButton] {
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        actionStack.axis = .vertical
        actionStack.alignment = .leading
        actionStack.spacing = 12
        actionStack.addArrangedSubview(pinButton)
        actionStack.addArrangedSubview(reviewButton)
        actionStack.addArrangedSubview(copyButton)
        actionStack.addArrangedSubview(agentButton)

        let stack = UIStackView(arrangedSubviews: [titleStack, summaryLabel, detailLabel, actionStack])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor)
        ])
    }

    private func detailText(for definition: Definition) -> String {
        let symbol = definition.codeLocator.symbol.isEmpty ? definition.codeLocator.function : definition.codeLocator.symbol
        let file = definition.codeLocator.file.isEmpty ? "No file locator" : definition.codeLocator.file
        let lifecycle = definition.lifecycle?.state.rawValue ?? "Not evaluated"
        let heat = definition.changeHeat.map {
            let score = String(format: "%.2f", $0.score)
            return "\(Int($0.percentile * 100)) percentile · score \(score)"
        } ?? "Not evaluated"
        let priority = definition.humanPriority?.level.rawValue.capitalized ?? "Not pinned"
        let functionalLocator = [
            definition.functionalLocator.domain,
            definition.functionalLocator.role,
            definition.functionalLocator.trigger
        ].filter { !$0.isEmpty }.joined(separator: " · ")
        let visualLocator = [
            definition.visualLocator.screen,
            definition.visualLocator.container,
            definition.visualLocator.region
        ].filter { !$0.isEmpty }.joined(separator: " · ")
        let history = definition.implementationHistory.isEmpty
            ? "None"
            : "\(definition.implementationHistory.count) events"
        return [
            "Canonical: \(definition.identity.canonicalName)",
            "Purpose: \(definition.function.purpose)",
            "Code: \(symbol)",
            "Func: \(definition.codeLocator.function)",
            "File: \(file)",
            "Visual: \(visualLocator.isEmpty ? "None" : visualLocator)",
            "Functional: \(functionalLocator.isEmpty ? "None" : functionalLocator)",
            "Terms: \(definition.fuzzyTerms.map(\.text).joined(separator: ", "))",
            "Relations: \(definition.relations.count)",
            "Lifecycle: \(lifecycle)",
            "Change Heat: \(heat)",
            "Priority: \(priority)",
            "History: \(history)",
            "Snapshots: \(definition.snapshots.count)"
        ].joined(separator: "\n")
    }
}
