import XCTest
@testable import funcDictionary

@MainActor
final class JSONAndExchangeTests: XCTestCase {
    func testProtocolUsesFuncAndCurrentFuncKeys() throws {
        let definition = makeDefinition()
        let context = AgentContextBuilder.make(for: definition)

        let definitionData = try JSONCodec.encode(definition)
        let definitionObject = try XCTUnwrap(JSONSerialization.jsonObject(with: definitionData) as? [String: Any])
        let codeLocator = try XCTUnwrap(definitionObject["code_locator"] as? [String: Any])
        XCTAssertNotNil(codeLocator["func"])
        XCTAssertNil(codeLocator["function"])

        let contextData = try JSONCodec.encode(context)
        let contextJSON = String(decoding: contextData, as: UTF8.self)
        XCTAssertTrue(contextJSON.contains("\"current_func\""))
        XCTAssertFalse(contextJSON.contains("\"current_function\""))
    }

    func testSnapshotAndDeltaRoundTripThroughExchangeDirectory() throws {
        let project = Project(id: "project_exchange", name: "Exchange Test")
        let definition = makeDefinition(projectID: project.id)
        let snapshot = ProjectSnapshot(
            project: project,
            definitions: [definition],
            agentContext: AgentContextBuilder.make(for: definition)
        )
        try DictionarySchemaValidator.validate(snapshot: snapshot)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-exchange-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = FileExchangeStore(directory: ExchangeDirectory(rootURL: root))
        let snapshotFiles = try store.write(snapshot: snapshot)
        XCTAssertTrue(snapshotFiles.contains { $0.lastPathComponent == "snapshot.json" })
        let roundTrippedSnapshot = try store.readSnapshot()
        XCTAssertEqual(
            roundTrippedSnapshot.generatedAt.timeIntervalSince1970,
            snapshot.generatedAt.timeIntervalSince1970,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            roundTrippedSnapshot.project.createdAt.timeIntervalSince1970,
            snapshot.project.createdAt.timeIntervalSince1970,
            accuracy: 0.000001
        )
        XCTAssertEqual(
            roundTrippedSnapshot.project.updatedAt.timeIntervalSince1970,
            snapshot.project.updatedAt.timeIntervalSince1970,
            accuracy: 0.000001
        )
        for (actual, expected) in zip(roundTrippedSnapshot.definitions, snapshot.definitions) {
            XCTAssertEqual(
                actual.createdAt.timeIntervalSince1970,
                expected.createdAt.timeIntervalSince1970,
                accuracy: 0.000001
            )
            XCTAssertEqual(
                actual.updatedAt.timeIntervalSince1970,
                expected.updatedAt.timeIntervalSince1970,
                accuracy: 0.000001
            )
        }
        var normalizedSnapshot = roundTrippedSnapshot
        normalizedSnapshot.generatedAt = snapshot.generatedAt
        normalizedSnapshot.project.createdAt = snapshot.project.createdAt
        normalizedSnapshot.project.updatedAt = snapshot.project.updatedAt
        normalizedSnapshot.definitions = zip(normalizedSnapshot.definitions, snapshot.definitions).map { actual, expected in
            var normalized = actual
            normalized.createdAt = expected.createdAt
            normalized.updatedAt = expected.updatedAt
            return normalized
        }
        XCTAssertEqual(normalizedSnapshot, snapshot)

        let delta = DictionaryDelta(
            deltaID: "delta_exchange_1",
            projectID: project.id,
            baseRevision: 0,
            targetRevision: 1,
            changedFields: ["def_exchange.code_locator.func"],
            definitionsEvolved: [
                DefinitionEvolution(
                    definitionID: definition.id,
                    changeType: "implementation_change",
                    changes: ["func": "old() -> new()"],
                    codeImpact: 0.4,
                    semanticImpact: 0.2,
                    milestone: false
                )
            ]
        )
        let deltaURL = try store.write(delta: delta)
        XCTAssertTrue(FileManager.default.fileExists(atPath: deltaURL.path))
        let roundTrippedDelta = try store.read(deltaID: delta.deltaID)
        XCTAssertEqual(
            roundTrippedDelta.createdAt.timeIntervalSince1970,
            delta.createdAt.timeIntervalSince1970,
            accuracy: 0.000001
        )
        var normalizedDelta = roundTrippedDelta
        normalizedDelta.createdAt = delta.createdAt
        XCTAssertEqual(normalizedDelta, delta)
    }

    func testReadSnapshotRejectsMissingOrCorruptSnapshotAssets() throws {
        let project = Project(id: "project_exchange_assets", name: "Exchange Assets")
        let jpegData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let metadata = SnapshotMetadata(
            id: "snapshot_exchange_assets",
            file: "snapshots/snapshot_exchange_assets.jpg",
            width: 2,
            height: 2,
            sizeBytes: jpegData.count,
            perceptualHash: "0123456789abcdef",
            revision: 1
        )
        var definition = makeDefinition(projectID: project.id)
        definition.snapshots = [metadata]
        let snapshot = ProjectSnapshot(project: project, definitions: [definition], revision: 1)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-exchange-assets-\(UUID().uuidString)", isDirectory: true)
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

        try Data("not a jpeg".utf8).write(to: assetURL)
        XCTAssertThrowsError(try store.readSnapshot()) { error in
            XCTAssertEqual(error as? ExchangeValidationError, .invalidSnapshotMetadata(metadata.id))
        }
    }

    func testPRDChangeObjectFormDecodesToCurrentValue() throws {
        let data = Data(#"""
        {
            "definition_id": "def_exchange",
            "change_type": "implementation_change",
            "changes": {
                "func": { "from": "old()", "to": "new()" },
                "file": "Features/New.swift"
            },
            "code_impact": 0.4,
            "semantic_impact": 0.2,
            "milestone": false
        }
        """#.utf8)

        let evolution = try JSONCodec.decode(DefinitionEvolution.self, from: data)
        XCTAssertEqual(evolution.changes["func"], "old() -> new()")
        XCTAssertEqual(evolution.changes["file"], "Features/New.swift")
    }

    func testValidatorRejectsUnsafeSnapshotPathAndEmbeddedBinary() throws {
        var definition = makeDefinition()
        definition.snapshots = [
            SnapshotMetadata(
                id: "snapshot_unsafe",
                file: "../outside.jpg",
                width: 720,
                height: 480,
                sizeBytes: 20_000,
                perceptualHash: "abc",
                revision: 1
            )
        ]
        let project = Project(id: definition.projectID, name: "Unsafe")
        let snapshot = ProjectSnapshot(project: project, definitions: [definition])
        XCTAssertThrowsError(try DictionarySchemaValidator.validate(snapshot: snapshot))

        XCTAssertThrowsError(
            try DictionarySchemaValidator.validateJSONData(
                Data(#"{"schema_version":"1.0","image":"data:image/jpeg;base64,AAAA"}"#.utf8)
            )
        )
    }

    func testSnapshotValidatorRejectsRelationsToUnknownDefinitions() throws {
        let project = Project(id: "project_relation_validation", name: "Relation Validation")
        var definition = makeDefinition(projectID: project.id)
        definition.relations = [
            Relation(
                id: "relation_missing_target",
                type: .uses,
                sourceDefinitionID: definition.id,
                targetDefinitionID: "def_missing"
            )
        ]
        XCTAssertThrowsError(
            try DictionarySchemaValidator.validate(
                snapshot: ProjectSnapshot(project: project, definitions: [definition])
            )
        ) { error in
            XCTAssertEqual(error as? ExchangeValidationError, .invalidRelation("relation_missing_target"))
        }
    }

    func testSnapshotExportMaterializesJPEGBytesAndKeepsJSONPortable() throws {
        let project = Project(id: "project_snapshot_export", name: "Snapshot Export")
        let snapshotMetadata = SnapshotMetadata(
            id: "snapshot_export",
            file: "snapshots/snapshot_export.jpg",
            width: 720,
            height: 480,
            sizeBytes: 6,
            perceptualHash: "0123456789abcdef",
            revision: 1
        )
        var definition = makeDefinition(projectID: project.id)
        definition.snapshots = [snapshotMetadata]
        let snapshot = ProjectSnapshot(project: project, definitions: [definition])
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-snapshot-export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let jpegData = Data([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xd9])
        let store = FileExchangeStore(directory: ExchangeDirectory(rootURL: root))
        let urls = try store.write(snapshot: snapshot, jpegDataBySnapshotID: [snapshotMetadata.id: jpegData])
        let imageURL = try ExchangeDirectory(rootURL: root).snapshotFileURL(relativePath: snapshotMetadata.file)

        XCTAssertTrue(urls.contains(imageURL))
        XCTAssertEqual(try Data(contentsOf: imageURL), jpegData)
        let exportedJSON = try Data(contentsOf: root.appendingPathComponent("snapshot.json"))
        XCTAssertFalse(String(decoding: exportedJSON, as: UTF8.self).contains("/9j"))
        XCTAssertFalse(String(decoding: exportedJSON, as: UTF8.self).contains("base64"))
    }

    func testJSONCodecIgnoresUnknownForwardCompatibleFields() throws {
        let project = Project(id: "project_forward", name: "Forward")
        let snapshot = ProjectSnapshot(project: project, definitions: [])
        let encoded = try JSONCodec.encode(snapshot)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["future_field"] = ["reserved": true]
        let futureData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])

        let decoded = try JSONCodec.decode(ProjectSnapshot.self, from: futureData)
        XCTAssertEqual(decoded.project.id, project.id)
        XCTAssertEqual(decoded.definitions, [])
    }

    func testValidatorRejectsMalformedEvolutionAndClusterReferences() throws {
        let project = Project(id: "project_malformed", name: "Malformed")
        let invalidDelta = DictionaryDelta(
            deltaID: "delta_malformed",
            projectID: project.id,
            baseRevision: 0,
            targetRevision: 1,
            definitionsEvolved: [
                DefinitionEvolution(
                    definitionID: "def_missing",
                    changeType: "change",
                    changes: ["symbol": "old -> new"],
                    codeImpact: 1.1,
                    semanticImpact: 0,
                    milestone: false
                )
            ]
        )
        XCTAssertThrowsError(try DictionarySchemaValidator.validate(delta: invalidDelta))

        let definition = makeDefinition(projectID: project.id)
        let invalidCluster = Cluster(
            id: "cluster_invalid",
            projectID: project.id,
            name: "Invalid",
            definitionIDs: [definition.id, definition.id],
            primaryDefinitionID: definition.id,
            status: .pending
        )
        XCTAssertThrowsError(
            try DictionarySchemaValidator.validate(
                snapshot: ProjectSnapshot(project: project, definitions: [definition], clusters: [invalidCluster])
            )
        )
    }

    func testDeltaImportsOwnedFuzzyRelationReferenceAndSnapshotChanges() throws {
        let repository = InMemoryProjectRepository()
        let project = Project(id: "project_delta", name: "Delta Test")
        let source = makeDefinition(projectID: project.id)
        let target = Definition(
            id: "def_target",
            projectID: project.id,
            identity: DefinitionIdentity(canonicalName: "Target", displayName: "Target", kind: .service),
            function: FunctionDescriptor(domain: "testing", purpose: "target"),
            codeLocator: CodeLocator(symbol: "Target", file: "Target.swift"),
            visualLocator: VisualLocator(),
            functionalLocator: FunctionalLocator()
        )
        try repository.save(project: project)
        try repository.save(definition: source, in: project.id)
        try repository.save(definition: target, in: project.id)

        let relation = Relation(
            id: "relation_delta",
            type: .uses,
            sourceDefinitionID: source.id,
            targetDefinitionID: target.id
        )
        let snapshot = SnapshotMetadata(
            id: "snapshot_delta",
            file: "snapshots/snapshot_delta.jpg",
            width: 720,
            height: 480,
            sizeBytes: 40_000,
            perceptualHash: "0000000000000000",
            revision: 1
        )
        // An evolution that moves identity-bearing fields rides on an
        // approved identity Proposal carried inside the same delta.
        var identityProposal = GovernanceEngine.makeProposal(
            action: .identityChange,
            projectID: project.id,
            definitionIDs: [source.id],
            summary: "Apply the owned rename evolution"
        )
        identityProposal.status = .approved
        identityProposal.payload = [
            "canonical_name": "RenamedExchangeDefinition",
            "symbol": "RenamedExchangeView",
            "func": "performRenamedExchange()",
            "file": "Features/RenamedExchange.swift"
        ]
        let delta = DictionaryDelta(
            deltaID: "delta_owned_changes",
            projectID: project.id,
            baseRevision: 0,
            targetRevision: 1,
            definitionsEvolved: [
                DefinitionEvolution(
                    definitionID: source.id,
                    changeType: "implementation_change",
                    changes: [
                        "canonical_name": "ExchangeDefinition -> RenamedExchangeDefinition",
                        "symbol": "ExchangeView -> RenamedExchangeView",
                        "func": "performExchange() -> performRenamedExchange()",
                        "file": "Features/Exchange.swift -> Features/RenamedExchange.swift"
                    ],
                    codeImpact: 0.4,
                    semanticImpact: 0.2,
                    milestone: true
                )
            ],
            fuzzyTermsAdded: [
                FuzzyTermChange(
                    definitionID: source.id,
                    term: FuzzyTerm(id: "term_delta", text: "delta term", source: .user)
                )
            ],
            relationsChanged: [relation],
            referencesChanged: [
                DefinitionReferenceChange(
                    definitionID: source.id,
                    reference: Reference(id: "ref_delta", kind: "test", value: "fixture")
                )
            ],
            snapshotsChanged: [
                DefinitionSnapshotChange(definitionID: source.id, snapshot: snapshot)
            ],
            proposals: [identityProposal]
        )

        let result = try repository.apply(delta: delta, in: project.id)
        XCTAssertTrue(result.imported)
        let updated = try XCTUnwrap(repository.definition(id: source.id, in: project.id))
        XCTAssertEqual(updated.identity.canonicalName, "RenamedExchangeDefinition")
        XCTAssertTrue(updated.lineage.contains("ExchangeDefinition"))
        XCTAssertEqual(updated.fuzzyTerms.map(\.text), ["exchange", "delta term"])
        XCTAssertEqual(updated.codeLocator.symbol, "RenamedExchangeView")
        XCTAssertEqual(updated.codeLocator.function, "performRenamedExchange()")
        XCTAssertEqual(updated.codeLocator.file, "Features/RenamedExchange.swift")
        XCTAssertEqual(updated.implementationHistory.last?.changeType, "implementation_change")
        XCTAssertEqual(updated.relations.map(\.id), ["relation_delta"])
        XCTAssertEqual(updated.references.map(\.id), ["ref_delta"])
        XCTAssertEqual(updated.snapshots.map(\.id), ["snapshot_delta"])
        XCTAssertEqual(try repository.currentRevision(in: project.id), 1)
    }

    private func makeDefinition(projectID: String = "project_exchange") -> Definition {
        Definition(
            id: "def_exchange",
            projectID: projectID,
            identity: DefinitionIdentity(
                canonicalName: "ExchangeDefinition",
                displayName: "Exchange",
                kind: .component
            ),
            function: FunctionDescriptor(domain: "testing", purpose: "verify exchange", actions: ["encode"]),
            codeLocator: CodeLocator(
                symbol: "ExchangeView",
                symbolType: "class",
                function: "performExchange()",
                signature: "func performExchange()",
                owner: "ExchangeViewController",
                file: "Features/Exchange.swift",
                module: "funcDictionary",
                lineHint: 12
            ),
            visualLocator: VisualLocator(screen: "Exchange", container: "content", region: "center", hierarchy: ["Exchange"]),
            functionalLocator: FunctionalLocator(domain: "testing", role: "exchange", trigger: "test"),
            fuzzyTerms: [FuzzyTerm(text: "exchange", source: .user)]
        )
    }
}
