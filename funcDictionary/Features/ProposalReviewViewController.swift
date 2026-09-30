import UIKit

@MainActor
final class ProposalReviewViewController: UIViewController {
    private let store: AppStore
    private let project: Project?
    private var proposals: [Proposal] = []
    private var changeRequests: [ChangeRequest] = []
    private var emptyState: EmptyStateView?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    init(store: AppStore, project: Project? = nil) {
        self.store = store
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Review Proposals"
        view.backgroundColor = .systemGroupedBackground
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "proposal-cell")
        tableView.accessibilityIdentifier = "proposal-review-table"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let emptyState = EmptyStateView(
            symbolName: "checkmark.circle",
            title: "Nothing to Review",
            message: "Identity changes, splits, merges, and protected changes will wait here for your decision."
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

    private func reload() {
        do {
            if let project {
                proposals = try store.repository.pendingProposals(in: project.id)
                changeRequests = try store.repository.pendingChangeRequests(in: project.id)
            } else {
                proposals = try store.repository.projects(includeArchived: false).flatMap { try store.repository.pendingProposals(in: $0.id) }
                changeRequests = try store.repository.projects(includeArchived: false).flatMap { try store.repository.pendingChangeRequests(in: $0.id) }
            }
        } catch {
            proposals = []
            changeRequests = []
        }
        tableView.reloadData()
        let isEmpty = proposals.isEmpty && changeRequests.isEmpty
        tableView.isHidden = isEmpty
        emptyState?.isHidden = !isEmpty
    }
}

extension ProposalReviewViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 2 }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "Proposals" : "Protected Change Requests"
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? proposals.count : changeRequests.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "proposal-cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            let proposal = proposals[indexPath.row]
            content.text = proposal.summary
            content.secondaryText = "\(proposal.action.rawValue) · \(proposal.definitionIDs.count) definition(s)"
            content.image = UIImage(systemName: "checkmark.circle")
            cell.accessibilityIdentifier = "proposal-cell-\(proposal.id)"
        } else {
            let request = changeRequests[indexPath.row]
            content.text = request.requestedChange.summary
            content.secondaryText = "Protected change · \(request.risk)"
            content.image = UIImage(systemName: "lock.shield")
            cell.accessibilityIdentifier = "change-request-cell-\(request.id)"
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }
}

extension ProposalReviewViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            let proposal = proposals[indexPath.row]
            let alert = UIAlertController(
                title: "Review Proposal",
                message: proposal.summary,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Reject", style: .destructive) { [weak self] _ in
                self?.decide(proposal: proposal, approved: false)
            })
            alert.addAction(UIAlertAction(title: "Adjust", style: .default) { [weak self] _ in
                self?.promptAdjustment(for: proposal)
            })
            alert.addAction(UIAlertAction(title: "Approve", style: .default) { [weak self] _ in
                self?.decide(proposal: proposal, approved: true)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
        } else {
            let request = changeRequests[indexPath.row]
            let alert = UIAlertController(
                title: "Review Protected Change",
                message: "\(request.requestedChange.summary)\n\nAffected: \(request.affectedDefinitionIDs.count) definition(s)",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Reject", style: .destructive) { [weak self] _ in
                self?.decide(changeRequest: request, approved: false)
            })
            alert.addAction(UIAlertAction(title: "Approve", style: .default) { [weak self] _ in
                self?.decide(changeRequest: request, approved: true)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            present(alert, animated: true)
        }
    }

    private func decide(proposal: Proposal, approved: Bool) {
        do {
            let decision = GovernanceEngine.decide(proposal, approved: approved)
            try apply(decision)
            reload()
        } catch {
            presentError(message: error.localizedDescription)
        }
    }

    private func promptAdjustment(for proposal: Proposal) {
        let alert = UIAlertController(
            title: "Adjust Proposal",
            message: "Edit the human-readable decision before applying it.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = proposal.summary
            textField.accessibilityLabel = "Adjusted proposal summary"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Apply Adjustment", style: .default) { [weak self, weak alert] _ in
            let summary = alert?.textFields?.first?.text ?? proposal.summary
            do {
                try self?.apply(GovernanceEngine.adjust(proposal, summary: summary))
                self?.reload()
            } catch {
                self?.presentError(message: error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func apply(_ proposal: Proposal) throws {
        // Persist the human decision first so repository write policy can see
        // the approved governance record before applying its data changes.
        try store.repository.save(proposal: proposal, in: proposal.projectID)
        if proposal.status == .approved || proposal.status == .adjusted {
            let definitions = try store.repository.definitions(in: proposal.projectID)
            let application = try GovernanceEngine.applyApproved(proposal, to: definitions)
            for definition in application.updatedDefinitions {
                try store.repository.save(definition: definition, in: proposal.projectID)
            }
            if let cluster = application.cluster {
                try store.repository.save(cluster: cluster, in: proposal.projectID)
            }
        }
    }

    private func decide(changeRequest: ChangeRequest, approved: Bool) {
        do {
            try store.repository.save(
                changeRequest: GovernanceEngine.decide(changeRequest, approved: approved),
                in: changeRequest.projectID
            )
            reload()
        } catch {
            presentError(message: error.localizedDescription)
        }
    }

    private func presentError(message: String) {
        let alert = UIAlertController(title: "Could Not Save Review", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
