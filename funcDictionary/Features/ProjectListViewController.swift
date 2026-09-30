import UIKit


@MainActor
final class ProjectListViewController: UIViewController {
    private let store: AppStore
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var projects: [Project] = []
    private var emptyState: EmptyStateView?
    var onProjectSelected: ((Project) -> Void)?

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
        title = "Projects"
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .always
        navigationController?.navigationBar.prefersLargeTitles = true

        let settingsButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"),
            style: .plain,
            target: self,
            action: #selector(openSettings)
        )
        settingsButton.accessibilityLabel = "Settings"
        settingsButton.accessibilityIdentifier = "settings-button"
        let addButton = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(createProject)
        )
        addButton.accessibilityLabel = "Create Project"
        addButton.accessibilityIdentifier = "create-project-button"
        navigationItem.rightBarButtonItems = [settingsButton, addButton]

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.accessibilityIdentifier = "projects-table"
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "project-cell")
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        let emptyState = EmptyStateView(
            symbolName: "folder",
            title: "No Projects Yet",
            message: "Create or connect a project to start building a shared dictionary.",
            actions: [
                ("Open Dictionary", "open-dictionary-button", { [weak self] in self?.openDictionary() }),
                ("Search", "open-search-button", { [weak self] in self?.openSearch() }),
                ("Review Proposals", "open-review-button", { [weak self] in self?.openReview() })
            ]
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
            projects = try store.repository.projects(includeArchived: false)
        } catch {
            projects = []
        }
        tableView.reloadData()
        let isEmpty = projects.isEmpty
        tableView.isHidden = isEmpty
        emptyState?.isHidden = !isEmpty
    }

    @objc private func openSettings() {
        navigationController?.pushViewController(SettingsViewController(store: store), animated: true)
    }

    private func openDictionary() {
        navigationController?.pushViewController(DictionaryViewController(store: store), animated: true)
    }

    private func openSearch() {
        navigationController?.pushViewController(SearchViewController(store: store), animated: true)
    }

    private func openReview() {
        navigationController?.pushViewController(ProposalReviewViewController(store: store), animated: true)
    }

    @objc private func createProject() {
        let alert = UIAlertController(
            title: "New Project",
            message: "Give this project a name. Definitions stay inside its project boundary.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = "Project name"
            textField.accessibilityIdentifier = "project-name-field"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                self.presentError(title: "Project Name Required", message: "Enter a name before creating the project.")
                return
            }
            do {
                try self.store.repository.save(project: self.store.makeProject(name: name))
                self.reload()
            } catch {
                self.presentError(title: "Could Not Create Project", message: error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func presentError(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension ProjectListViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        projects.count
    }

    func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "project-cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let project = projects[indexPath.row]
        content.text = project.name
        content.secondaryText = "Project-scoped dictionary"
        content.image = UIImage(systemName: "folder")
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityIdentifier = "project-cell-\(project.id)"
        cell.accessibilityLabel = "\(project.name), project"
        return cell
    }
}

extension ProjectListViewController: UITableViewDelegate {
    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let project = projects[indexPath.row]
        let rename = UIContextualAction(style: .normal, title: "Rename") { [weak self] _, _, completion in
            self?.presentRename(for: project)
            completion(true)
        }
        rename.backgroundColor = .systemBlue
        rename.image = UIImage(systemName: "pencil")

        let archive = UIContextualAction(style: .destructive, title: "Archive") { [weak self] _, _, completion in
            self?.confirmArchive(project)
            completion(true)
        }
        archive.image = UIImage(systemName: "archivebox")
        let configuration = UISwipeActionsConfiguration(actions: [archive, rename])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let project = projects[indexPath.row]
        if let onProjectSelected {
            onProjectSelected(project)
        } else {
            navigationController?.pushViewController(
                DictionaryViewController(store: store, project: project),
                animated: true
            )
        }
    }

    private func presentRename(for project: Project) {
        let alert = UIAlertController(
            title: "Rename Project",
            message: "Definitions remain inside the same project boundary.",
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = project.name
            textField.accessibilityIdentifier = "rename-project-name-field"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty else {
                self.presentError(title: "Project Name Required", message: "Enter a name before saving.")
                return
            }
            var renamed = project
            renamed.name = name
            renamed.updatedAt = Date()
            do {
                try self.store.repository.save(project: renamed)
                self.reload()
            } catch {
                self.presentError(title: "Could Not Rename Project", message: error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }

    private func confirmArchive(_ project: Project) {
        let alert = UIAlertController(
            title: "Archive Project?",
            message: "The project and its definitions will leave the active list. They remain recoverable in the archived store.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Archive", style: .destructive) { [weak self] _ in
            do {
                try self?.store.repository.archive(projectID: project.id)
                self?.reload()
            } catch {
                self?.presentError(title: "Could Not Archive Project", message: error.localizedDescription)
            }
        })
        present(alert, animated: true)
    }
}