import UIKit

@MainActor
final class SearchViewController: UIViewController {
    private let store: AppStore
    private let project: Project?
    private var allDefinitions: [Definition] = []
    private var allClusters: [Cluster] = []
    private var results: [DefinitionSearchResult] = []
    private var clusterResults: [ClusterSearchResult] = []
    private var searchResponse = SearchResponse(query: "", direct: nil, candidates: [], related: [])
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let messageLabel = UILabel()

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
        title = "Search"
        view.backgroundColor = .systemGroupedBackground

        let searchController = UISearchController(searchResultsController: nil)
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search definitions"
        searchController.searchBar.accessibilityIdentifier = "dictionary-search-field"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "search-result-cell")
        tableView.accessibilityIdentifier = "search-results-table"
        tableView.isHidden = true
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.text = "Type a term, symbol, screen, or function to search."
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(messageLabel)
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            messageLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        allDefinitions = loadDefinitions()
        allClusters = loadClusters()
    }

    private func loadDefinitions() -> [Definition] {
        do {
            if let project {
                return try store.repository.definitions(in: project.id)
            } else {
                return try store.repository.projects(includeArchived: false).flatMap {
                    try store.repository.definitions(in: $0.id)
                }
            }
        } catch {
            return []
        }
    }

    private func loadClusters() -> [Cluster] {
        do {
            if let project {
                return try store.repository.clusters(in: project.id)
                    .filter { $0.status == .approved || $0.status == .adjusted }
            }
            return try store.repository.projects(includeArchived: false).flatMap {
                try store.repository.clusters(in: $0.id)
                    .filter { $0.status == .approved || $0.status == .adjusted }
            }
        } catch {
            return []
        }
    }
}

extension SearchViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let query = searchController.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        allDefinitions = loadDefinitions()
        allClusters = loadClusters()
        guard !SearchNormalizer.normalize(query).isEmpty else {
            results = []
            clusterResults = []
            messageLabel.text = "Type a term, symbol, screen, or function to search."
            messageLabel.isHidden = false
            tableView.isHidden = true
            return
        }

        searchResponse = makeSearchResponse(query: query)
        var combined: [DefinitionSearchResult] = []
        if let direct = searchResponse.direct { combined.append(direct) }
        combined.append(contentsOf: searchResponse.candidates)
        combined.append(contentsOf: searchResponse.related)
        var seen: Set<String> = []
        results = combined.filter { seen.insert($0.definitionID).inserted }
        clusterResults = searchResponse.clusters
        tableView.reloadData()
        let hasResults = !results.isEmpty || !clusterResults.isEmpty
        tableView.isHidden = !hasResults
        messageLabel.isHidden = hasResults
        if !hasResults {
            messageLabel.text = "No matching definitions yet."
        } else if let direct = searchResponse.direct {
            messageLabel.text = "Direct match · \(Int(direct.score * 100))% confidence"
        } else {
            messageLabel.text = "\(searchResponse.candidates.count) candidates · \(searchResponse.related.count) related"
        }
    }

    private func makeSearchResponse(query: String) -> SearchResponse {
        let engine = SearchEngine()
        if let project {
            return engine.search(
                query: query,
                projectID: project.id,
                definitions: allDefinitions,
                clusters: allClusters
            )
        }

        // Global search is intentionally a fan-out over isolated project
        // scopes. It never hands a mixed-project array to the scoring engine,
        // and therefore cannot use one project's vocabulary as another's
        // relation/context evidence.
        let projectIDs = Set(allDefinitions.map(\.projectID)).sorted()
        let responses = projectIDs.compactMap { projectID -> SearchResponse? in
            let definitions = allDefinitions.filter { $0.projectID == projectID }
            let clusters = allClusters.filter { $0.projectID == projectID }
            guard !definitions.isEmpty else { return nil }
            return engine.search(query: query, projectID: projectID, definitions: definitions, clusters: clusters)
        }

        let directResults = responses.compactMap(\.direct)
        let direct = directResults.count == 1 ? directResults.first : nil
        let directIDs = Set(directResults.map(\.definitionID))
        let candidates = uniqueResults(
            responses.flatMap { response in
                (response.direct.map { [$0] } ?? []) + response.candidates
            },
            excluding: directIDs
        )
        let related = uniqueResults(
            responses.flatMap(\.related),
            excluding: directIDs.union(Set(candidates.map(\.definitionID)))
        )
        let clusters = responses.flatMap(\.clusters)
        return SearchResponse(query: query, direct: direct, candidates: candidates, related: related, clusters: clusters)
    }

    private func uniqueResults(
        _ values: [DefinitionSearchResult],
        excluding excludedIDs: Set<String>
    ) -> [DefinitionSearchResult] {
        var seen = excludedIDs
        return values.filter { seen.insert($0.definitionID).inserted }
    }
}

extension SearchViewController: UITableViewDataSource {
    func numberOfSections(in tableView: UITableView) -> Int {
        clusterResults.isEmpty ? 1 : 2
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        clusterResults.isEmpty ? nil : (section == 0 ? "Definition Clusters" : "Definitions")
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        clusterResults.isEmpty || section == 1 ? results.count : clusterResults.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "search-result-cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        if !clusterResults.isEmpty && indexPath.section == 0 {
            let cluster = clusterResults[indexPath.row]
            content.text = cluster.name
            content.secondaryText = "Cluster · Primary \(cluster.primaryDefinitionID) · \(Int(cluster.score * 100))%"
            content.image = UIImage(systemName: "square.stack.3d.up")
            cell.accessibilityIdentifier = "search-cluster-result-\(cluster.clusterID)"
            cell.accessibilityLabel = "\(cluster.name), definition cluster"
        } else {
            let result = results[indexPath.row]
            content.text = result.displayName
            let reason = result.reasons.first.map {
                "\($0.field.rawValue) · \($0.kind.rawValue)"
            } ?? "Related definition"
            content.secondaryText = "\(reason) · \(Int(result.score * 100))%"
            content.image = UIImage(systemName: "magnifyingglass")
            cell.accessibilityIdentifier = "search-result-\(result.definitionID)"
        }
        cell.contentConfiguration = content
        return cell
    }
}

extension SearchViewController: UITableViewDelegate {
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if !clusterResults.isEmpty && indexPath.section == 0 {
            let cluster = clusterResults[indexPath.row]
            let alert = UIAlertController(
                title: cluster.name,
                message: "Definition cluster\nPrimary definition: \(cluster.primaryDefinitionID)\nMatch: \(cluster.reasons.first?.evidence ?? "related")",
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        let result = results[indexPath.row]
        let reasons = result.reasons
            .map { "\($0.field.rawValue): \($0.evidence)" }
            .joined(separator: "\n")
        let alert = UIAlertController(
            title: result.displayName,
            message: "Current symbol: \(result.currentSymbol)\nCurrent function: \(result.currentFunction)\n\n\(reasons)",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
