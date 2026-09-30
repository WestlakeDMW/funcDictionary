import XCTest
@testable import funcDictionary

final class DictionaryEnginesTests: XCTestCase {
    func testCollectionScoreUsesDocumentedWeightedThreshold() {
        let score = CollectionScorer.score(
            evidence: CollectionEvidence(
                independentlyEditable: 1,
                independentlyLocatable: 0.8,
                functionalBoundary: 0.7,
                stableIdentity: 0.9,
                reusePotential: 0.6,
                explanation: "Independent component",
                evidence: ["has own locator"]
            )
        )

        XCTAssertEqual(score.total, 0.835, accuracy: 0.0001)
        XCTAssertTrue(score.shouldCreate)
        XCTAssertEqual(score.threshold, 0.70, accuracy: 0.0001)
    }

    func testChangeHeatUsesDecayedImpactAndProjectPercentile() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let high = makeDefinition(
            id: "def_high",
            name: "High",
            history: [
                ImplementationEvent(revision: 1, changeType: "large", codeImpact: 1, semanticImpact: 1, milestone: true, occurredAt: now)
            ]
        )
        let manySmall = makeDefinition(
            id: "def_many",
            name: "Many",
            history: (0..<10).map {
                ImplementationEvent(
                    revision: $0,
                    changeType: "small",
                    codeImpact: 0.01,
                    semanticImpact: 0.01,
                    milestone: false,
                    occurredAt: now
                )
            }
        )
        let highHeat = ChangeHeatEngine.calculate(for: high, in: [high, manySmall], now: now)
        let smallHeat = ChangeHeatEngine.calculate(for: manySmall, in: [high, manySmall], now: now)

        XCTAssertGreaterThan(highHeat.score, smallHeat.score)
        XCTAssertGreaterThan(highHeat.percentile, smallHeat.percentile)
        XCTAssertEqual(highHeat.eventCount, 1)
        XCTAssertEqual(smallHeat.eventCount, 10)
        XCTAssertTrue(highHeat.explanation.contains("not raw event count"))
    }

    func testChangeHeatUsesMedianPercentileForSingleDefinitionAndAverageRankForTies() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let one = makeDefinition(
            id: "def_one",
            name: "One",
            history: [ImplementationEvent(revision: 1, changeType: "work", codeImpact: 0.4, semanticImpact: 0.4, milestone: false, occurredAt: now)]
        )
        XCTAssertEqual(
            ChangeHeatEngine.calculate(for: one, in: [one], now: now).percentile,
            0.5,
            accuracy: 0.0001
        )

        let low = makeDefinition(
            id: "def_low",
            name: "Low",
            history: [ImplementationEvent(revision: 1, changeType: "work", codeImpact: 0.2, semanticImpact: 0.2, milestone: false, occurredAt: now)]
        )
        let tied = makeDefinition(
            id: "def_tied",
            name: "Tied",
            history: [ImplementationEvent(revision: 1, changeType: "work", codeImpact: 0.2, semanticImpact: 0.2, milestone: false, occurredAt: now)]
        )
        let high = makeDefinition(
            id: "def_high_tie",
            name: "High",
            history: [ImplementationEvent(revision: 1, changeType: "work", codeImpact: 0.8, semanticImpact: 0.8, milestone: false, occurredAt: now)]
        )
        let definitions = [low, tied, high]
        let lowHeat = ChangeHeatEngine.calculate(for: low, in: definitions, now: now)
        let tiedHeat = ChangeHeatEngine.calculate(for: tied, in: definitions, now: now)
        XCTAssertEqual(lowHeat.percentile, 0.5, accuracy: 0.0001)
        XCTAssertEqual(tiedHeat.percentile, lowHeat.percentile, accuracy: 0.0001)
        XCTAssertEqual(ChangeHeatEngine.calculate(for: high, in: definitions, now: now).percentile, 1.0, accuracy: 0.0001)
    }

    func testRelationGraphRejectsCrossProjectEdgesAndBuildsClusters() throws {
        var first = makeDefinition(id: "def_one", name: "One", history: [])
        let second = makeDefinition(id: "def_two", name: "Two", history: [])
        first.relations = [Relation(type: .uses, sourceDefinitionID: first.id, targetDefinitionID: second.id)]

        let graph = try RelationGraph(definitions: [first, second])
        XCTAssertEqual(graph.neighbors(of: first.id).map(\.id), [second.id])
        XCTAssertEqual(graph.clusters().count, 1)
        XCTAssertEqual(graph.clusters().first?.primaryDefinitionID, first.id)

        var otherProject = second
        otherProject.projectID = "project_other"
        XCTAssertThrowsError(try RelationGraph(definitions: [first, otherProject])) { error in
            XCTAssertEqual(error as? RelationGraphError, .mixedProjects)
        }
    }

    func testCriticalProtectionPropagatesByDepthAndRespectsZeroDepth() throws {
        var critical = makeDefinition(id: "def_critical", name: "Critical", history: [])
        critical.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "Core contract")
        var related = makeDefinition(id: "def_related", name: "Related", history: [])
        let distant = makeDefinition(id: "def_distant", name: "Distant", history: [])
        critical.relations = [Relation(type: .uses, sourceDefinitionID: critical.id, targetDefinitionID: related.id)]
        related.relations = [Relation(type: .uses, sourceDefinitionID: related.id, targetDefinitionID: distant.id)]

        let evaluation = try ProtectionEngine.evaluate(
            definitions: [critical, related, distant],
            configuration: ScoringConfiguration(protectionMaxDepth: 2)
        )
        XCTAssertEqual(Set(evaluation.protectedDefinitionIDs), Set([critical.id, related.id, distant.id]))
        XCTAssertEqual(evaluation.propagationScores[critical.id], 1.0)
        XCTAssertEqual(evaluation.propagationScores[distant.id] ?? -1, 0.81, accuracy: 0.0001)
        XCTAssertTrue(evaluation.propagationReasons[distant.id]?.contains("score 0.81") == true)
        XCTAssertFalse(ProtectionEngine.requiresChangeRequest(
            definitionID: related.id,
            evaluation: evaluation,
            impact: ImpactDimensions(visual: 0.1)
        ))
        XCTAssertTrue(ProtectionEngine.requiresChangeRequest(
            definitionID: related.id,
            evaluation: evaluation,
            impact: ImpactDimensions(structure: 0.6)
        ))

        let zeroDepth = try ProtectionEngine.evaluate(
            definitions: [critical, related, distant],
            configuration: ScoringConfiguration(protectionMaxDepth: 0)
        )
        XCTAssertEqual(zeroDepth.protectedDefinitionIDs, [critical.id])
    }

    func testRenamePreservesStableIdentityAndProtectedRenameCreatesChangeRequest() {
        var definition = makeDefinition(id: "def_rename", name: "Old Name", history: [])
        let plan = DefinitionEvolutionEngine.planRename(
            definition: definition,
            canonicalName: "NewName",
            displayName: "New Name",
            symbol: "NewSymbol"
        )
        XCTAssertEqual(plan.updatedDefinition.id, definition.id)
        XCTAssertEqual(plan.updatedDefinition.identity.canonicalName, "NewName")
        XCTAssertTrue(plan.updatedDefinition.lineage.contains("Old Name"))
        XCTAssertFalse(plan.requiresHumanApproval)
        XCTAssertEqual(plan.evolution.definitionID, definition.id)

        definition.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "Protected")
        let protectedPlan = DefinitionEvolutionEngine.planRename(
            definition: definition,
            canonicalName: "ProtectedNew",
            displayName: "Protected New"
        )
        XCTAssertTrue(protectedPlan.requiresHumanApproval)
        XCTAssertEqual(protectedPlan.changeRequest?.status, .pending)
        XCTAssertEqual(protectedPlan.changeRequest?.definitionID, definition.id)
    }

    func testGovernanceProposalAndChangeRequestDecisionsAreExplicit() {
        let proposal = GovernanceEngine.makeProposal(
            action: .split,
            projectID: "project_governance",
            definitionIDs: ["def_a", "def_b"],
            summary: "Split two unrelated responsibilities"
        )
        XCTAssertEqual(GovernanceEngine.decide(proposal, approved: true).status, .approved)
        XCTAssertEqual(GovernanceEngine.decide(proposal, approved: false).status, .rejected)

        let definition = makeDefinition(id: "def_governance", name: "Governance", history: [])
        let request = GovernanceEngine.makeChangeRequest(
            definition: definition,
            requestedChange: RequestedChange(type: "structure", summary: "Change hierarchy"),
            reason: "A protected surface changed",
            risk: "May affect related definitions",
            relatedDefinitionIDs: ["def_related"]
        )
        XCTAssertEqual(request.affectedDefinitionIDs, ["def_governance", "def_related"])
        XCTAssertEqual(GovernanceEngine.decide(request, approved: true).status, .approved)
    }

    func testApprovedSplitCreatesNewIDsAndPreservesSourceLineage() throws {
        let source = makeDefinition(id: "def_source", name: "Source", history: [])
        let proposal = Proposal(
            id: "proposal_split_source",
            projectID: source.projectID,
            action: .split,
            definitionIDs: [source.id],
            status: .approved,
            summary: "Split source",
            payload: ["new_definition_ids": "def_part_a, def_part_b"]
        )

        let application = try GovernanceEngine.applyApproved(proposal, to: [source])
        XCTAssertEqual(application.updatedDefinitions.map(\.id), [source.id, "def_part_a", "def_part_b"])
        XCTAssertEqual(application.updatedDefinitions.first?.reviewStatus, .split)
        XCTAssertTrue(application.updatedDefinitions.first?.lineage.contains("def_part_a") == true)
        XCTAssertEqual(application.updatedDefinitions[1].lineage, [source.id])
        XCTAssertEqual(application.updatedDefinitions[1].identity.canonicalName, "Source.part_a")
        XCTAssertEqual(application.updatedDefinitions[1].identity.displayName, "Source Part 1")
        XCTAssertEqual(application.updatedDefinitions[1].codeLocator.symbol, "SourceSymbol_1")
    }

    func testApprovedClusterCreatesFormalClusterWithPrimary() throws {
        let first = makeDefinition(id: "def_first", name: "First", history: [])
        let second = makeDefinition(id: "def_second", name: "Second", history: [])
        let proposal = Proposal(
            id: "proposal_cluster_pair",
            projectID: first.projectID,
            action: .cluster,
            definitionIDs: [first.id, second.id],
            status: .approved,
            summary: "Group related definitions",
            payload: [
                "name": "Pair",
                "primary_definition_id": first.id
            ]
        )

        let application = try GovernanceEngine.applyApproved(proposal, to: [first, second])
        XCTAssertEqual(application.cluster?.status, .approved)
        XCTAssertEqual(application.cluster?.primaryDefinitionID, first.id)
        XCTAssertEqual(application.cluster?.definitionIDs, [first.id, second.id])
        XCTAssertEqual(application.cluster?.id, "cluster_proposal_cluster_pair")
    }

    func testPendingProposalCannotBeApplied() {
        let definition = makeDefinition(id: "def_pending", name: "Pending", history: [])
        let proposal = GovernanceEngine.makeProposal(
            action: .deprecated,
            projectID: definition.projectID,
            definitionIDs: [definition.id],
            summary: "Deprecate pending"
        )

        XCTAssertThrowsError(try GovernanceEngine.applyApproved(proposal, to: [definition])) { error in
            XCTAssertEqual(error as? GovernanceEngine.ProposalApplicationError, .decisionRequired)
        }
    }

    func testLifecycleEngineCoversAllEightMVPStates() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cases: [(LifecycleState, Definition)] = [
            (.experimental, makeDefinition(id: "def_experimental", name: "Experimental", history: [])),
            (.active, makeDefinition(
                id: "def_active",
                name: "Active",
                history: [ImplementationEvent(revision: 1, changeType: "work", codeImpact: 0.5, semanticImpact: 0.5, milestone: false, occurredAt: now)]
            )),
            (.evolving, makeDefinition(
                id: "def_evolving",
                name: "Evolving",
                history: [ImplementationEvent(revision: 1, changeType: "work", codeImpact: 0.8, semanticImpact: 0.8, milestone: false, occurredAt: now)]
            )),
            (.stabilizing, makeDefinition(
                id: "def_stabilizing",
                name: "Stabilizing",
                history: [ImplementationEvent(revision: 1, changeType: "work", codeImpact: 0.1, semanticImpact: 0.1, milestone: false, occurredAt: now)]
            )),
            (.stable, makeDefinition(
                id: "def_stable",
                name: "Stable",
                history: (0..<3).map { index in
                    ImplementationEvent(revision: index, changeType: "work", codeImpact: 0.05, semanticImpact: 0.05, milestone: false, occurredAt: now)
                }
            )),
            (.activeCore, makeCoreDefinition(
                id: "def_active_core",
                name: "Active Core",
                history: [ImplementationEvent(revision: 1, changeType: "work", codeImpact: 0.45, semanticImpact: 0.45, milestone: false, occurredAt: now)]
            )),
            (.evolvingCore, makeCoreDefinition(
                id: "def_evolving_core",
                name: "Evolving Core",
                history: [ImplementationEvent(revision: 1, changeType: "work", codeImpact: 0.8, semanticImpact: 0.8, milestone: false, occurredAt: now)]
            )),
            (.stableCore, makeCoreDefinition(
                id: "def_stable_core",
                name: "Stable Core",
                history: (0..<3).map { index in
                    ImplementationEvent(revision: index, changeType: "work", codeImpact: 0.05, semanticImpact: 0.05, milestone: false, occurredAt: now)
                },
                approved: true,
                milestone: true
            ))
        ]

        var adjustedCases = cases
        adjustedCases[3].1.reviewStatus = .approved
        adjustedCases[4].1.reviewStatus = .approved

        for (expected, definition) in adjustedCases {
            let evaluation = LifecycleEngine.evaluate(
                definition: definition,
                in: [definition],
                now: now
            )
            XCTAssertEqual(evaluation.state, expected, "Expected \(expected.rawValue) for \(definition.id)")
            XCTAssertFalse(evaluation.matchedRules.isEmpty)
        }
    }

    private func makeDefinition(id: String, name: String, history: [ImplementationEvent]) -> Definition {
        Definition(
            id: id,
            projectID: "project_engines",
            identity: DefinitionIdentity(canonicalName: name, displayName: name, kind: .component),
            function: FunctionDescriptor(domain: "Domain", purpose: "\(name) purpose"),
            codeLocator: CodeLocator(symbol: "\(name)Symbol", function: "run()", file: "\(name).swift"),
            visualLocator: VisualLocator(screen: name),
            functionalLocator: FunctionalLocator(domain: "Domain", role: name, trigger: "Tap"),
            implementationHistory: history
        )
    }

    private func makeCoreDefinition(
        id: String,
        name: String,
        history: [ImplementationEvent],
        approved: Bool = false,
        milestone: Bool = false
    ) -> Definition {
        var definition = makeDefinition(id: id, name: name, history: history)
        definition.relations = (0..<2).map { index in
            Relation(
                type: .uses,
                sourceDefinitionID: definition.id,
                targetDefinitionID: "def_core_neighbor_\(index)"
            )
        }
        if approved { definition.reviewStatus = .approved }
        if milestone {
            definition.snapshots = [
                SnapshotMetadata(
                    id: "snapshot_\(id)",
                    file: "snapshots/snapshot_\(id).jpg",
                    width: 720,
                    height: 480,
                    sizeBytes: 1,
                    perceptualHash: "0",
                    revision: 1,
                    milestone: true
                )
            ]
        }
        return definition
    }
}
