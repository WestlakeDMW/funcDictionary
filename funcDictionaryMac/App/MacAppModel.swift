import AppKit
import Combine
import Foundation

enum MacSidebarSelection: Hashable {
    case projects
    case project(String)
}

enum MacAppError: Error, LocalizedError {
    case noProject
    case noWorkspace
    case noDefinition
    case harnessNotReady(String)
    case snapshotStorageUnavailable
    case invalidSnapshotImage

    var errorDescription: String? {
        switch self {
        case .noProject: "请先选择一个项目。"
        case .noWorkspace: "请先为当前项目选择工作区文件夹。"
        case .noDefinition: "当前项目还没有可导出的 Definition。"
        case .harnessNotReady(let harness): "\(harness) 尚未配置可执行文件或参数模板无法解析。"
        case .snapshotStorageUnavailable: "当前存储没有可用的 Snapshot 二进制仓储，请先完成本地 Core Data 存储初始化。"
        case .invalidSnapshotImage: "所选文件不是可读取的图像。"
        }
    }
}

struct PendingHarnessSend: Identifiable {
    let id = UUID()
    let harness: HarnessID
    let projectName: String
    let workspaceURL: URL
    let contextURL: URL
    let prompt: String
    let launchRequest: HarnessLaunchRequest

    var command: String { launchRequest.command }
}

@MainActor
final class MacAppModel: ObservableObject {
    let store: AppStore
    let harnessCenter: HarnessCenterModel

    @Published private(set) var projects: [Project] = []
    @Published private(set) var definitions: [Definition] = []
    @Published private(set) var proposals: [Proposal] = []
    @Published private(set) var changeRequests: [ChangeRequest] = []
    @Published private(set) var conflicts: [ConflictRecord] = []
    @Published private(set) var currentRevision = 0
    @Published var sidebarSelection: MacSidebarSelection = .projects
    @Published var selectedProjectID: String?
    @Published var selectedDefinitionID: String?
    @Published var searchQuery = ""
    @Published var agentPrompt = AgentWorkspace.indexingPrompt
    @Published var isShowingNewProjectSheet = false
    @Published var isShowingRenameProjectSheet = false
    @Published var renameProjectDraft = ""
    @Published var errorMessage: String?
    @Published private(set) var statusMessage: String?
    @Published var pendingHarnessSend: PendingHarnessSend?
    @Published private(set) var syncEvents: [DeltaSyncEvent] = []
    @Published private(set) var lastUpdateDates: [String: Date] = [:]
    @Published private(set) var showsPropertyNotes = true
    @Published private(set) var isGlobalSearchHotKeyEnabled = true

    static let globalSearchHotKeyEnabledKey = "funcDictionary.mac.globalSearchHotKeyEnabled"

    private let defaults: UserDefaults
    private let workspacePathsKey = "funcDictionary.mac.workspacePaths"
    private let selectedProjectKey = "funcDictionary.mac.selectedProjectID"
    private let lastUpdateDatesKey = "funcDictionary.mac.lastUpdateDates"
    private let propertyNotesKey = "funcDictionary.mac.propertyNotes"
    private let isUITesting: Bool
    private var workspacePaths: [String: String]
    private let searchEngine = SearchEngine()
    private var deltaWatchers: [String: DeltaDirectoryWatcher] = [:]

    init(store: AppStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.harnessCenter = HarnessCenterModel(defaults: defaults)
        self.defaults = defaults
        self.isUITesting = ProcessInfo.processInfo.arguments.contains("--ui-testing")
        self.workspacePaths = isUITesting
            ? [:]
            : (defaults.dictionary(forKey: workspacePathsKey) as? [String: String] ?? [:])
        self.lastUpdateDates = defaults.dictionary(forKey: lastUpdateDatesKey) as? [String: Date] ?? [:]
        self.selectedProjectID = defaults.string(forKey: selectedProjectKey)
        reloadProjects()
        showsPropertyNotes = defaults.object(forKey: propertyNotesKey) as? Bool ?? true
        isGlobalSearchHotKeyEnabled = defaults.object(forKey: Self.globalSearchHotKeyEnabledKey) as? Bool ?? true
    }

    func setShowsPropertyNotes(_ enabled: Bool) {
        showsPropertyNotes = enabled
        defaults.set(enabled, forKey: propertyNotesKey)
    }

    func setGlobalSearchHotKeyEnabled(_ enabled: Bool) {
        guard enabled != isGlobalSearchHotKeyEnabled else { return }
        isGlobalSearchHotKeyEnabled = enabled
        defaults.set(enabled, forKey: Self.globalSearchHotKeyEnabledKey)
    }

    /// 从全局检索面板跳转：切换项目、选中词条，并把主窗口带回前台。
    func openDefinitionInMainWindow(projectID: String, definitionID: String) {
        selectProject(projectID)
        selectedDefinitionID = definitionID
        NSApp.activate(ignoringOtherApps: true)
        let mainWindow = NSApp.windows.first { window in
            window.isVisible && !(window is NSPanel) && window.title != "设置"
        } ?? NSApp.windows.first { !($0 is NSPanel) }
        mainWindow?.makeKeyAndOrderFront(nil)
    }

    var activeProject: Project? {
        guard let selectedProjectID else { return nil }
        return projects.first { $0.id == selectedProjectID }
    }

    var activeWorkspaceURL: URL? {
        activeProject.map { workspaceURL(for: $0) }
    }

    func definitionCount(for projectID: String) -> Int {
        if projectID == selectedProjectID { return definitions.count }
        return (try? store.repository.definitions(in: projectID).count) ?? 0
    }

    var filteredDefinitions: [Definition] {
        let base = definitions
        guard let projectID = selectedProjectID else { return base }
        guard !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }

        let response = searchEngine.search(
            query: searchQuery,
            projectID: projectID,
            definitions: base
        )
        let orderedIDs = ([response.direct] + response.candidates + response.related)
            .compactMap { $0?.definitionID }
        var seen = Set<String>()
        return orderedIDs.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return base.first { $0.id == id }
        }
    }

    var selectedDefinition: Definition? {
        guard let selectedDefinitionID else { return filteredDefinitions.first }
        return definitions.first { $0.id == selectedDefinitionID } ?? filteredDefinitions.first
    }

    func project(withID id: String) -> Project? {
        projects.first { $0.id == id }
    }

    func reloadProjects() {
        do {
            projects = try store.repository.projects(includeArchived: false)
        } catch {
            projects = []
            present(error)
        }
        NotificationCenter.default.post(name: .funcDictionaryStoreDidChange, object: nil)

        guard let selectedProjectID,
              projects.contains(where: { $0.id == selectedProjectID }) else {
            setSelectedProject(nil)
            definitions = []
            proposals = []
            changeRequests = []
            conflicts = []
            currentRevision = 0
            syncWatcherLifecycles()
            return
        }
        reloadProjectData()
        syncWatcherLifecycles()
    }

    func selectProject(_ projectID: String) {
        guard projects.contains(where: { $0.id == projectID }) else { return }
        let didChange = selectedProjectID != projectID
        setSelectedProject(projectID)
        sidebarSelection = .project(projectID)
        if didChange {
            selectedDefinitionID = nil
            searchQuery = ""
        }
        reloadProjectData()
    }

    func handleSidebarSelection(_ selection: MacSidebarSelection) {
        switch selection {
        case .project(let projectID):
            selectProject(projectID)
        case .projects:
            break
        }
    }

    func createProject(named name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            present("项目名称不能为空。")
            return
        }
        do {
            let project = store.makeProject(name: trimmedName)
            try store.repository.save(project: project)
            reloadProjects()
            setSelectedProject(project.id)
            sidebarSelection = .project(project.id)
            reloadProjectData()
            statusMessage = "已创建项目“\(project.name)”"
        } catch {
            present(error)
        }
    }

    func archiveProject(_ project: Project) {
        do {
            try store.repository.archive(projectID: project.id)
            if selectedProjectID == project.id {
                setSelectedProject(nil)
                sidebarSelection = .projects
                definitions = []
            }
            reloadProjects()
            statusMessage = "已归档项目“\(project.name)”"
        } catch {
            present(error)
        }
    }

    func beginRenamingActiveProject() {
        guard let project = activeProject else {
            present(MacAppError.noProject)
            return
        }
        renameProjectDraft = project.name
        isShowingRenameProjectSheet = true
    }

    func renameActiveProject(to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            present("项目名称不能为空。")
            return
        }
        guard var project = activeProject else {
            present(MacAppError.noProject)
            return
        }
        project.name = trimmedName
        project.updatedAt = Date()
        do {
            try store.repository.save(project: project)
            reloadProjects()
            setSelectedProject(project.id)
            sidebarSelection = .project(project.id)
            statusMessage = "项目已重命名为“\(trimmedName)”"
        } catch {
            present(error)
        }
    }

    func setWorkspaceURL(_ url: URL) {
        guard let projectID = selectedProjectID else {
            present(MacAppError.noProject)
            return
        }
        do {
            let root = url.standardizedFileURL.resolvingSymlinksInPath()
            try AgentWorkspace.validate(root: root, projectID: projectID)
            workspacePaths[projectID] = root.path
            defaults.set(workspacePaths, forKey: workspacePathsKey)
            _ = try exportAgentContext()
        syncWatcherLifecycles()
        statusMessage = "仓库已关联，Agent 接入包已准备：\(root.path)"
        } catch { present(error) }
    }

    func handleLink(_ url: URL) {
        do {
            let root = try AgentWorkspace.root(from: url)
            let manifest = root.appendingPathComponent(".funcdictionary/project.json")
            let project: Project
            if FileManager.default.fileExists(atPath: manifest.path) {
                let linked = try JSONCodec.decode(Project.self, from: Data(contentsOf: manifest))
                guard IdentifierValidator.isValid(linked.id, prefix: "project_"),
                      linked.schemaVersion == SchemaVersion.current, !linked.archived else {
                    throw ExchangeValidationError.invalidRevision
                }
                // An exported manifest alone cannot restore a database. Avoid
                // overwriting another installation's dictionary with an empty one.
                guard let existing = projects.first(where: { $0.id == linked.id }) else {
                    throw ExchangeValidationError.projectMismatch("该词典来自其他安装，请先迁移词典数据，再关联仓库。")
                }
                if let boundPath = workspacePaths[existing.id], boundPath != root.path,
                   FileManager.default.fileExists(atPath: boundPath) {
                    throw ExchangeValidationError.projectMismatch("该项目仍关联另一目录，请在 App 中明确更改工作区。")
                }
                project = existing
            } else if let existing = projects.first(where: { workspacePaths[$0.id] == root.path }) {
                project = existing
            } else {
                project = store.makeProject(name: root.lastPathComponent)
                try store.repository.save(project: project)
                reloadProjects()
            }
            selectProject(project.id)
            setWorkspaceURL(root)
        } catch { present(error) }
    }

    func workspaceURL(for project: Project) -> URL {
        if let path = workspacePaths[project.id], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("funcDictionary", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
            .appendingPathComponent(project.id, isDirectory: true)
    }

    func linkedWorkspaceName(for project: Project) -> String? {
        guard let path = workspacePaths[project.id], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).lastPathComponent
    }

    @discardableResult
    func exportAgentContext() throws -> URL {
        guard let project = activeProject else { throw MacAppError.noProject }
        return try exportAgentContext(for: project.id, definitionID: selectedDefinition?.id)
    }

    @discardableResult
    private func exportAgentContext(for projectID: String, definitionID: String? = nil) throws -> URL {
        guard let project = project(withID: projectID), workspacePaths[projectID] != nil else {
            throw MacAppError.noWorkspace
        }
        let projectDefinitions = try store.repository.definitions(in: project.id)
        let definition = definitionID.flatMap { id in projectDefinitions.first { $0.id == id } }
            ?? projectDefinitions.first
        let context: AgentContext
        if let definition {
            context = AgentContextBuilder.make(for: definition, definitions: projectDefinitions)
        } else {
            context = .empty
        }
        let revision = try store.repository.currentRevision(in: project.id)
        let workspaceURL = workspaceURL(for: project)
        let exchangeStore = FileExchangeStore(directory: ExchangeDirectory(projectRootURL: workspaceURL))
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let snapshot = ProjectSnapshot(project: project, definitions: projectDefinitions,
                                       clusters: try store.repository.clusters(in: project.id),
                                       agentContext: context, revision: revision)
        try AgentWorkspace.publish(snapshot: snapshot, root: workspaceURL)
        let url = try exchangeStore.writeAgentContext(context, projectID: project.id, revision: revision)
        statusMessage = "Context 已导出到 \(url.path)"
        return url
    }

    func copyAgentInstructions(for projectID: String) {
        guard let project = project(withID: projectID), workspacePaths[project.id] != nil else {
            present(MacAppError.noWorkspace)
            return
        }
        let text = """
        请把以下项目词典规则加入你实际使用的项目协作指令或 Agent Skill。每次开始任务时先读取 .funcdictionary/AGENTS.md 和 dictionary.json；每次修改代码后，在结束任务前更新受影响的词条、直接调用位置和变更记录，校验并提交 Delta。直接调用用 calls 关系，从调用方指向被调用方，附相对文件、正整数行号和证据。等待 funcDictionary 确认入库后，再报告完成。

        项目：\(project.name)
        词典目录：.funcdictionary/
        """
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        statusMessage = "Agent 接入说明已复制"
    }

    func requestSendContext(to harness: HarnessID) {
        do {
            guard let project = activeProject else { throw MacAppError.noProject }
            guard workspacePaths[project.id] != nil else { throw MacAppError.noWorkspace }
            let workspaceURL = workspaceURL(for: project)
            try AgentWorkspace.validate(root: workspaceURL, projectID: project.id)
            let contextURL = try exportAgentContext()
            let prompt = """
            \(agentPrompt)

            项目：\(project.name)
            工作目录：\(workspaceURL.path)
            Context 文件：\(contextURL.path)
            协作规范：.funcdictionary/AGENTS.md
            全量词典：.funcdictionary/dictionary.json
            先读取协作规范和 Context。用 python3 .funcdictionary/funcdictionary.py --project . submit <delta文件> --wait 30 提交。
            仅更新词典交换目录，不修改业务源码。
            """
            guard let launchRequest = harnessCenter.previewLaunchRequest(
                for: harness,
                projectURL: workspaceURL,
                contextURL: contextURL,
                prompt: prompt,
                dictionaryTask: true
            ) else {
                throw MacAppError.harnessNotReady(harness.displayName)
            }
            pendingHarnessSend = PendingHarnessSend(
                harness: harness,
                projectName: project.name,
                workspaceURL: workspaceURL,
                contextURL: contextURL,
                prompt: prompt,
                launchRequest: launchRequest
            )
            statusMessage = "等待确认后通过 \(harness.displayName) 发送 Context"
        } catch {
            present(error)
        }
    }

    func confirmPendingHarnessSend() {
        guard let request = pendingHarnessSend else { return }
        pendingHarnessSend = nil
        harnessCenter.send(
            request.harness,
            launchRequest: request.launchRequest,
            workingDirectoryURL: request.workspaceURL
        )
        statusMessage = "正在通过 \(request.harness.displayName) 发送 Context"
    }

    func cancelPendingHarnessSend() {
        pendingHarnessSend = nil
    }

    func copyCLILinkCommand() {
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("funcdictionary.py") else { return }
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = "python3 \(quote(script.path)) --project \"$PWD\" link --app \(quote(Bundle.main.bundleURL.path))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        statusMessage = "CLI 接入命令已复制；在目标仓库目录中运行即可关联。"
    }

    func copyAgentContext() {
        do {
            let url = try exportAgentContext()
            let text = try String(contentsOf: url, encoding: .utf8)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            statusMessage = "Agent Context JSON 已复制到剪贴板"
        } catch {
            present(error)
        }
    }

    func revealAgentContext() {
        do {
            let url = try exportAgentContext()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            present(error)
        }
    }

    func importDeltaFromFile() {
        guard let project = activeProject else {
            present(MacAppError.noProject)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "导入 Dictionary Delta"
        panel.message = "选择当前项目的 Dictionary Delta JSON 文件。"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try Data(contentsOf: url)
            try DictionarySchemaValidator.validateJSONData(data)
            let delta = try JSONCodec.decode(DictionaryDelta.self, from: data)
            guard delta.projectID == project.id else {
                throw ExchangeValidationError.projectMismatch("Delta project (delta.projectID) does not match (project.id)")
            }
            let result = try store.repository.apply(delta: delta, in: project.id)
            reloadProjectData()
            // Keep the workspace agent-context at the newest revision so an
            // agent reading it before its next delta emits a valid base_revision.
            _ = try? exportAgentContext()
            statusMessage = result.alreadyApplied
                ? "Delta 已导入过，保持 revision \(result.newRevision)"
                : "Delta 已应用，当前 revision \(result.newRevision)，冲突 \(result.conflictCount) 条"
        } catch {
            present(error)
        }
    }

    // MARK: Delta 自动同步

    /// Every linked project is watched independently of the current selection.
    private func syncWatcherLifecycles() {
        let linkedProjects = projects.filter { workspacePaths[$0.id] != nil }
        let linkedIDs = Set(linkedProjects.map(\.id))
        for projectID in Array(deltaWatchers.keys) where !linkedIDs.contains(projectID) {
            deltaWatchers.removeValue(forKey: projectID)?.stop()
        }

        for project in linkedProjects {
            let watcher: DeltaDirectoryWatcher
            if let existing = deltaWatchers[project.id] {
                watcher = existing
            } else {
                watcher = DeltaDirectoryWatcher()
                deltaWatchers[project.id] = watcher
            }
            watcher.onDirectoryChanged = { [weak self, weak watcher] in
                guard let watcher else { return }
                self?.scanForPendingDeltas(in: project.id, watcher: watcher)
            }

            let workspace = workspaceURL(for: project)
            let exchangeURL = workspace.appendingPathComponent(".funcdictionary", isDirectory: true)
            let deltasURL = exchangeURL.appendingPathComponent("deltas", isDirectory: true)
            if FileManager.default.fileExists(atPath: deltasURL.path) {
                watcher.start(watching: deltasURL)
            } else if FileManager.default.fileExists(atPath: exchangeURL.path) {
                watcher.start(watching: exchangeURL)
            } else if FileManager.default.fileExists(atPath: workspace.path) {
                watcher.start(watching: workspace)
            } else {
                watcher.stop()
            }
            scanForPendingDeltas(in: project.id, watcher: watcher)
        }
    }

    /// The public entry point also recovers queued deltas after relaunch.
    func scanForPendingDeltas() {
        syncWatcherLifecycles()
    }

    /// Applies every not-yet-processed delta in this project, oldest first.
    private func scanForPendingDeltas(in projectID: String, watcher: DeltaDirectoryWatcher) {
        guard workspacePaths[projectID] != nil,
              let project = project(withID: projectID) else { return }
        let deltasURL = ExchangeDirectory(projectRootURL: workspaceURL(for: project)).deltasURL
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: deltasURL,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let pending = files
            .filter { !$0.hasDirectoryPath && $0.pathExtension.lowercased() == "json" }
            .sorted { modificationDate($0) < modificationDate($1) }
        for file in pending where watcher.hasPendingFile(file) {
            processDelta(at: file, projectID: projectID, watcher: watcher)
        }
    }

    private func processDelta(at url: URL, projectID: String, watcher: DeltaDirectoryWatcher) {
        watcher.markProcessed(url)
        let service = DeltaSyncService(repository: store.repository)
        do {
            let outcome = try service.applyDeltaFile(at: url, projectID: projectID)
            switch outcome {
            case .applied(let revision):
                if projectID == selectedProjectID { reloadProjectData() }
                appendSyncEvent(projectID, url, .applied(revision: revision))
                try exportAgentContext(for: projectID)
                NotificationCenter.default.post(name: .funcDictionaryStoreDidChange, object: nil)
                statusMessage = "自动同步：\(url.lastPathComponent) 已应用（revision \(revision)）"
            case .needsAttention(let revision, let conflictCount):
                if projectID == selectedProjectID { reloadProjectData() }
                appendSyncEvent(projectID, url, .needsAttention(revision: revision, conflictCount: conflictCount))
                try exportAgentContext(for: projectID)
                NotificationCenter.default.post(name: .funcDictionaryStoreDidChange, object: nil)
                statusMessage = "自动同步：已入库，但有 \(conflictCount) 项需要处理"
            case .duplicate:
                try exportAgentContext(for: projectID)
                appendSyncEvent(projectID, url, .duplicate)
            }
        } catch let error as RepositoryError {
            if case .baseRevisionMismatch(let expected, let actual) = error {
                appendSyncEvent(projectID, url, .stale(expected: expected, actual: actual))
            } else {
                appendSyncEvent(projectID, url, .failed(message: error.localizedDescription))
            }
        } catch {
            appendSyncEvent(projectID, url, .failed(message: error.localizedDescription))
        }
    }

    private func appendSyncEvent(_ projectID: String, _ url: URL, _ status: DeltaSyncEventStatus) {
        prependSyncEvent(projectID, url.lastPathComponent, status)
    }

    private func prependSyncEvent(_ projectID: String, _ fileName: String, _ status: DeltaSyncEventStatus) {
        syncEvents.insert(DeltaSyncEvent(projectID: projectID, fileName: fileName, status: status), at: 0)
        switch status {
        case .applied, .needsAttention, .duplicate:
            lastUpdateDates[projectID] = Date()
            defaults.set(lastUpdateDates, forKey: lastUpdateDatesKey)
        case .stale, .failed:
            break
        }
        if syncEvents.count > 20 {
            syncEvents.removeLast(syncEvents.count - 20)
        }
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    func exportProjectSnapshot() {
        do {
            guard let project = activeProject else { throw MacAppError.noProject }
            let projectDefinitions = try store.repository.definitions(in: project.id)
            guard !projectDefinitions.isEmpty else { throw MacAppError.noDefinition }
            let clusters = try store.repository.clusters(in: project.id)
            let definition = selectedDefinition ?? projectDefinitions.first
            let context = definition.map { AgentContextBuilder.make(for: $0, definitions: projectDefinitions) } ?? .empty
            let revision = try store.repository.currentRevision(in: project.id)
            let snapshot = ProjectSnapshot(
                project: project,
                definitions: projectDefinitions,
                clusters: clusters,
                agentContext: context,
                revision: revision
            )
            var assets: [String: Data] = [:]
            for definition in projectDefinitions {
                for metadata in definition.snapshots {
                    guard let snapshotAssets = store.snapshotAssets else { throw MacAppError.snapshotStorageUnavailable }
                    assets[metadata.id] = try snapshotAssets.read(
                        snapshotID: metadata.id,
                        projectID: project.id
                    ).jpegData
                }
            }
            let exchangeStore = FileExchangeStore(directory: ExchangeDirectory(projectRootURL: workspaceURL(for: project)))
            let urls = try exchangeStore.write(snapshot: snapshot, jpegDataBySnapshotID: assets, preserveLiveExchange: true)
            statusMessage = "Snapshot 已导出，写入 \(urls.count) 个文件"
        } catch {
            present(error)
        }
    }

    func importSnapshotForSelectedDefinition() {
        guard let project = activeProject, let definition = selectedDefinition else {
            present(MacAppError.noDefinition)
            return
        }
        guard let snapshotAssets = store.snapshotAssets else {
            present(MacAppError.snapshotStorageUnavailable)
            return
        }
        let panel = NSOpenPanel()
        panel.title = "导入 Snapshot"
        panel.message = "选择要附加到当前 Definition 的图像。"
        panel.prompt = "导入"
        panel.allowedContentTypes = [.image]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing { url.stopAccessingSecurityScopedResource() }
        }
        do {
            guard let image = NSImage(contentsOf: url) else { throw MacAppError.invalidSnapshotImage }
            let snapshotID = "snapshot_\(UUID().uuidString.lowercased())"
            let pipeline = SnapshotPipeline(directory: ExchangeDirectory(projectRootURL: workspaceURL(for: project)))
            let artifact = try pipeline.makeArtifact(
                image: image,
                snapshotID: snapshotID,
                revision: currentRevision,
                milestone: false
            )
            try snapshotAssets.save(
                metadata: artifact.metadata,
                jpegData: artifact.jpegData,
                projectID: project.id
            )
            var updated = definition
            updated.snapshots.append(artifact.metadata)
            updated.updatedAt = Date()
            try store.repository.save(definition: updated, in: project.id)
            reloadProjectData()
            selectedDefinitionID = definition.id
            statusMessage = artifact.meetsTargetByteRange
                ? "Snapshot 已导入（\(artifact.metadata.sizeBytes) bytes，符合目标范围）"
                : "Snapshot 已导入（\(artifact.metadata.sizeBytes) bytes，已保留实际测量结果）"
        } catch {
            present(error)
        }
    }

    func snapshotImage(for metadata: SnapshotMetadata, projectID: String) -> NSImage? {
        guard let snapshotAssets = store.snapshotAssets,
              let asset = try? snapshotAssets.read(snapshotID: metadata.id, projectID: projectID) else {
            return nil
        }
        return NSImage(data: asset.jpegData)
    }

    func saveDefinitionEdits(
        original: Definition,
        displayName: String,
        purpose: String,
        comment: String
    ) {
        guard let projectID = selectedProjectID else {
            present(MacAppError.noProject)
            return
        }
        let newDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let newPurpose = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let newComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newDisplayName.isEmpty else {
            present("功能名称不能为空。")
            return
        }
        let oldName = original.identity.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyKeptOldName = original.fuzzyTerms.contains {
            $0.text.compare(oldName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        let preservedOldName = newDisplayName != oldName && !oldName.isEmpty && !alreadyKeptOldName
            ? [FuzzyTermChange(definitionID: original.id, term: FuzzyTerm(text: oldName, source: .humanAdded))]
            : []
        let previous = [
            "display_name": original.identity.displayName,
            "purpose": original.function.purpose,
            "func_comment": original.codeLocator.comment
        ]
        let updated = [
            "display_name": newDisplayName,
            "purpose": newPurpose,
            "func_comment": newComment
        ]
        let changes = updated.filter { previous[$0.key] != $0.value }
        guard !changes.isEmpty else {
            statusMessage = "没有需要保存的修改"
            return
        }
        do {
            let baseRevision = try store.repository.currentRevision(in: projectID)
            let delta = DictionaryDelta(
                deltaID: "delta_manual_\(UUID().uuidString.lowercased())",
                projectID: projectID,
                baseRevision: baseRevision,
                targetRevision: baseRevision + 1,
                changedFields: changes.keys.sorted(),
                definitionsEvolved: [
                    DefinitionEvolution(
                        definitionID: original.id,
                        changeType: "manual_note",
                        changes: changes,
                        codeImpact: 0,
                        semanticImpact: 0.05,
                        milestone: false
                    )
                ],
                fuzzyTermsAdded: preservedOldName
            )
            _ = try store.repository.apply(delta: delta, in: projectID)
            reloadProjectData()
            selectedDefinitionID = original.id
            prependSyncEvent(projectID, "人工编辑", .applied(revision: baseRevision + 1))
            statusMessage = "功能说明已保存"
        } catch {
            present(error)
        }
    }

    func resolveConflict(_ conflict: ConflictRecord, useRemoteValue: Bool) {
        guard let projectID = selectedProjectID, projectID == conflict.projectID else {
            present(MacAppError.noProject)
            return
        }
        do {
            let revision = try store.repository.currentRevision(in: projectID)
            var resolved = conflict
            resolved.status = .resolved
            let value = useRemoteValue ? conflict.remoteValue : conflict.localValue
            let delta = DictionaryDelta(
                deltaID: "delta_resolution_\(UUID().uuidString.lowercased())",
                projectID: projectID,
                baseRevision: revision,
                targetRevision: revision + 1,
                changedFields: [conflict.field],
                definitionsEvolved: [DefinitionEvolution(
                    definitionID: conflict.definitionID,
                    changeType: "conflict_resolution",
                    changes: [conflict.field: value],
                    codeImpact: 0,
                    semanticImpact: 0.05,
                    milestone: false
                )],
                conflictRecords: [resolved]
            )
            _ = try store.repository.apply(delta: delta, in: projectID)
            reloadProjectData()
            selectedDefinitionID = conflict.definitionID
            prependSyncEvent(projectID, "冲突处理", .applied(revision: revision + 1))
            statusMessage = "冲突已处理"
        } catch {
            present(error)
        }
    }

    func cycleHumanPriority(for definitionID: String) {
        guard let projectID = selectedProjectID,
              var definition = definitions.first(where: { $0.id == definitionID }) else { return }
        switch definition.humanPriority?.level {
        case nil:
            definition.humanPriority = HumanPriority(level: .important, label: "Important", note: "用户标记")
        case .important:
            definition.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "结构性修改需要 Change Request")
        case .critical:
            definition.humanPriority = nil
        }
        definition.updatedAt = Date()
        do {
            try store.repository.save(definition: definition, in: projectID)
            reloadProjectData()
            selectedDefinitionID = definitionID
            statusMessage = definition.humanPriority.map { "已标记为 \($0.level.rawValue)" } ?? "已取消 Pin"
        } catch {
            present(error)
        }
    }

    func markDefinitionReviewed(_ definitionID: String) {
        guard let projectID = selectedProjectID,
              var definition = definitions.first(where: { $0.id == definitionID }) else { return }
        definition.reviewStatus = .approved
        definition.updatedAt = Date()
        do {
            try store.repository.save(definition: definition, in: projectID)
            reloadProjectData()
            selectedDefinitionID = definitionID
            statusMessage = "Definition 已标记为已审查"
        } catch {
            present(error)
        }
    }

    func decideProposal(_ proposal: Proposal, approved: Bool) {
        guard let projectID = selectedProjectID else { return }
        do {
            let decided = GovernanceEngine.decide(proposal, approved: approved)
            try store.repository.save(proposal: decided, in: projectID)
            var didApply = false
            if approved {
                didApply = try applyApprovedProposalIfReady(decided, in: projectID)
            }
            reloadProjectData()
            statusMessage = if !approved {
                "Proposal 已拒绝"
            } else if didApply {
                "Proposal 已批准并应用"
            } else {
                "Proposal 已批准，等待关联的 Change Request"
            }
        } catch {
            present(error)
        }
    }

    func adjustProposal(_ proposal: Proposal, summary: String) {
        guard let projectID = selectedProjectID else { return }
        do {
            let adjusted = GovernanceEngine.adjust(proposal, summary: summary)
            try store.repository.save(proposal: adjusted, in: projectID)
            let didApply = try applyApprovedProposalIfReady(adjusted, in: projectID)
            reloadProjectData()
            statusMessage = didApply
                ? "Proposal 已调整并应用"
                : "Proposal 已调整，等待关联的 Change Request"
        } catch {
            present(error)
        }
    }

    func decideChangeRequest(_ request: ChangeRequest, approved: Bool) {
        guard let projectID = selectedProjectID else { return }
        do {
            let decided = GovernanceEngine.decide(request, approved: approved)
            try store.repository.save(changeRequest: decided, in: projectID)
            let didApply = approved
                ? try applyApprovedChangeRequestIfReady(decided, in: projectID)
                : false
            reloadProjectData()
            statusMessage = if !approved {
                "Change Request 已拒绝"
            } else if didApply {
                "Change Request 已批准并应用"
            } else {
                "Change Request 已批准，等待关联的 Proposal"
            }
        } catch {
            present(error)
        }
    }

    private func applyApprovedProposalIfReady(_ proposal: Proposal, in projectID: String) throws -> Bool {
        try store.repository.apply(approved: proposal, in: projectID)
    }

    private func applyApprovedChangeRequestIfReady(_ request: ChangeRequest, in projectID: String) throws -> Bool {
        try store.repository.apply(approved: request, in: projectID)
    }

    func clearError() {
        errorMessage = nil
    }

    private func reloadProjectData() {
        guard let projectID = selectedProjectID else {
            definitions = []
            proposals = []
            changeRequests = []
            conflicts = []
            currentRevision = 0
            return
        }
        do {
            definitions = try store.repository.definitions(in: projectID)
            proposals = try store.repository.pendingProposals(in: projectID)
            changeRequests = try store.repository.pendingChangeRequests(in: projectID)
            conflicts = try store.repository.conflicts(in: projectID)
            currentRevision = try store.repository.currentRevision(in: projectID)
            if workspacePaths[projectID] != nil {
                do { _ = try exportAgentContext() }
                catch { present(error) } // Export failure must not hide persisted definitions.
            }
            if let selectedDefinitionID,
               !definitions.contains(where: { $0.id == selectedDefinitionID }) {
                self.selectedDefinitionID = nil
            }
            NotificationCenter.default.post(name: .funcDictionaryStoreDidChange, object: nil)
        } catch {
            definitions = []
            proposals = []
            changeRequests = []
            conflicts = []
            currentRevision = 0
            present(error)
        }
    }

    private func setSelectedProject(_ projectID: String?) {
        selectedProjectID = projectID
        if let projectID {
            defaults.set(projectID, forKey: selectedProjectKey)
        } else {
            defaults.removeObject(forKey: selectedProjectKey)
        }
    }

    private func present(_ error: Error) {
        errorMessage = error.localizedDescription
    }

    private func present(_ message: String) {
        errorMessage = message
    }
}
