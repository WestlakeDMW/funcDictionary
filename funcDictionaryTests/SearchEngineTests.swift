import XCTest
@testable import funcDictionary

final class SearchEngineTests: XCTestCase {
    func testNormalizationRemovesCaseAndPunctuationNoise() {
        XCTAssertEqual(SearchNormalizer.normalize("  Project_ListViewController.swift  "), "project listviewcontroller swift")
        XCTAssertTrue(SearchNormalizer.tokens("项目 / 列表").starts(with: ["项目", "列表"]))
        XCTAssertGreaterThan(SearchNormalizer.similarity("colour", "color"), 0.7)
    }

    func testNaturalLanguageAndCJKNGramsSupportContiguousChineseMemory() {
        let tokens = SearchNormalizer.tokens("右上角那个同步的东西")
        XCTAssertTrue(tokens.starts(with: ["右上角", "那个", "同步", "的", "东西"]))
        XCTAssertTrue(tokens.contains("同"))
        XCTAssertTrue(tokens.contains("同步"))
        XCTAssertTrue(tokens.contains("东西"))
    }

    func testExactMultiFieldMatchBecomesDirectAndExplainsContributions() {
        let definition = makeDefinition(
            id: "def_checkout",
            name: "Checkout",
            fuzzyTerm: FuzzyTerm(text: "checkout", source: .user),
            oldName: nil
        )
        let response = SearchEngine().search(query: "checkout", definitions: [definition])

        XCTAssertEqual(response.direct?.definitionID, definition.id)
        XCTAssertGreaterThanOrEqual(response.direct?.score ?? 0, 0.72)
        XCTAssertTrue(response.direct?.reasons.contains(where: { $0.field == .fuzzy }) == true)
        XCTAssertEqual(response.direct?.currentSymbol, "CheckoutViewController")
        XCTAssertEqual(response.direct?.currentFunction, "render()")
    }

    func testUserFuzzyTermOutranksEquivalentAIGeneratedTerm() {
        let userDefinition = makeDefinition(
            id: "def_user",
            name: "Unrelated",
            fuzzyTerm: FuzzyTerm(text: "handoff", source: .user),
            oldName: nil
        )
        let aiDefinition = makeDefinition(
            id: "def_ai",
            name: "Unrelated Two",
            fuzzyTerm: FuzzyTerm(text: "handoff", source: .aiGenerated),
            oldName: nil
        )
        let response = SearchEngine().search(query: "handoff", definitions: [aiDefinition, userDefinition])

        XCTAssertEqual(response.candidates.first?.definitionID, userDefinition.id)
        XCTAssertGreaterThan(response.candidates.first?.score ?? 0, response.candidates.last?.score ?? 0)
    }

    func testExplicitFuzzyTermWeightParticipatesInRanking() {
        let highWeight = makeDefinition(
            id: "def_high_weight",
            name: "High Weight",
            fuzzyTerm: FuzzyTerm(text: "remembered action", source: .user, weight: 1.0),
            oldName: nil
        )
        let lowWeight = makeDefinition(
            id: "def_low_weight",
            name: "Low Weight",
            fuzzyTerm: FuzzyTerm(text: "remembered action", source: .user, weight: 0.5),
            oldName: nil
        )

        let response = SearchEngine().search(
            query: "remembered action",
            definitions: [lowWeight, highWeight]
        )

        XCTAssertEqual(response.candidates.first?.definitionID, highWeight.id)
        XCTAssertGreaterThan(response.candidates.first?.score ?? 0, response.candidates.last?.score ?? 0)
    }

    func testMixedProjectSearchIsRejectedInsteadOfLeakingVocabulary() {
        let first = makeDefinition(id: "def_project_a", name: "Project A", fuzzyTerm: FuzzyTerm(text: "private term", source: .user), oldName: nil)
        var second = makeDefinition(id: "def_project_b", name: "Project B", fuzzyTerm: nil, oldName: nil)
        second.projectID = "project_other"

        let response = SearchEngine().search(query: "private term", definitions: [first, second])

        XCTAssertNil(response.direct)
        XCTAssertTrue(response.candidates.isEmpty)
        XCTAssertTrue(response.related.isEmpty)
    }

    func testRelatedResultsDoNotInventNeighbors() {
        let direct = makeDefinition(
            id: "def_isolated_direct",
            name: "Isolated Direct",
            fuzzyTerm: FuzzyTerm(text: "isolated", source: .user),
            oldName: nil
        )
        let unrelated = makeDefinition(id: "def_unrelated", name: "Unrelated", fuzzyTerm: nil, oldName: nil)

        let response = SearchEngine().search(query: "isolated", definitions: [direct, unrelated])

        XCTAssertEqual(response.direct?.definitionID, direct.id)
        XCTAssertTrue(response.related.isEmpty)
    }

    func testPriorityCannotPushBelowCandidateThresholdIntoResults() {
        var definition = makeDefinition(id: "def_priority_threshold", name: "Priority", fuzzyTerm: nil, oldName: nil)
        definition.function.purpose = "query"
        definition.visualLocator.screen = "some query context"
        definition.humanPriority = HumanPriority(level: .critical, label: "Critical", note: "Should not create relevance")

        let response = SearchEngine().search(
            query: "query",
            definitions: [definition],
            clusters: []
        )

        XCTAssertTrue(response.candidates.isEmpty)
        XCTAssertNil(response.direct)
    }

    func testHistoricalMatchReturnsCurrentLocatorAndNeverClaimsDirectConfidence() {
        let definition = makeDefinition(
            id: "def_renamed",
            name: "Current Checkout",
            fuzzyTerm: FuzzyTerm(text: "checkout", source: .humanAdded),
            oldName: "Legacy Checkout"
        )
        let response = SearchEngine().search(query: "Legacy Checkout", definitions: [definition])

        XCTAssertNil(response.direct)
        XCTAssertEqual(response.candidates.first?.definitionID, definition.id)
        XCTAssertEqual(response.candidates.first?.currentSymbol, "CurrentCheckoutViewController")
        XCTAssertTrue(response.candidates.first?.reasons.contains(where: { $0.field == .history }) == true)
    }

    func testRelatedDefinitionsAreLimitedToFiveAndIncludeGraphNeighbors() {
        let neighbors = (0..<7).map { index in
            makeDefinition(id: "def_neighbor_\(index)", name: "Neighbor \(index)", fuzzyTerm: nil, oldName: nil)
        }
        var root = makeDefinition(id: "def_root", name: "Root", fuzzyTerm: FuzzyTerm(text: "Root", source: .user), oldName: nil)
        root.relations = neighbors.map {
            Relation(type: .uses, sourceDefinitionID: root.id, targetDefinitionID: $0.id)
        }
        let response = SearchEngine().search(query: "Root", definitions: [root] + neighbors)

        XCTAssertEqual(response.direct?.definitionID, root.id)
        XCTAssertEqual(response.related.count, 5)
        XCTAssertTrue(response.related.allSatisfy { $0.definitionID.hasPrefix("def_neighbor_") })
    }

    func testClusterQueryReturnsAnExplainableClusterResult() {
        let first = makeDefinition(id: "def_cluster_first", name: "Sync Action", fuzzyTerm: FuzzyTerm(text: "sync", source: .user), oldName: nil)
        let second = makeDefinition(id: "def_cluster_second", name: "Sync Status", fuzzyTerm: nil, oldName: nil)
        let cluster = Cluster(
            id: "cluster_sync",
            projectID: first.projectID,
            name: "Synchronization",
            definitionIDs: [first.id, second.id],
            primaryDefinitionID: first.id,
            status: .approved
        )

        let response = SearchEngine().search(
            query: "Synchronization",
            definitions: [first, second],
            clusters: [cluster]
        )

        XCTAssertEqual(response.clusters.first?.clusterID, cluster.id)
        XCTAssertEqual(response.clusters.first?.primaryDefinitionID, first.id)
        XCTAssertTrue(response.clusters.first?.reasons.first?.evidence.contains("Synchronization") == true)
    }

    private func makeDefinition(
        id: String,
        name: String,
        fuzzyTerm: FuzzyTerm?,
        oldName: String?
    ) -> Definition {
        var history: [ImplementationEvent] = []
        if let oldName {
            history = [
                ImplementationEvent(
                    revision: 1,
                    changeType: "rename",
                    changes: ["from": oldName, "to": name],
                    codeImpact: 0.3,
                    semanticImpact: 0.2,
                    milestone: true
                )
            ]
        }
        return Definition(
            id: id,
            projectID: "project_search",
            identity: DefinitionIdentity(canonicalName: name, displayName: name, kind: .controller),
            function: FunctionDescriptor(domain: name, purpose: "\(name) purpose", actions: ["render"]),
            codeLocator: CodeLocator(symbol: "\(name.replacingOccurrences(of: " ", with: ""))ViewController", function: "render()", file: "\(name).swift"),
            visualLocator: VisualLocator(screen: name, container: "Main", region: "Content"),
            functionalLocator: FunctionalLocator(domain: name, role: "Screen", trigger: "Tap"),
            fuzzyTerms: fuzzyTerm.map { [$0] } ?? [],
            implementationHistory: history
        )
    }
}
