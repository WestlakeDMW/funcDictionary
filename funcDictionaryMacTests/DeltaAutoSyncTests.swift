import Foundation
import XCTest
@testable import funcDictionaryMac

@MainActor
final class DeltaAutoSyncTests: XCTestCase {
    func testAgentPackageSupportsEmptyProjectAndPreservesInbox() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = Project(id: "project_package", name: "Package")
        let snapshot = ProjectSnapshot(project: project, definitions: [], clusters: [], agentContext: .empty, revision: 0)
        try AgentWorkspace.publish(snapshot: snapshot, root: root)
        let exchange = root.appendingPathComponent(".funcdictionary")
        let pending = exchange.appendingPathComponent("deltas/delta_pending.json")
        try Data("pending".utf8).write(to: pending)
        try AgentWorkspace.publish(snapshot: snapshot, root: root)
        XCTAssertEqual(try String(contentsOf: pending, encoding: .utf8), "pending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exchange.appendingPathComponent("AGENTS.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exchange.appendingPathComponent("funcdictionary.py").path))
        let exported = try JSONCodec.decode(ProjectSnapshot.self, from: Data(contentsOf: exchange.appendingPathComponent("dictionary.json")))
        XCTAssertEqual(exported.project.id, project.id)
        XCTAssertEqual(exported.definitions, [])
        XCTAssertThrowsError(try AgentWorkspace.validate(root: root, projectID: "project_foreign"))
    }

    func testLinkURLRoundTripsSpacesChineseAndRejectsUnknownCommand() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("词典 空格-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var url = URLComponents()
        url.scheme = "funcdictionary"
        url.host = "link"
        url.queryItems = [URLQueryItem(name: "path", value: root.path)]
        XCTAssertEqual(try AgentWorkspace.root(from: XCTUnwrap(url.url)).path, root.path)
        url.host = "execute"
        XCTAssertThrowsError(try AgentWorkspace.root(from: XCTUnwrap(url.url)))
    }

    func testSnapshotExportDoesNotEraseLiveInboxOrAgentInstructions() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileExchangeStore(directory: ExchangeDirectory(projectRootURL: root))
        let delta = DictionaryDelta(deltaID: "delta_waiting", projectID: "project_export", baseRevision: 0, targetRevision: 1)
        let pending = try store.write(delta: delta)
        let instructions = store.directory.rootURL.appendingPathComponent("AGENTS.md")
        try Data("rules".utf8).write(to: instructions)
        let snapshot = ProjectSnapshot(project: Project(id: "project_export", name: "Export"),
                                       definitions: [], clusters: [], agentContext: .empty, revision: 0)
        _ = try store.write(snapshot: snapshot, preserveLiveExchange: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pending.path))
        XCTAssertEqual(try String(contentsOf: instructions, encoding: .utf8), "rules")
    }

    func testWatcherDoesNotConfuseSameNamedFilesInDifferentProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first/delta.json")
        let second = root.appendingPathComponent("second/delta.json")
        for file in [first, second] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: file)
        }
        let watcher = DeltaDirectoryWatcher()
        watcher.markProcessed(first)
        XCTAssertFalse(watcher.hasPendingFile(first))
        XCTAssertTrue(watcher.hasPendingFile(second))
    }

    private struct Harness {
        let repository: CoreDataProjectRepository
        let service: DeltaSyncService
        let exchangeStore: FileExchangeStore
        let exchangeDirectory: ExchangeDirectory
        let projectID: String
        let workDirectory: URL

        var deltasURL: URL { exchangeDirectory.deltasURL }
    }

    func testApplyDeltaFileAppliesDefinitionsAndArchivesFile() async throws {
        let harness = try await makeHarness()
        let delta = makeDelta(
            deltaID: "delta_auto_sync_apply",
            projectID: harness.projectID,
            baseRevision: 0,
            targetRevision: 1
        )
        let url = try harness.exchangeStore.write(delta: delta)

        let outcome = try harness.service.applyDeltaFile(at: url, projectID: harness.projectID)

        XCTAssertEqual(outcome, .applied(revision: 1))
        let definition = try harness.repository.definition(id: "def_auto_sync_probe", in: harness.projectID)
        XCTAssertEqual(definition?.identity.canonicalName, "AutoSyncProbe")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: harness.deltasURL.appendingPathComponent("applied/\(url.lastPathComponent)").path
            )
        )
    }

    func testApplyDeltaFileIsIdempotentByDeltaID() async throws {
        let harness = try await makeHarness()
        let delta = makeDelta(
            deltaID: "delta_auto_sync_idempotent",
            projectID: harness.projectID,
            baseRevision: 0,
            targetRevision: 1
        )
        let url = try harness.exchangeStore.write(delta: delta)

        XCTAssertEqual(try harness.service.applyDeltaFile(at: url, projectID: harness.projectID), .applied(revision: 1))

        // An agent that re-emits the same delta_id gets a no-op, not a second apply.
        let rewritten = try harness.exchangeStore.write(delta: delta)
        XCTAssertEqual(try harness.service.applyDeltaFile(at: rewritten, projectID: harness.projectID), .duplicate)
    }

    func testApplyDeltaFileRejectsStaleBaseRevision() async throws {
        let harness = try await makeHarness()
        let first = makeDelta(
            deltaID: "delta_auto_sync_first",
            projectID: harness.projectID,
            baseRevision: 0,
            targetRevision: 1
        )
        let second = makeDelta(
            deltaID: "delta_auto_sync_second",
            projectID: harness.projectID,
            baseRevision: 0,
            targetRevision: 1,
            definitionID: "def_auto_sync_second"
        )
        let firstURL = try harness.exchangeStore.write(delta: first)
        let secondURL = try harness.exchangeStore.write(delta: second)

        _ = try harness.service.applyDeltaFile(at: firstURL, projectID: harness.projectID)

        XCTAssertThrowsError(
            try harness.service.applyDeltaFile(at: secondURL, projectID: harness.projectID)
        ) { error in
            XCTAssertEqual(
                error as? RepositoryError,
                .baseRevisionMismatch(expected: 1, actual: 0)
            )
        }
    }

    func testApplyDeltaFileRejectsForeignProject() async throws {
        let harness = try await makeHarness()
        let delta = makeDelta(
            deltaID: "delta_auto_sync_foreign",
            projectID: "project_someone_else",
            baseRevision: 0,
            targetRevision: 1
        )
        let url = try harness.exchangeStore.write(delta: delta)

        XCTAssertThrowsError(
            try harness.service.applyDeltaFile(at: url, projectID: harness.projectID)
        ) { error in
            guard case ExchangeValidationError.projectMismatch = error else {
                return XCTFail("Expected projectMismatch, got \(error)")
            }
        }
    }

    func testApplyDeltaFileRejectsInvalidJSON() async throws {
        let harness = try await makeHarness()
        try FileManager.default.createDirectory(at: harness.deltasURL, withIntermediateDirectories: true)
        let url = harness.deltasURL.appendingPathComponent("delta_auto_sync_broken.json")
        try Data("not a delta".utf8).write(to: url)

        XCTAssertThrowsError(
            try harness.service.applyDeltaFile(at: url, projectID: harness.projectID)
        )
    }

    func testDefinitionCommentSurvivesJSONRoundTrip() throws {
        var definition = Definition(
            id: "def_auto_sync_probe",
            projectID: "project_probe",
            identity: DefinitionIdentity(canonicalName: "Probe", displayName: "探针", kind: .component),
            function: FunctionDescriptor(domain: "testing", purpose: "probe"),
            codeLocator: CodeLocator(symbol: "Probe", file: "Probe.swift", comment: "判定子物品能否放入目标容器"),
            visualLocator: VisualLocator(),
            functionalLocator: FunctionalLocator()
        )
        definition.codeLocator.comment = "判定子物品能否放入目标容器"

        let definitionData = try JSONCodec.encode(definition)
        let decodedDefinition = try JSONCodec.decode(Definition.self, from: definitionData)
        XCTAssertEqual(
            decodedDefinition.codeLocator.comment,
            "判定子物品能否放入目标容器",
            "Definition round trip json: \(String(data: definitionData, encoding: .utf8) ?? "")"
        )

        let evolution = DefinitionEvolution(
            definitionID: definition.id,
            changeType: "annotate_func",
            changes: ["code_locator.func_comment": "判定子物品能否放入目标容器"],
            codeImpact: 0,
            semanticImpact: 0.1,
            milestone: false
        )
        let evolutionData = try JSONCodec.encode(evolution)
        let evolutionJSON = String(data: evolutionData, encoding: .utf8) ?? ""
        XCTAssertTrue(evolutionJSON.contains("func_comment"), "evolution json should keep func_comment key: \(evolutionJSON)")
        let decodedEvolution = try JSONCodec.decode(DefinitionEvolution.self, from: evolutionData)
        XCTAssertEqual(
            decodedEvolution.changes["code_locator.func_comment"],
            "判定子物品能否放入目标容器",
            "Evolution changes round trip: \(evolutionJSON)"
        )
    }

    func testApplyingSetsFuncCommentDirectly() {
        let definition = Definition(
            id: "def_auto_sync_probe",
            projectID: "project_probe",
            identity: DefinitionIdentity(canonicalName: "Probe", displayName: "探针", kind: .component),
            function: FunctionDescriptor(domain: "testing", purpose: "probe"),
            codeLocator: CodeLocator(symbol: "Probe", file: "Probe.swift"),
            visualLocator: VisualLocator(),
            functionalLocator: FunctionalLocator()
        )
        let evolution = DefinitionEvolution(
            definitionID: definition.id,
            changeType: "annotate_func",
            changes: ["code_locator.func_comment": "判定子物品能否放入目标容器"],
            codeImpact: 0,
            semanticImpact: 0.1,
            milestone: false
        )

        let updated = evolution.applying(to: definition)

        XCTAssertEqual(updated.codeLocator.comment, "判定子物品能否放入目标容器")
    }

    func testEvolutionAppliesFuncComment() async throws {
        let harness = try await makeHarness()
        let seed = makeDelta(
            deltaID: "delta_auto_sync_comment_seed",
            projectID: harness.projectID,
            baseRevision: 0,
            targetRevision: 1
        )
        let seedURL = try harness.exchangeStore.write(delta: seed)
        _ = try harness.service.applyDeltaFile(at: seedURL, projectID: harness.projectID)

        let evolution = DefinitionEvolution(
            definitionID: "def_auto_sync_probe",
            changeType: "annotate_func",
            changes: ["code_locator.func_comment": "判定子物品能否放入目标容器"],
            codeImpact: 0,
            semanticImpact: 0.1,
            milestone: false
        )
        let commentDelta = DictionaryDelta(
            deltaID: "delta_auto_sync_comment",
            projectID: harness.projectID,
            baseRevision: 1,
            targetRevision: 2,
            definitionsEvolved: [evolution]
        )
        let commentURL = try harness.exchangeStore.write(delta: commentDelta)
        _ = try harness.service.applyDeltaFile(at: commentURL, projectID: harness.projectID)

        let updated = try harness.repository.definition(id: "def_auto_sync_probe", in: harness.projectID)
        XCTAssertEqual(updated?.codeLocator.comment, "判定子物品能否放入目标容器")
    }

    func testEvolutionAppliesUIMetrics() async throws {
        let harness = try await makeHarness()
        let seed = makeDelta(
            deltaID: "delta_auto_sync_metrics_seed",
            projectID: harness.projectID,
            baseRevision: 0,
            targetRevision: 1
        )
        _ = try harness.service.applyDeltaFile(
            at: harness.exchangeStore.write(delta: seed),
            projectID: harness.projectID
        )

        let evolution = DefinitionEvolution(
            definitionID: "def_auto_sync_probe",
            changeType: "annotate_ui_metrics",
            changes: [
                "ui_metric.网格列间距": "16pt（来自 PageOneMetrics.inventoryGridSpacing）",
                "ui_metric.面板最小圆角": "28pt",
            ],
            codeImpact: 0,
            semanticImpact: 0.1,
            milestone: false
        )
        let metricsDelta = DictionaryDelta(
            deltaID: "delta_auto_sync_metrics",
            projectID: harness.projectID,
            baseRevision: 1,
            targetRevision: 2,
            definitionsEvolved: [evolution]
        )
        _ = try harness.service.applyDeltaFile(
            at: harness.exchangeStore.write(delta: metricsDelta),
            projectID: harness.projectID
        )

        let updated = try harness.repository.definition(id: "def_auto_sync_probe", in: harness.projectID)
        XCTAssertEqual(updated?.uiMetrics?.count, 2)
        XCTAssertEqual(updated?.uiMetrics?.first { $0.property == "网格列间距" }?.value, "16pt（来自 PageOneMetrics.inventoryGridSpacing）")
        XCTAssertEqual(updated?.uiMetrics?.first { $0.property == "面板最小圆角" }?.value, "28pt")
    }

    // MARK: Harness

    private func makeHarness() async throws -> Harness {
        let persistence = try PersistenceController(mode: .inMemory)
        try await persistence.loadPersistentStores()
        let repository = CoreDataProjectRepository(persistence: persistence)
        let projectID = "project_auto_sync_\(UUID().uuidString.lowercased().prefix(8))"
        try repository.save(project: Project(id: projectID, name: "Auto Sync Tests"))

        let workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionaryAutoSyncTests-\(UUID().uuidString)", isDirectory: true)
        let exchangeDirectory = ExchangeDirectory(projectRootURL: workDirectory)

        return Harness(
            repository: repository,
            service: DeltaSyncService(repository: repository),
            exchangeStore: FileExchangeStore(directory: exchangeDirectory),
            exchangeDirectory: exchangeDirectory,
            projectID: projectID,
            workDirectory: workDirectory
        )
    }

    private func makeDelta(
        deltaID: String,
        projectID: String,
        baseRevision: Int,
        targetRevision: Int,
        definitionID: String = "def_auto_sync_probe"
    ) -> DictionaryDelta {
        let definition = Definition(
            id: definitionID,
            projectID: projectID,
            identity: DefinitionIdentity(canonicalName: "AutoSyncProbe", displayName: "自动同步探针", kind: .component),
            function: FunctionDescriptor(domain: "testing", purpose: "验证 Delta 自动同步链路"),
            codeLocator: CodeLocator(
                symbol: "AutoSyncProbe",
                symbolType: "struct",
                function: "probe()",
                signature: "struct AutoSyncProbe",
                owner: "AutoSyncProbe",
                file: "AutoSyncProbe.swift",
                module: "funcDictionaryMacTests",
                lineHint: 1
            ),
            visualLocator: VisualLocator(screen: "TestScreen", container: "probe", region: "center"),
            functionalLocator: FunctionalLocator(domain: "testing", role: "probe", trigger: "test")
        )
        return DictionaryDelta(
            deltaID: deltaID,
            projectID: projectID,
            baseRevision: baseRevision,
            targetRevision: targetRevision,
            changedFields: ["identity", "code_locator"],
            definitionsCreated: [definition]
        )
    }
}
