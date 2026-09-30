import AppKit
import Foundation
import XCTest
@testable import funcDictionaryMac

@MainActor
final class MacCoreRegressionTests: XCTestCase {
    func testBidirectionalSearchFindsSymbolPurposeAndHumanComment() {
        var definition = makeDefinition(id: "def_search", projectID: "project_search")
        definition.codeLocator.function = "uploadDictionary()"
        definition.function.purpose = "上传项目词典"
        definition.codeLocator.comment = "离线数据补传"
        let engine = SearchEngine()
        for query in ["uploadDictionary()", "uploadDict", "项目词典", "离线数据补传"] {
            let result = engine.search(query: query, projectID: definition.projectID, definitions: [definition])
            let ids = ([result.direct] + result.candidates + result.related).compactMap { $0?.definitionID }
            XCTAssertTrue(ids.contains(definition.id), "Missing result for \(query)")
        }
    }

    func testDefinitionEvolutionAppliesRenameValuesAndKeepsLineage() {
        let definition = makeDefinition(id: "def_rename", projectID: "project_rename")
        let plan = DefinitionEvolutionEngine.planRename(
            definition: definition,
            canonicalName: "RenamedDefinition",
            displayName: "Renamed",
            symbol: "RenamedSymbol"
        )

        let updated = plan.evolution.applying(to: definition)

        XCTAssertEqual(updated.identity.canonicalName, "RenamedDefinition")
        XCTAssertEqual(updated.identity.displayName, "Renamed")
        XCTAssertEqual(updated.codeLocator.symbol, "RenamedSymbol")
        XCTAssertTrue(updated.lineage.contains(definition.identity.canonicalName))
    }

    func testSearchExplicitProjectScopeRejectsMixedInput() {
        let first = makeDefinition(id: "def_scope_a", projectID: "project_scope_a")
        let second = makeDefinition(id: "def_scope_b", projectID: "project_scope_b")

        let response = SearchEngine().search(
            query: "scope",
            projectID: "project_scope_a",
            definitions: [first, second]
        )

        XCTAssertNil(response.direct)
        XCTAssertTrue(response.candidates.isEmpty)
        XCTAssertTrue(response.related.isEmpty)
    }

    func testSnapshotAssetRequiresAnExistingProject() async throws {
        let persistence = try await loadedPersistence()
        let store = SnapshotAssetStore(persistence: persistence)
        let metadata = SnapshotMetadata(
            id: "snapshot_missing_project",
            file: "snapshots/snapshot_missing_project.jpg",
            width: 2,
            height: 2,
            sizeBytes: 2,
            perceptualHash: "0123456789abcdef",
            revision: 0
        )

        XCTAssertThrowsError(
            try store.save(
                metadata: metadata,
                jpegData: Data([0xff, 0xd8]),
                projectID: "project_missing"
            )
        ) { error in
            XCTAssertEqual(error as? SnapshotAssetStoreError, .projectNotFound("project_missing"))
        }
    }

    func testCoreDataDeltaPreflightIncludesApprovedProtectedRequest() async throws {
        let persistence = try await loadedPersistence()
        let repository = CoreDataProjectRepository(persistence: persistence)
        let project = Project(id: "project_governed_mac", name: "Governed macOS")
        try repository.save(project: project)

        var definition = makeDefinition(id: "def_governed_mac", projectID: project.id)
        definition.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "Protected")
        try repository.save(definition: definition, in: project.id)

        let plan = DefinitionEvolutionEngine.planRename(
            definition: definition,
            canonicalName: "GovernedRenamed",
            displayName: "Governed Renamed",
            symbol: "GovernedRenamedSymbol"
        )
        let request = ChangeRequest(
            id: "cr_governed_mac",
            projectID: project.id,
            definitionID: definition.id,
            requestedChange: RequestedChange(type: "rename", summary: "Rename protected definition"),
            reason: "Keep the dictionary current",
            risk: "Callers may use the old symbol",
            affectedDefinitionIDs: [definition.id],
            proposedValues: RepositoryWritePolicy.protectedChangePayload(for: plan.updatedDefinition),
            status: .approved
        )
        try repository.save(changeRequest: request, in: project.id)
        var identityProposal = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: project.id,
            definitionIDs: [definition.id],
            summary: "Approve governed rename"
        )
        identityProposal.status = .approved
        identityProposal.payload["canonical_name"] = "GovernedRenamed"
        identityProposal.payload["display_name"] = "Governed Renamed"
        identityProposal.payload["symbol"] = "GovernedRenamedSymbol"
        try repository.save(proposal: identityProposal, in: project.id)
        let delta = DictionaryDelta(
            deltaID: "delta_governed_mac",
            projectID: project.id,
            baseRevision: 0,
            targetRevision: 1,
            definitionsEvolved: [plan.evolution]
        )

        let result = try repository.apply(delta: delta, in: project.id)
        XCTAssertTrue(result.imported)
        let updated = try XCTUnwrap(try repository.definition(id: definition.id, in: project.id))
        XCTAssertEqual(updated.identity.canonicalName, "GovernedRenamed")
        XCTAssertEqual(updated.codeLocator.symbol, "GovernedRenamedSymbol")
        let revisions = try repository.fieldRevisions(for: definition.id, in: project.id)
        XCTAssertTrue(revisions.contains { $0.field == "canonical_name" && $0.revision == 1 })
        XCTAssertTrue(revisions.contains { $0.field == "symbol" && $0.source == "delta:delta_governed_mac" })
    }

    func testInMemoryIdentityChangeDoesNotRequireProposal() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_identity_gate", name: "Identity Gate")
        try repository.save(project: project)
        let original = makeDefinition(id: "def_identity_gate", projectID: project.id)
        try repository.save(definition: original, in: project.id)

        var changed = original
        changed.identity.canonicalName = "Renamed.Identity"
        try repository.save(definition: changed, in: project.id)
        XCTAssertEqual(try repository.definition(id: original.id, in: project.id)?.identity.canonicalName, "Renamed.Identity")
        XCTAssertTrue(try repository.proposals(in: project.id).isEmpty)

        var proposal = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: project.id,
            definitionIDs: [original.id],
            summary: "Approve identity change"
        )
        proposal.status = .approved
        proposal.payload = RepositoryWritePolicy.editableValues(for: changed)
        try repository.save(proposal: proposal, in: project.id)
        try repository.save(definition: changed, in: project.id)
        XCTAssertEqual(try repository.definition(id: original.id, in: project.id)?.identity.canonicalName, "Renamed.Identity")
    }

    func testIdentityProposalAppliesTheCompleteEditorPayload() throws {
        let definition = makeDefinition(id: "def_identity_payload", projectID: "project_identity_payload")
        var proposal = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: definition.projectID,
            definitionIDs: [definition.id],
            summary: "Apply complete editor payload"
        )
        proposal.status = .approved
        proposal.payload = [
            "canonical_name": "Renamed.Payload",
            "display_name": "Renamed Payload",
            "symbol": "renamedPayload",
            "func": "drawPayload()",
            "file": "PayloadView.swift",
            "domain": "Rendering",
            "purpose": "Render the payload"
        ]

        let application = try GovernanceEngine.applyApproved(proposal, to: [definition])
        let updated = try XCTUnwrap(application.updatedDefinitions.first)
        XCTAssertEqual(updated.identity.canonicalName, "Renamed.Payload")
        XCTAssertEqual(updated.identity.displayName, "Renamed Payload")
        XCTAssertEqual(updated.codeLocator.symbol, "renamedPayload")
        XCTAssertEqual(updated.codeLocator.function, "drawPayload()")
        XCTAssertEqual(updated.codeLocator.file, "PayloadView.swift")
        XCTAssertEqual(updated.function.domain, "Rendering")
        XCTAssertEqual(updated.function.purpose, "Render the payload")
        XCTAssertTrue(updated.lineage.contains(definition.identity.canonicalName))
    }

    func testLegacyIdentityApprovalDoesNotBlockNewFacts() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_identity_binding", name: "Identity Binding")
        try repository.save(project: project)
        let original = makeDefinition(id: "def_identity_binding", projectID: project.id)
        try repository.save(definition: original, in: project.id)

        var approved = original
        approved.identity.canonicalName = "Approved.Name"
        approved.identity.displayName = "Approved Name"
        var proposal = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: project.id,
            definitionIDs: [original.id],
            summary: "Approve one exact identity"
        )
        proposal.status = .approved
        proposal.payload = RepositoryWritePolicy.editableValues(for: approved)
        try repository.save(proposal: proposal, in: project.id)

        var different = original
        different.identity.canonicalName = "Different.Name"
        try repository.save(definition: different, in: project.id)
        XCTAssertEqual(try repository.definition(id: original.id, in: project.id)?.identity.canonicalName, "Different.Name")
        XCTAssertEqual(try repository.proposals(in: project.id).first?.payload, proposal.payload)
    }

    func testLegacyChangeRequestDoesNotBlockNewStructure() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_change_binding", name: "Change Binding")
        try repository.save(project: project)
        var original = makeDefinition(id: "def_change_binding", projectID: project.id)
        original.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "Protected")
        try repository.save(definition: original, in: project.id)

        var approved = original
        approved.codeLocator.symbol = "ApprovedSymbol"
        var request = GovernanceEngine.makeChangeRequest(
            definition: original,
            requestedChange: RequestedChange(type: "structure", summary: "Approve one exact structure"),
            reason: "Protected symbol change",
            risk: "Callers may need migration",
            proposedValues: RepositoryWritePolicy.protectedChangePayload(for: approved)
        )
        request.status = .approved
        try repository.save(changeRequest: request, in: project.id)

        var different = original
        different.codeLocator.symbol = "DifferentSymbol"
        try repository.save(definition: different, in: project.id)
        let saved = try XCTUnwrap(try repository.definition(id: original.id, in: project.id))
        XCTAssertEqual(saved.codeLocator.symbol, "DifferentSymbol")
        XCTAssertEqual(saved.humanPriority, original.humanPriority)
        XCTAssertEqual(try repository.changeRequests(in: project.id).first?.proposedValues, request.proposedValues)
    }

    func testDeltaPersistsChangedFieldsAsFieldRevisionsInMemory() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_field_revision", name: "Field Revision")
        try repository.save(project: project)
        let definition = makeDefinition(id: "def_field_revision", projectID: project.id)
        try repository.save(definition: definition, in: project.id)
        let delta = DictionaryDelta(
            deltaID: "delta_field_revision",
            projectID: project.id,
            baseRevision: 0,
            targetRevision: 1,
            changedFields: ["def_field_revision.code_locator.func", "def_field_revision.visual_locator.screen"],
            definitionsEvolved: [
                DefinitionEvolution(
                    definitionID: definition.id,
                    changeType: "implementation_change",
                    changes: ["code_locator.func": "render() -> draw()"],
                    codeImpact: 0.2,
                    semanticImpact: 0.2,
                    milestone: false
                )
            ]
        )

        _ = try repository.apply(delta: delta, in: project.id)
        let revisions = try repository.fieldRevisions(for: definition.id, in: project.id)
        XCTAssertEqual(Set(revisions.map(\.field)), ["code_locator.func", "visual_locator.screen"])
        XCTAssertTrue(revisions.allSatisfy { $0.revision == 1 && $0.source == "delta:delta_field_revision" })
    }

    func testCoreDataDefinitionLookupHidesArchivedDefinition() async throws {
        let persistence = try await loadedPersistence()
        let repository = CoreDataProjectRepository(persistence: persistence)
        let project = Project(id: "project_archived_lookup", name: "Archived Lookup")
        try repository.save(project: project)
        let definition = makeDefinition(id: "def_archived_lookup", projectID: project.id)
        try repository.save(definition: definition, in: project.id)

        try repository.softDelete(definitionID: definition.id, in: project.id)

        XCTAssertNil(try repository.definition(id: definition.id, in: project.id))
        XCTAssertTrue(try repository.definitions(in: project.id).isEmpty)
    }

    func testMergeProposalWithOneDefinitionReturnsInvalidPayload() throws {
        let definition = makeDefinition(id: "def_merge_single", projectID: "project_merge_single")
        var proposal = GovernanceEngine.makeProposal(
            action: .merge,
            projectID: definition.projectID,
            definitionIDs: [definition.id],
            summary: "Invalid single-definition merge"
        )
        proposal.status = .approved

        XCTAssertThrowsError(try GovernanceEngine.applyApproved(proposal, to: [definition])) { error in
            XCTAssertEqual(error as? GovernanceEngine.ProposalApplicationError, .invalidPayload("definition_ids"))
        }
    }

    func testExchangeRejectsSnapshotMetadataWithoutBinaryData() throws {
        let project = Project(id: "project_missing_snapshot_bytes", name: "Missing Snapshot Bytes")
        let metadata = SnapshotMetadata(
            id: "snapshot_missing_bytes",
            file: "snapshots/snapshot_missing_bytes.jpg",
            width: 720,
            height: 480,
            sizeBytes: 4,
            perceptualHash: "0123456789abcdef",
            revision: 1
        )
        var definition = makeDefinition(id: "def_missing_snapshot_bytes", projectID: project.id)
        definition.snapshots = [metadata]
        let snapshot = ProjectSnapshot(project: project, definitions: [definition], revision: 1)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-mac-missing-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileExchangeStore(directory: ExchangeDirectory(rootURL: root))
        XCTAssertThrowsError(try store.write(snapshot: snapshot)) { error in
            XCTAssertEqual(error as? ExchangeValidationError, .invalidSnapshotMetadata("snapshot_missing_bytes"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("snapshot.json").path))
    }

    func testConfiguredCloudKitDoesNotClaimSyncedWithoutRemoteEvidence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-mac-cloud-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let persistence = try PersistenceController(
            mode: .cloudCapable(
                directory: directory,
                containerIdentifier: "iCloud.com.example.funcDictionary"
            )
        )
        let coordinator = CloudSyncCoordinator(
            persistence: persistence,
            configuration: CloudKitConfiguration(
                containerIdentifier: "iCloud.com.example.funcDictionary"
            )
        )

        XCTAssertEqual(coordinator.state, .needsConfirmation)
        XCTAssertTrue(coordinator.statusSummary.contains("verification pending"))
        coordinator.start()
        XCTAssertEqual(coordinator.state, .needsConfirmation)
        coordinator.requestSync()
        XCTAssertEqual(coordinator.state, .syncing)
        coordinator.stop()
    }

    func testExchangeWriteReplacesWholePackageAndRemovesStaleFiles() throws {
        let project = Project(id: "project_atomic_mac", name: "Atomic package")
        let definition = makeDefinition(id: "def_atomic_mac", projectID: project.id)
        let snapshot = ProjectSnapshot(project: project, definitions: [definition])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-mac-atomic-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileExchangeStore(directory: ExchangeDirectory(rootURL: root))
        try store.write(snapshot: snapshot)
        let staleURL = root.appendingPathComponent("stale.txt")
        try Data("stale".utf8).write(to: staleURL)

        var updatedProject = project
        updatedProject.name = "Atomic package updated"
        try store.write(snapshot: ProjectSnapshot(project: updatedProject, definitions: [definition]))

        XCTAssertFalse(FileManager.default.fileExists(atPath: staleURL.path))
        XCTAssertEqual(try store.readSnapshot().project.name, "Atomic package updated")
    }

    func testMacSnapshotPipelineProducesPortableJPEG() throws {
        let image = NSImage(size: NSSize(width: 320, height: 200))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 320, height: 200).fill()
        NSColor.white.setFill()
        NSRect(x: 60, y: 40, width: 200, height: 120).fill()
        image.unlockFocus()

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-mac-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = SnapshotPipeline(directory: ExchangeDirectory(rootURL: root))
        let metadata = try pipeline.write(
            image: image,
            snapshotID: "snapshot_mac_pipeline",
            revision: 3,
            milestone: true
        )

        XCTAssertEqual(max(metadata.width, metadata.height), 720)
        XCTAssertGreaterThan(metadata.sizeBytes, 0)
        XCTAssertEqual(metadata.perceptualHash.count, 16)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(metadata.file).path))
    }

    func testMacSnapshotPipelineTargetsContractByteRangeForDetailedImage() throws {
        let width = 720
        let height = 720
        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        for row in 0..<12 {
            for column in 0..<12 {
                let seed = (row * 37 + column * 19) % 100
                NSColor(
                    calibratedRed: 0.18 + CGFloat(seed) / 190,
                    green: 0.30 + CGFloat((seed * 3) % 80) / 200,
                    blue: 0.55 + CGFloat((seed * 7) % 60) / 220,
                    alpha: 1
                ).setFill()
                NSRect(
                    x: column * 60 + 1,
                    y: row * 60 + 1,
                    width: 58,
                    height: 58
                ).fill()
            }
        }
        NSColor.white.withAlphaComponent(0.65).setStroke()
        for offset in stride(from: 0, through: width, by: 72) {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: offset, y: 0))
            path.line(to: NSPoint(x: offset, y: height))
            path.stroke()
        }
        image.unlockFocus()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-mac-snapshot-target-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = SnapshotPipeline(directory: ExchangeDirectory(rootURL: root))
        let artifact = try pipeline.makeArtifact(
            image: image,
            snapshotID: "snapshot_mac_target",
            revision: 1
        )

        XCTAssertTrue(artifact.meetsTargetByteRange, "measured JPEG size was \(artifact.jpegData.count) bytes")
        XCTAssertTrue(SnapshotPipeline.targetByteRange.contains(artifact.metadata.sizeBytes))
    }

    func testApprovedProposalApplicationWritesAuditTrail() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_proposal_audit", name: "Proposal Audit")
        try repository.save(project: project)
        let original = makeDefinition(id: "def_proposal_audit", projectID: project.id)
        try repository.save(definition: original, in: project.id)

        var renamed = original
        renamed.identity.canonicalName = "Audited.Rename"
        renamed.identity.displayName = "Audited Rename"
        renamed.codeLocator.symbol = "auditedSymbol"
        var proposal = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: project.id,
            definitionIDs: [original.id],
            summary: "Audit every applied identity change"
        )
        proposal.status = .approved
        proposal.payload = RepositoryWritePolicy.editableValues(for: renamed)
        try repository.save(proposal: proposal, in: project.id)

        let didApply = try repository.apply(approved: proposal, in: project.id)

        XCTAssertTrue(didApply)
        let updated = try XCTUnwrap(try repository.definition(id: original.id, in: project.id))
        XCTAssertEqual(updated.identity.canonicalName, "Audited.Rename")
        let event = try XCTUnwrap(updated.implementationHistory.last)
        XCTAssertEqual(event.changeType, "identity_change")
        XCTAssertEqual(event.revision, 1)
        XCTAssertTrue(event.milestone)
        XCTAssertEqual(event.changes["canonical_name"], "Audited.Rename")
        let revisions = try repository.fieldRevisions(for: original.id, in: project.id)
        XCTAssertTrue(revisions.contains {
            $0.field == "canonical_name" && $0.revision == 1 && $0.source == "proposal:\(proposal.id)"
        })
        XCTAssertTrue(revisions.contains { $0.field == "symbol" && $0.revision == 1 })
        XCTAssertEqual(try repository.currentRevision(in: project.id), 1)
    }

    func testLegacyPriorityDoesNotBlockRenameAndPendingRequestIsPreserved() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_protected_pair", name: "Protected Pair")
        try repository.save(project: project)
        var original = makeDefinition(id: "def_protected_pair", projectID: project.id)
        original.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "Protected")
        try repository.save(definition: original, in: project.id)

        var renamed = original
        renamed.identity.canonicalName = "Paired.Rename"
        renamed.identity.displayName = "Paired Rename"
        var proposal = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: project.id,
            definitionIDs: [original.id],
            summary: "Rename a protected definition"
        )
        proposal.status = .approved
        proposal.payload = RepositoryWritePolicy.editableValues(for: renamed)
        try repository.save(proposal: proposal, in: project.id)
        var request = GovernanceEngine.makeChangeRequest(
            definition: original,
            requestedChange: RequestedChange(type: "identity_change", summary: "Pair the protected rename"),
            reason: "Protected identity change",
            risk: "Callers may use the old symbol",
            proposedValues: RepositoryWritePolicy.protectedChangePayload(for: renamed)
        )
        try repository.save(changeRequest: request, in: project.id)

        XCTAssertTrue(try repository.apply(approved: proposal, in: project.id))
        let updated = try XCTUnwrap(try repository.definition(id: original.id, in: project.id))
        XCTAssertEqual(updated.identity.canonicalName, "Paired.Rename")
        XCTAssertEqual(updated.humanPriority, original.humanPriority)
        XCTAssertEqual(try repository.changeRequests(in: project.id).first?.status, request.status)
        XCTAssertEqual(updated.implementationHistory.last?.revision, 1)
        XCTAssertEqual(try repository.currentRevision(in: project.id), 1)
        XCTAssertTrue(try repository.fieldRevisions(for: original.id, in: project.id).contains {
            $0.field == "canonical_name" && $0.source == "proposal:\(proposal.id)"
        })
    }

    func testCoreDataProposalApplicationWritesAuditTrail() async throws {
        let persistence = try await loadedPersistence()
        let repository = CoreDataProjectRepository(persistence: persistence)
        let project = Project(id: "project_coredata_audit", name: "CoreData Audit")
        try repository.save(project: project)
        let original = makeDefinition(id: "def_coredata_audit", projectID: project.id)
        try repository.save(definition: original, in: project.id)

        var renamed = original
        renamed.identity.canonicalName = "CoreData.Rename"
        renamed.codeLocator.symbol = "coreDataSymbol"
        var proposal = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: project.id,
            definitionIDs: [original.id],
            summary: "Audit the Core Data transaction path"
        )
        proposal.status = .approved
        proposal.payload = RepositoryWritePolicy.editableValues(for: renamed)
        try repository.save(proposal: proposal, in: project.id)

        let didApply = try repository.apply(approved: proposal, in: project.id)

        XCTAssertTrue(didApply)
        let updated = try XCTUnwrap(try repository.definition(id: original.id, in: project.id))
        XCTAssertEqual(updated.identity.canonicalName, "CoreData.Rename")
        let event = try XCTUnwrap(updated.implementationHistory.last)
        XCTAssertEqual(event.changeType, "identity_change")
        XCTAssertEqual(event.revision, 1)
        let revisions = try repository.fieldRevisions(for: original.id, in: project.id)
        XCTAssertTrue(revisions.contains {
            $0.field == "canonical_name" && $0.source == "proposal:\(proposal.id)"
        })
        XCTAssertEqual(try repository.currentRevision(in: project.id), 1)
    }

    func testReadSnapshotRejectsMissingOrCorruptSnapshotAssets() throws {
        let project = Project(id: "project_asset_check", name: "Asset Check")
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let metadata = SnapshotMetadata(
            id: "snapshot_asset_check",
            file: "snapshots/snapshot_asset_check.jpg",
            width: 2,
            height: 2,
            sizeBytes: jpegData.count,
            perceptualHash: "0123456789abcdef",
            revision: 1
        )
        var definition = makeDefinition(id: "def_asset_check", projectID: project.id)
        definition.snapshots = [metadata]
        let snapshot = ProjectSnapshot(project: project, definitions: [definition], revision: 1)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-mac-asset-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileExchangeStore(directory: ExchangeDirectory(rootURL: root))
        try store.write(snapshot: snapshot, jpegDataBySnapshotID: [metadata.id: jpegData])
        XCTAssertEqual(try store.readSnapshot().project.id, project.id)

        let assetURL = try store.directory.snapshotFileURL(relativePath: metadata.file)
        try FileManager.default.removeItem(at: assetURL)
        XCTAssertThrowsError(try store.readSnapshot()) { error in
            XCTAssertEqual(error as? ExchangeValidationError, .invalidSnapshotMetadata(metadata.id))
        }

        try Data([0xFF, 0xD8, 0xFF, 0xD9, 0x00]).write(to: assetURL)
        XCTAssertThrowsError(try store.readSnapshot()) { error in
            XCTAssertEqual(error as? ExchangeValidationError, .invalidSnapshotMetadata(metadata.id))
        }

        // Byte count matching the declaration but a corrupted JPEG header
        // must still be rejected by the signature check.
        try Data([0x00, 0x01, 0x02, 0x03]).write(to: assetURL)
        XCTAssertThrowsError(try store.readSnapshot()) { error in
            XCTAssertEqual(error as? ExchangeValidationError, .invalidSnapshotMetadata(metadata.id))
        }

        try Data("not a jpeg".utf8).write(to: assetURL)
        XCTAssertThrowsError(try store.readSnapshot()) { error in
            XCTAssertEqual(error as? ExchangeValidationError, .invalidSnapshotMetadata(metadata.id))
        }
    }

    func testRepeatedApprovedProposalApplicationIsIdempotent() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_apply_twice", name: "Apply Twice")
        try repository.save(project: project)
        let original = makeDefinition(id: "def_apply_twice", projectID: project.id)
        try repository.save(definition: original, in: project.id)

        var renamed = original
        renamed.identity.canonicalName = "Renamed.Once"
        var proposal = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: project.id,
            definitionIDs: [original.id],
            summary: "Apply once; re-apply must be a no-op"
        )
        proposal.status = .approved
        proposal.payload = RepositoryWritePolicy.editableValues(for: renamed)
        try repository.save(proposal: proposal, in: project.id)

        XCTAssertTrue(try repository.apply(approved: proposal, in: project.id))
        let applied = try XCTUnwrap(try repository.definition(id: original.id, in: project.id))
        let eventCount = applied.implementationHistory.count
        let revisionCount = try repository.fieldRevisions(for: original.id, in: project.id).count

        // The second application must not append lineage to itself and
        // must not forge another audit event or revision.
        XCTAssertTrue(try repository.apply(approved: proposal, in: project.id))
        let after = try XCTUnwrap(try repository.definition(id: original.id, in: project.id))
        XCTAssertEqual(after.implementationHistory.count, eventCount)
        XCTAssertEqual(try repository.fieldRevisions(for: original.id, in: project.id).count, revisionCount)
        XCTAssertEqual(try repository.currentRevision(in: project.id), 1)
        XCTAssertFalse(after.lineage.contains(after.identity.canonicalName))
    }

    func testSuccessiveEditSubmissionsKeepPriorApprovalInLedger() throws {
        let first = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: "project_ledger",
            definitionIDs: ["def_ledger"],
            summary: "First submission",
            uniqueSubmissionID: true
        )
        let second = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: "project_ledger",
            definitionIDs: ["def_ledger"],
            summary: "Second submission",
            uniqueSubmissionID: true
        )
        XCTAssertNotEqual(first.id, second.id)
        let firstRequest = GovernanceEngine.makeChangeRequest(
            definition: makeDefinition(id: "def_ledger", projectID: "project_ledger"),
            requestedChange: RequestedChange(type: "identity_change", summary: "First request"),
            reason: "r",
            risk: "r",
            uniqueSubmissionID: true
        )
        let secondRequest = GovernanceEngine.makeChangeRequest(
            definition: makeDefinition(id: "def_ledger", projectID: "project_ledger"),
            requestedChange: RequestedChange(type: "identity_change", summary: "Second request"),
            reason: "r",
            risk: "r",
            uniqueSubmissionID: true
        )
        XCTAssertNotEqual(firstRequest.id, secondRequest.id)

        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_ledger", name: "Ledger")
        try repository.save(project: project)
        let definition = makeDefinition(id: "def_ledger", projectID: project.id)
        try repository.save(definition: definition, in: project.id)

        var approvedSubmission = first
        approvedSubmission.status = .approved
        try repository.save(proposal: approvedSubmission, in: project.id)
        // A later edit for the same Definition creates its own record; the
        // approved decision must remain untouched in the ledger.
        try repository.save(proposal: second, in: project.id)
        let storedFirst = try XCTUnwrap(
            try repository.proposals(in: project.id).first { $0.id == approvedSubmission.id }
        )
        XCTAssertEqual(storedFirst.status, .approved)
        XCTAssertEqual(try repository.pendingProposals(in: project.id).map(\.id), [second.id])
    }

    func testIncompleteLegacyRequestDoesNotBlockCurrentCodeFacts() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_lineage_binding", name: "Lineage Binding")
        try repository.save(project: project)
        var original = makeDefinition(id: "def_lineage_binding", projectID: project.id)
        original.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "Protected")
        try repository.save(definition: original, in: project.id)

        var renamed = original
        renamed.codeLocator.symbol = "BoundSymbol"
        var proposedValues = RepositoryWritePolicy.protectedChangePayload(for: renamed)
        proposedValues.removeValue(forKey: "lineage")
        var request = GovernanceEngine.makeChangeRequest(
            definition: original,
            requestedChange: RequestedChange(type: "definition_edit", summary: "Missing lineage binding"),
            reason: "Incomplete proposed values",
            risk: "Unbounded approval",
            proposedValues: proposedValues
        )
        request.status = .approved
        try repository.save(changeRequest: request, in: project.id)

        try repository.save(definition: renamed, in: project.id)
        XCTAssertEqual(try repository.definition(id: original.id, in: project.id)?.codeLocator.symbol, "BoundSymbol")
        XCTAssertEqual(try repository.changeRequests(in: project.id).first?.proposedValues, proposedValues)
    }

    func testChangedFieldsAuditsProtectedLocatorAndRelations() {
        let original = makeDefinition(id: "def_audit_protected", projectID: "project_audit")
        var updated = original
        updated.functionalLocator.domain = "Sharing"
        updated.relations.append(
            Relation(type: .uses, sourceDefinitionID: original.id, targetDefinitionID: "def_audit_other")
        )

        let changes = RepositoryWritePolicy.changedFields(from: original, to: updated)
        XCTAssertEqual(Set(changes.map(\.field)), ["functional_locator", "relations"])
        XCTAssertTrue(changes.first { $0.field == "functional_locator" }?.value.contains("Sharing") == true)

        let event = RepositoryWritePolicy.implementationEvent(changeType: "structure", changes: changes, revision: 1)
        XCTAssertEqual(event.codeImpact, 0.0)
        XCTAssertEqual(event.semanticImpact, 1.0)
    }

    func testSplitProposalBaselineRecordsInheritedState() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_split_baseline", name: "Split Baseline")
        try repository.save(project: project)
        let source = makeDefinition(id: "def_split_baseline", projectID: project.id)
        try repository.save(definition: source, in: project.id)

        var proposal = GovernanceEngine.makeProposal(
            action: .split,
            projectID: project.id,
            definitionIDs: [source.id],
            summary: "Split with inherited baseline"
        )
        proposal.status = .approved
        proposal.payload["new_definition_ids"] = "def_split_part"
        try repository.save(proposal: proposal, in: project.id)

        XCTAssertTrue(try repository.apply(approved: proposal, in: project.id))

        let part = try XCTUnwrap(try repository.definition(id: "def_split_part", in: project.id))
        let event = try XCTUnwrap(part.implementationHistory.last)
        let fields = Set(event.changes.keys)
        let expectedFields: Set<String> = [
            "canonical_name", "display_name", "kind", "symbol", "func", "file", "domain", "purpose",
            "review_status", "lineage",
            "code_locator", "visual_locator", "functional_locator", "function"
        ]
        XCTAssertEqual(fields, expectedFields)
        XCTAssertTrue(event.changes["lineage"]?.contains("def_split_baseline") == true)
        XCTAssertTrue(event.changes["functional_locator"]?.contains("Testing") == true)
    }

    private func loadedPersistence() async throws -> PersistenceController {
        let persistence = try PersistenceController(mode: .inMemory)
        try await persistence.loadPersistentStores()
        XCTAssertTrue(persistence.isLoaded)
        return persistence
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
            function: FunctionDescriptor(domain: "Testing", purpose: "Verify macOS MVP"),
            codeLocator: CodeLocator(symbol: "\(id)Symbol", function: "render()", file: "Example.swift"),
            visualLocator: VisualLocator(screen: "Example"),
            functionalLocator: FunctionalLocator(domain: "Testing", role: "Example", trigger: "Tap")
        )
    }
}
