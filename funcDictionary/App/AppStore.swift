import Foundation

@MainActor
final class AppStore {
    let repository: ProjectScopedRepository
    let persistence: PersistenceController?
    let snapshotAssets: SnapshotAssetStore?
    let isUsingFallbackStorage: Bool
    let syncCoordinator: CloudSyncCoordinator

    private init(
        persistence: PersistenceController?,
        seedDemoData: Bool,
        startSync: Bool
    ) {
        if let persistence {
            self.persistence = persistence
            self.repository = CoreDataProjectRepository(persistence: persistence)
            self.snapshotAssets = SnapshotAssetStore(persistence: persistence)
            self.isUsingFallbackStorage = false
        } else {
            self.persistence = nil
            self.repository = InMemoryProjectRepository()
            self.snapshotAssets = nil
            self.isUsingFallbackStorage = true
        }
        self.syncCoordinator = CloudSyncCoordinator(
            persistence: persistence,
            configuration: .fromInfoDictionary()
        )
        if startSync {
            self.syncCoordinator.start()
        }

        if seedDemoData {
            SeedData.populateIfNeeded(repository: repository)
        }
    }

    convenience init() {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        let mode: PersistenceMode
        if isUITesting {
            mode = .inMemory
        } else {
            let directory = Self.applicationSupportDirectory()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            mode = .local(directory: directory)
        }

        self.init(
            persistence: try? PersistenceController(mode: mode),
            seedDemoData: {
#if os(macOS)
                false
#else
                ProcessInfo.processInfo.arguments.contains("--demo-data")
#endif
            }(),
            startSync: {
#if os(macOS)
                false
#else
                true
#endif
            }()
        )
    }

#if os(macOS)
    /// Completes macOS bootstrap after persistent-store I/O has yielded off
    /// the main actor. A failed local store falls back to an explicit in-memory
    /// repository so the shell remains inspectable and Settings can disclose
    /// the degraded mode.
    static func makeLoaded() async -> AppStore {
        let initialStore = AppStore()
        if let persistence = initialStore.persistence {
            do {
                try await persistence.loadPersistentStores()
                initialStore.syncCoordinator.start()
                if ProcessInfo.processInfo.arguments.contains("--demo-data") {
                    SeedData.populateIfNeeded(repository: initialStore.repository)
                }
                return initialStore
            } catch {
                return AppStore(
                    persistence: nil,
                    seedDemoData: ProcessInfo.processInfo.arguments.contains("--demo-data"),
                    startSync: true
                )
            }
        }
        return initialStore
    }
#endif

    func makeProject(name: String) -> Project {
        Project(id: "project_\(UUID().uuidString.lowercased())", name: name)
    }

    private static func applicationSupportDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("funcDictionary", isDirectory: true)
    }
}

enum SeedData {
    @MainActor
    static func populateIfNeeded(repository: ProjectScopedRepository) {
        do {
            guard try repository.projects(includeArchived: false).isEmpty else { return }
            let project = Project(id: "project_demo", name: "Demo Product")
            try repository.save(project: project)
            let definitions = [
                Definition(
                    id: "def_project_list",
                    projectID: project.id,
                    identity: DefinitionIdentity(canonicalName: "ProjectListViewController", displayName: "Project List", kind: .screen),
                    function: FunctionDescriptor(domain: "Navigation", purpose: "选择一个项目，进入该项目的函数词典"),
                    codeLocator: CodeLocator(symbol: "ProjectListViewController", function: "tableView(_:didSelectRowAt:)", file: "ProjectListViewController.swift"),
                    visualLocator: VisualLocator(screen: "Projects", container: "Navigation stack", region: "Main list"),
                    functionalLocator: FunctionalLocator(domain: "Project selection", role: "Entry point", trigger: "Tap a project"),
                    fuzzyTerms: [FuzzyTerm(text: "项目列表", source: .user), FuzzyTerm(text: "project picker", source: .humanAdded)]
                ),
                Definition(
                    id: "def_dictionary_card",
                    projectID: project.id,
                    identity: DefinitionIdentity(canonicalName: "DefinitionCardCell", displayName: "Definition Card", kind: .component),
                    function: FunctionDescriptor(domain: "Dictionary", purpose: "展示一个功能定义及其当前定位信息"),
                    codeLocator: CodeLocator(symbol: "DefinitionCardCell", function: "configure(definition:expanded:)", file: "DictionaryViewController.swift"),
                    visualLocator: VisualLocator(screen: "Dictionary", container: "Collection view", region: "Definition card"),
                    functionalLocator: FunctionalLocator(domain: "Definition browsing", role: "Expandable card", trigger: "Tap the card"),
                    fuzzyTerms: [FuzzyTerm(text: "卡片", source: .user), FuzzyTerm(text: "expandable definition", source: .aiGenerated)]
                ),
                Definition(
                    id: "def_search",
                    projectID: project.id,
                    identity: DefinitionIdentity(canonicalName: "SearchViewController", displayName: "Dictionary Search", kind: .screen),
                    function: FunctionDescriptor(domain: "Discovery", purpose: "根据人类表达和机器词汇找到相关功能定义"),
                    codeLocator: CodeLocator(symbol: "SearchViewController", function: "updateSearchResults(for:)", file: "SearchViewController.swift"),
                    visualLocator: VisualLocator(screen: "Search", container: "Navigation bar", region: "Search field"),
                    functionalLocator: FunctionalLocator(domain: "Discovery", role: "Global search", trigger: "Enter a query"),
                    fuzzyTerms: [FuzzyTerm(text: "查找", source: .user), FuzzyTerm(text: "lookup", source: .humanAdded)]
                ),
                Definition(
                    id: "def_proposal_review",
                    projectID: project.id,
                    identity: DefinitionIdentity(canonicalName: "ProposalReviewViewController", displayName: "Proposal Review", kind: .screen),
                    function: FunctionDescriptor(domain: "Governance", purpose: "审查身份变化和受保护的结构性修改"),
                    codeLocator: CodeLocator(symbol: "ProposalReviewViewController", function: "tableView(_:didSelectRowAt:)", file: "ProposalReviewViewController.swift"),
                    visualLocator: VisualLocator(screen: "Review Proposals", container: "Grouped list", region: "Proposal rows"),
                    functionalLocator: FunctionalLocator(domain: "Governance", role: "Human approval", trigger: "Open Review"),
                    humanPriority: HumanPriority(level: .important, label: "Review surface", note: "Identity changes require a human decision.")
                )
            ]
            for definition in definitions {
                try repository.save(definition: definition, in: project.id)
            }
        } catch {
            // The shell remains usable if demo data is unavailable; the store
            // exposes its fallback state for Settings and diagnostics.
        }
    }
}
