import UIKit

@MainActor
final class SettingsViewController: UIViewController {
    private let store: AppStore

    init(store: AppStore) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        view.backgroundColor = .systemGroupedBackground

        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.isScrollEnabled = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.accessibilityIdentifier = "settings-table"
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

extension SettingsViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int { 3 }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 1 ? 2 : 1
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Project", "Appearance", "About"][section]
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        switch (indexPath.section, indexPath.row) {
        case (0, 0):
            content.text = "Current Project"
            content.secondaryText = "None"
        case (1, 0):
            content.text = "Appearance"
            content.secondaryText = "System"
        case (1, 1):
            content.text = "Cloud Sync"
            content.secondaryText = store.syncCoordinator.statusSummary
        default:
            content.text = "Version"
            content.secondaryText = "MVP"
        }
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "settings-row-\(indexPath.section)-\(indexPath.row)"
        return cell
    }
}

extension SettingsViewController: UITableViewDelegate {}
