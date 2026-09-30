import CoreData
import XCTest
@testable import funcDictionary

@MainActor
final class PersistenceAndDomainTests: XCTestCase {
    func testInMemoryRepositoryIsProjectScopedAndRollsBackFailedDelta() throws {
        let repository = InMemoryProjectRepository()
        let projectA = Project(id: "project_a", name: "Project A")
        let projectB = Project(id: "project_b", name: "Project B")
        try repository.save(project: projectA)
        try repository.save(project: projectB)

        try repository.save(definition: makeDefinition(id: "def_shared", projectID: projectA.id), in: projectA.id)
        XCTAssertThrowsError(
            try repository.save(definition: makeDefinition(id: "def_shared", projectID: projectB.id), in: projectB.id)
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .duplicateStableID("def_shared"))
        }
        XCTAssertEqual(try repository.definitions(in: projectA.id).count, 1)
        XCTAssertTrue(try repository.definitions(in: projectB.id).isEmpty)

        let delta = DictionaryDelta(
            deltaID: "delta_rollback",
            projectID: projectA.id,
            baseRevision: 0,
            targetRevision: 1,
            definitionsCreated: [makeDefinition(id: "def_created", projectID: projectA.id)],
            definitionsEvolved: [
                DefinitionEvolution(
                    definitionID: "def_missing",
                    changeType: "rename",
                    changes: ["from": "Old", "to": "New"],
                    codeImpact: 0.2,
                    semanticImpact: 0.2,
                    milestone: false
                )
            ]
        )

        XCTAssertThrowsError(try repository.apply(delta: delta, in: projectA.id))
        XCTAssertEqual(try repository.definitions(in: projectA.id).map(\.id).sorted(), ["def_shared"])
        XCTAssertEqual(try repository.currentRevision(in: projectA.id), 0)
    }

    func testInMemoryDeltaIsIdempotentAndRejectsStaleBaseRevision() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_delta", name: "Delta")
        try repository.save(project: project)
        try repository.save(definition: makeDefinition(id: "def_delta", projectID: project.id), in: project.id)
        let delta = DictionaryDelta(
            deltaID: "delta_once",
            projectID: project.id,
            baseRevision: 0,
            targetRevision: 1,
            definitionsEvolved: [
                DefinitionEvolution(
                    definitionID: "def_delta",
                    changeType: "rename",
                    changes: ["from": "Old", "to": "New"],
                    codeImpact: 0.4,
                    semanticImpact: 0.6,
                    milestone: true
                )
            ]
        )

        let first = try repository.apply(delta: delta, in: project.id)
        let second = try repository.apply(delta: delta, in: project.id)
        XCTAssertEqual(first, DeltaApplyResult(imported: true, alreadyApplied: false, newRevision: 1, conflictCount: 0))
        XCTAssertEqual(second, DeltaApplyResult(imported: false, alreadyApplied: true, newRevision: 1, conflictCount: 0))
        XCTAssertEqual(try repository.definition(id: "def_delta", in: project.id)?.implementationHistory.count, 1)

        let staleDelta = DictionaryDelta(
            deltaID: "delta_stale",
            projectID: project.id,
            baseRevision: 0,
            targetRevision: 2
        )
        XCTAssertThrowsError(try repository.apply(delta: staleDelta, in: project.id)) { error in
            XCTAssertEqual(error as? RepositoryError, .baseRevisionMismatch(expected: 1, actual: 0))
        }
    }

    func testRepositoryRequiresGovernanceForProtectedStructuralWrites() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_governed", name: "Governed")
        try repository.save(project: project)

        var definition = makeDefinition(id: "def_protected", projectID: project.id)
        definition.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "Protected")
        try repository.save(definition: definition, in: project.id)

        var changed = definition
        changed.codeLocator.symbol = "ChangedSymbol"
        XCTAssertThrowsError(try repository.save(definition: changed, in: project.id)) { error in
            XCTAssertEqual(error as? RepositoryError, .governanceRequired("an approved Change Request"))
        }

        let request = GovernanceEngine.makeChangeRequest(
            definition: definition,
            requestedChange: RequestedChange(type: "structure", summary: "Rename protected symbol"),
            reason: "Protected symbol changed",
            risk: "Agent may break callers",
            proposedValues: RepositoryWritePolicy.protectedChangePayload(for: changed)
        )
        try repository.save(changeRequest: request, in: project.id)
        XCTAssertThrowsError(try repository.save(definition: changed, in: project.id))

        try repository.save(
            changeRequest: GovernanceEngine.decide(request, approved: true),
            in: project.id
        )
        try repository.save(definition: changed, in: project.id)
        XCTAssertEqual(try repository.definition(id: definition.id, in: project.id)?.codeLocator.symbol, "ChangedSymbol")
    }

    func testRepositoryRequiresApprovedProposalForTerminalReviewStatus() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_proposal_gate", name: "Proposal Gate")
        try repository.save(project: project)
        let definition = makeDefinition(id: "def_proposal_gate", projectID: project.id)
        try repository.save(definition: definition, in: project.id)

        var deprecated = definition
        deprecated.reviewStatus = .deprecated
        XCTAssertThrowsError(try repository.save(definition: deprecated, in: project.id)) { error in
            XCTAssertEqual(error as? RepositoryError, .governanceRequired("an approved Proposal"))
        }

        let proposal = GovernanceEngine.makeProposal(
            action: .deprecated,
            projectID: project.id,
            definitionIDs: [definition.id],
            summary: "Deprecate definition"
        )
        try repository.save(proposal: proposal, in: project.id)
        XCTAssertThrowsError(try repository.save(definition: deprecated, in: project.id))

        let wrongAction = GovernanceEngine.makeProposal(
            action: .split,
            projectID: project.id,
            definitionIDs: [definition.id],
            summary: "Split instead"
        )
        try repository.save(
            proposal: GovernanceEngine.decide(wrongAction, approved: true),
            in: project.id
        )
        XCTAssertThrowsError(try repository.save(definition: deprecated, in: project.id))

        try repository.save(proposal: GovernanceEngine.decide(proposal, approved: true), in: project.id)
        try repository.save(definition: deprecated, in: project.id)
        XCTAssertEqual(try repository.definition(id: definition.id, in: project.id)?.reviewStatus, .deprecated)
    }

    func testCoreDataRepositoryEnforcesStableIDsAndProtectedGovernance() throws {
        let persistence = try PersistenceController(mode: .inMemory)
        let repository = CoreDataProjectRepository(persistence: persistence)
        let projectA = Project(id: "project_core_a", name: "Core A")
        let projectB = Project(id: "project_core_b", name: "Core B")
        try repository.save(project: projectA)
        try repository.save(project: projectB)

        var definition = makeDefinition(id: "def_core_shared", projectID: projectA.id)
        try repository.save(definition: definition, in: projectA.id)
        XCTAssertThrowsError(
            try repository.save(
                definition: makeDefinition(id: definition.id, projectID: projectB.id),
                in: projectB.id
            )
        ) { error in
            XCTAssertEqual(error as? RepositoryError, .duplicateStableID(definition.id))
        }

        definition.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "Protected")
        try repository.save(definition: definition, in: projectA.id)
        var changed = definition
        changed.codeLocator.symbol = "ChangedCoreSymbol"
        XCTAssertThrowsError(try repository.save(definition: changed, in: projectA.id)) { error in
            XCTAssertEqual(error as? RepositoryError, .governanceRequired("an approved Change Request"))
        }

        let request = GovernanceEngine.makeChangeRequest(
            definition: definition,
            requestedChange: RequestedChange(type: "structure", summary: "Change core symbol"),
            reason: "Core symbol changed",
            risk: "Callers may need migration",
            proposedValues: RepositoryWritePolicy.protectedChangePayload(for: changed)
        )
        try repository.save(
            changeRequest: GovernanceEngine.decide(request, approved: true),
            in: projectA.id
        )
        try repository.save(definition: changed, in: projectA.id)
        XCTAssertEqual(try repository.definition(id: definition.id, in: projectA.id)?.codeLocator.symbol, "ChangedCoreSymbol")
    }

    func testCoreDataLocalStorePersistsAndStoresAppliedDeltaMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let project = Project(id: "project_sqlite", name: "SQLite")
        let definition = makeDefinition(id: "def_sqlite", projectID: project.id)
        let delta = DictionaryDelta(
            deltaID: "delta_sqlite",
            projectID: project.id,
            baseRevision: 0,
            targetRevision: 1,
            definitionsCreated: [definition]
        )

        do {
            let persistence = try PersistenceController(mode: .local(directory: directory))
            let repository = CoreDataProjectRepository(persistence: persistence)
            try repository.save(project: project)
            let result = try repository.apply(delta: delta, in: project.id)
            XCTAssertTrue(result.imported)
            XCTAssertEqual(try repository.definitions(in: project.id).map(\.id), [definition.id])
            let repeated = try repository.apply(delta: delta, in: project.id)
            XCTAssertTrue(repeated.alreadyApplied)
            XCTAssertEqual(repeated.newRevision, 1)
            try closeStores(in: persistence)
        }

        do {
            let reopenedPersistence = try PersistenceController(mode: .local(directory: directory))
            let reopenedRepository = CoreDataProjectRepository(persistence: reopenedPersistence)
            XCTAssertEqual(try reopenedRepository.projects().map(\.id), [project.id])
            XCTAssertEqual(try reopenedRepository.definitions(in: project.id).map(\.id), [definition.id])
            let nextDelta = DictionaryDelta(
                deltaID: "delta_sqlite_next",
                projectID: project.id,
                baseRevision: 1,
                targetRevision: 2
            )
            XCTAssertTrue(try reopenedRepository.apply(delta: nextDelta, in: project.id).imported)
            try closeStores(in: reopenedPersistence)
        }
        try FileManager.default.removeItem(at: directory)
    }

    private func closeStores(in persistence: PersistenceController) throws {
        let coordinator = persistence.container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }

    func testCoreDataModelKeepsStoreBoundariesAndNoRelationships() throws {
        let model = try NSManagedObjectModel.funcDictionaryModel()
        XCTAssertNotNil(model.entitiesByName["Project"])
        XCTAssertNotNil(model.entitiesByName["Definition"])
        XCTAssertNotNil(model.entitiesByName["ProjectAccess"])
        XCTAssertTrue(model.entities.allSatisfy { $0.relationshipsByName.isEmpty })

        let cloudNames = Set((model.entities(forConfigurationName: "CloudStore") ?? []).compactMap(\.name))
        let localNames = Set((model.entities(forConfigurationName: "LocalStore") ?? []).compactMap(\.name))
        XCTAssertTrue(cloudNames.contains("Project"))
        XCTAssertTrue(cloudNames.contains("Definition"))
        XCTAssertTrue(cloudNames.contains("Snapshot"))
        XCTAssertTrue(localNames.contains("ProjectAccess"))
        XCTAssertTrue(localNames.contains("ExportState"))
        XCTAssertTrue(localNames.contains("DeviceState"))
        XCTAssertTrue(cloudNames.isDisjoint(with: localNames))

        let snapshot = try XCTUnwrap(model.entitiesByName["Snapshot"])
        // The shipped model leaves the managed object class name unprefixed
        // so the iOS and macOS targets can each map Snapshot to their own
        // CDSnapshotRecord without runtime class resolution failures.
        XCTAssertTrue(
            snapshot.managedObjectClassName == "CDSnapshotRecord"
                || snapshot.managedObjectClassName?.hasSuffix(".CDSnapshotRecord") == true,
            "Unexpected Snapshot managed object class: \(snapshot.managedObjectClassName ?? "nil")"
        )
        XCTAssertTrue(snapshot.attributesByName["payload"]?.isOptional == true)
        XCTAssertTrue(snapshot.attributesByName["file"] != nil)
        XCTAssertTrue(snapshot.attributesByName["width"] != nil)
        XCTAssertTrue(snapshot.attributesByName["height"] != nil)
        XCTAssertTrue(snapshot.attributesByName["sizeBytes"] != nil)
        XCTAssertTrue(snapshot.attributesByName["perceptualHash"] != nil)
        XCTAssertTrue(snapshot.attributesByName["revision"] != nil)
        XCTAssertTrue(snapshot.attributesByName["milestone"] != nil)
    }

    private func makeDefinition(id: String, projectID: String) -> Definition {
        Definition(
            id: id,
            projectID: projectID,
            identity: DefinitionIdentity(
                canonicalName: "Example.\(id)",
                displayName: id,
                kind: .component
            ),
            function: FunctionDescriptor(domain: "Testing", purpose: "Verify persistence"),
            codeLocator: CodeLocator(symbol: "\(id)Symbol", function: "render()", file: "Example.swift"),
            visualLocator: VisualLocator(screen: "Example"),
            functionalLocator: FunctionalLocator(domain: "Testing", role: "Example", trigger: "Tap")
        )
    }
}
