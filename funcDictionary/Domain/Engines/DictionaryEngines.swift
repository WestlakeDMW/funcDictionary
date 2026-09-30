import Foundation

public struct CollectionEvidence: Codable, Equatable, Sendable {
    public var independentlyEditable: Double
    public var independentlyLocatable: Double
    public var functionalBoundary: Double
    public var stableIdentity: Double
    public var reusePotential: Double
    public var explanation: String
    public var evidence: [String]

    public init(
        independentlyEditable: Double,
        independentlyLocatable: Double,
        functionalBoundary: Double,
        stableIdentity: Double,
        reusePotential: Double,
        explanation: String,
        evidence: [String]
    ) {
        self.independentlyEditable = independentlyEditable
        self.independentlyLocatable = independentlyLocatable
        self.functionalBoundary = functionalBoundary
        self.stableIdentity = stableIdentity
        self.reusePotential = reusePotential
        self.explanation = explanation
        self.evidence = evidence
    }
}

public enum CollectionScorer {
    public static func score(
        evidence: CollectionEvidence,
        configuration: ScoringConfiguration = ScoringConfiguration()
    ) -> CollectionScore {
        let score = CollectionScore(
            independentlyEditable: clamp(evidence.independentlyEditable),
            independentlyLocatable: clamp(evidence.independentlyLocatable),
            functionalBoundary: clamp(evidence.functionalBoundary),
            stableIdentity: clamp(evidence.stableIdentity),
            reusePotential: clamp(evidence.reusePotential),
            threshold: configuration.collectionThreshold,
            shouldCreate: false,
            explanation: evidence.explanation,
            evidence: evidence.evidence
        )
        var result = score
        result.shouldCreate = score.total >= configuration.collectionThreshold
        return result
    }

    private static func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
}

public enum DefinitionActivityEngine {
    public static func activity(
        for definition: Definition,
        now: Date = Date(),
        halfLifeDays: Double = 30
    ) -> Double {
        guard halfLifeDays > 0 else { return 0 }
        let halfLife = halfLifeDays * 86_400
        return min(
            1,
            definition.implementationHistory.reduce(0) { total, event in
                let age = max(0, now.timeIntervalSince(event.occurredAt))
                let decay = pow(0.5, age / halfLife)
                let impact = event.milestone ? 1 : max(event.codeImpact, event.semanticImpact)
                return total + decay * max(impact, 0.15)
            }
        )
    }
}

public enum ChangeHeatEngine {
    public static func calculate(
        for definition: Definition,
        in projectDefinitions: [Definition],
        now: Date = Date(),
        halfLifeDays: Double = 30
    ) -> ChangeHeatResult {
        let scopedDefinitions = projectDefinitions.filter { $0.projectID == definition.projectID }
        let distribution = scopedDefinitions.isEmpty ? [definition] : scopedDefinitions
        let scores = distribution.map {
            weightedImpact(for: $0, now: now, halfLifeDays: halfLifeDays)
        }
        let score = weightedImpact(for: definition, now: now, halfLifeDays: halfLifeDays)
        let percentile: Double
        if scores.isEmpty {
            percentile = 0
        } else if scores.count == 1 {
            // A one-item project is the median of its own distribution.
            percentile = 0.5
        } else {
            // Use the average rank for ties so equal heat values receive the
            // same percentile and the result does not depend on array order.
            let lowerCount = scores.filter { $0 < score }.count
            let equalCount = scores.filter { $0 == score }.count
            let averageRank = Double(lowerCount) + Double(equalCount + 1) / 2
            percentile = averageRank / Double(scores.count)
        }
        let explanation = definition.implementationHistory.isEmpty
            ? "No implementation history recorded."
            : "Project percentile \(Int(percentile * 100)) from decayed implementation impact, not raw event count."
        return ChangeHeatResult(
            score: min(max(score, 0), 1),
            percentile: min(max(percentile, 0), 1),
            eventCount: definition.implementationHistory.count,
            explanation: explanation,
            calculatedAt: now
        )
    }

    private static func weightedImpact(for definition: Definition, now: Date, halfLifeDays: Double) -> Double {
        guard halfLifeDays > 0 else { return 0 }
        let halfLife = halfLifeDays * 86_400
        let total = definition.implementationHistory.reduce(0) { total, event in
            let age = max(0, now.timeIntervalSince(event.occurredAt))
            let decay = pow(0.5, age / halfLife)
            let impact = event.milestone ? 1 : (event.codeImpact * 0.55 + event.semanticImpact * 0.45)
            return total + decay * min(max(impact, 0), 1)
        }
        return min(total, 1)
    }
}

public enum LifecycleEngine {
    public static func evaluate(
        definition: Definition,
        in projectDefinitions: [Definition],
        now: Date = Date(),
        configuration: ScoringConfiguration = ScoringConfiguration()
    ) -> LifecycleEvaluation {
        let scopedDefinitions = projectDefinitions.filter { $0.projectID == definition.projectID }
        let distribution = scopedDefinitions.isEmpty ? [definition] : scopedDefinitions
        let activity = DefinitionActivityEngine.activity(
            for: definition,
            now: now,
            halfLifeDays: configuration.changeHeatHalfLifeDays
        )
        let heat = ChangeHeatEngine.calculate(
            for: definition,
            in: projectDefinitions,
            now: now,
            halfLifeDays: configuration.changeHeatHalfLifeDays
        )
        let maximumDegree = max(
            1,
            distribution.map { $0.relations.count }.max() ?? 1
        )
        let centrality = min(1, Double(definition.relations.count) / Double(maximumDegree))
        let stability = min(1, max(0, 1 - heat.score))
        let maturity = min(
            1,
            (definition.reviewStatus == .approved ? 0.35 : 0)
                + (definition.implementationHistory.count >= 3 ? 0.35 : Double(definition.implementationHistory.count) * 0.10)
                + (definition.snapshots.contains(where: \.milestone) ? 0.30 : 0)
        )

        let state: LifecycleState
        let rule: String
        if centrality >= 0.65, stability >= 0.75, maturity >= 0.80 {
            state = .stableCore
            rule = "high centrality + stable + mature"
        } else if centrality >= 0.65, activity >= 0.50, stability < 0.60 {
            state = .evolvingCore
            rule = "high centrality + active change"
        } else if centrality >= 0.65, activity >= 0.45 {
            state = .activeCore
            rule = "high centrality + active"
        } else if activity >= 0.65, stability < 0.65 {
            state = .evolving
            rule = "high decayed activity + low stability"
        } else if activity >= 0.45, maturity < 0.55 {
            state = .active
            rule = "active + not mature"
        } else if stability >= 0.75, maturity >= 0.65 {
            state = .stable
            rule = "stable + mature"
        } else if maturity >= 0.35 {
            state = .stabilizing
            rule = "maturity is forming"
        } else {
            state = .experimental
            rule = "insufficient history or maturity"
        }
        return LifecycleEvaluation(
            state: state,
            activity: activity,
            centrality: centrality,
            stability: stability,
            maturity: maturity,
            matchedRules: [rule],
            calculatedAt: now
        )
    }
}

public struct RelationGraph: Sendable {
    public let definitionsByID: [String: Definition]
    public let adjacency: [String: Set<String>]

    public init(definitions: [Definition]) throws {
        let projectIDs = Set(definitions.map(\.projectID))
        guard projectIDs.count <= 1 else {
            throw RelationGraphError.mixedProjects
        }
        var map: [String: Definition] = [:]
        for definition in definitions {
            guard map[definition.id] == nil else { throw RelationGraphError.duplicateDefinitionID(definition.id) }
            map[definition.id] = definition
        }
        var graph = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, Set<String>()) })
        for definition in definitions {
            for relation in definition.relations {
                guard relation.sourceDefinitionID == definition.id else {
                    throw RelationGraphError.relationOwnership(definition.id, relation.id)
                }
                guard let source = map[relation.sourceDefinitionID], let target = map[relation.targetDefinitionID] else {
                    throw RelationGraphError.missingDefinition(relation.sourceDefinitionID, relation.targetDefinitionID)
                }
                guard source.projectID == target.projectID else { throw RelationGraphError.crossProjectRelation }
                graph[relation.sourceDefinitionID, default: []].insert(relation.targetDefinitionID)
                graph[relation.targetDefinitionID, default: []].insert(relation.sourceDefinitionID)
            }
        }
        self.definitionsByID = map
        self.adjacency = graph
    }

    public func neighbors(of definitionID: String) -> [Definition] {
        (adjacency[definitionID] ?? []).compactMap { definitionsByID[$0] }
            .sorted { $0.identity.canonicalName < $1.identity.canonicalName }
    }

    public func centrality(of definitionID: String) -> Double {
        let maximum = max(1, adjacency.values.map(\.count).max() ?? 1)
        return Double(adjacency[definitionID]?.count ?? 0) / Double(maximum)
    }

    public func clusters() -> [Cluster] {
        var visited: Set<String> = []
        var result: [Cluster] = []
        for definitionID in definitionsByID.keys.sorted() where !visited.contains(definitionID) {
            var component: [String] = []
            var queue = [definitionID]
            while let next = queue.popLast() {
                guard visited.insert(next).inserted else { continue }
                component.append(next)
                queue.append(contentsOf: adjacency[next] ?? [])
            }
            guard component.count > 1, let first = definitionsByID[component[0]] else { continue }
            let primary = component.max { centrality(of: $0) < centrality(of: $1) } ?? first.id
            result.append(
                Cluster(
                    id: "cluster_\(first.projectID)_\(component.sorted().joined(separator: "_"))",
                    projectID: first.projectID,
                    name: component.compactMap { definitionsByID[$0]?.identity.displayName }.joined(separator: " · "),
                    definitionIDs: component.sorted(),
                    primaryDefinitionID: primary,
                    // A graph component is only a candidate. Persisting it as
                    // approved would bypass the PRD's Proposal gate for
                    // formal Cluster creation.
                    status: .pending
                )
            )
        }
        return result.sorted { $0.name < $1.name }
    }
}

public enum RelationGraphError: Error, Equatable, LocalizedError, Sendable {
    case missingDefinition(String, String)
    case crossProjectRelation
    case duplicateDefinitionID(String)
    case mixedProjects
    case relationOwnership(String, String)

    public var errorDescription: String? {
        switch self {
        case .missingDefinition(let source, let target): "Relation points to missing definitions: \(source), \(target)."
        case .crossProjectRelation: "Relations cannot cross project boundaries."
        case .duplicateDefinitionID(let id): "Duplicate definition ID in graph: \(id)."
        case .mixedProjects: "A relation graph must contain one project at a time."
        case .relationOwnership(let definitionID, let relationID): "Relation \(relationID) is not owned by definition \(definitionID)."
        }
    }
}

public struct ProtectionEvaluation: Codable, Equatable, Sendable {
    public var rootDefinitionIDs: [String]
    public var protectedDefinitionIDs: [String]
    public var propagationReasons: [String: String]
    public var propagationScores: [String: Double]

    public init(
        rootDefinitionIDs: [String],
        protectedDefinitionIDs: [String],
        propagationReasons: [String: String],
        propagationScores: [String: Double] = [:]
    ) {
        self.rootDefinitionIDs = rootDefinitionIDs
        self.protectedDefinitionIDs = protectedDefinitionIDs
        self.propagationReasons = propagationReasons
        self.propagationScores = propagationScores
    }
}

public enum ProtectionEngine {
    public static func evaluate(
        definitions: [Definition],
        configuration: ScoringConfiguration = ScoringConfiguration(),
        impactByDefinitionID: [String: ImpactDimensions] = [:]
    ) throws -> ProtectionEvaluation {
        let graph = try RelationGraph(definitions: definitions)
        let roots = definitions.filter { $0.humanPriority?.level == .critical }.map(\.id).sorted()
        var protectedIDs = Set(roots)
        var reasons = Dictionary(uniqueKeysWithValues: roots.map { ($0, "critical human priority") })
        var scores = Dictionary(uniqueKeysWithValues: roots.map { ($0, 1.0) })
        var edges: [String: [(neighborID: String, type: RelationType)]] = [:]
        for definition in definitions {
            for relation in definition.relations {
                edges[relation.sourceDefinitionID, default: []].append((relation.targetDefinitionID, relation.type))
                edges[relation.targetDefinitionID, default: []].append((relation.sourceDefinitionID, relation.type))
            }
        }
        var frontier = roots
        if configuration.protectionMaxDepth > 0 {
            for depth in 1...configuration.protectionMaxDepth {
                var next: [String] = []
                for current in frontier {
                    let currentScore = scores[current] ?? 1
                    for edge in edges[current] ?? [] {
                        let neighbor = edge.neighborID
                        guard graph.adjacency[current]?.contains(neighbor) == true else { continue }
                        let impact = impactByDefinitionID[neighbor] ?? ImpactDimensions(structure: 1)
                        let maximumImpact = ImpactDimension.allCases.map { impact.value(for: $0) }.max() ?? 0
                        let candidateScore = currentScore * propagationCoefficient(for: edge.type) * maximumImpact
                        guard candidateScore >= configuration.criticalPropagationThreshold else { continue }
                        guard candidateScore > (scores[neighbor] ?? 0) else { continue }
                        scores[neighbor] = candidateScore
                        protectedIDs.insert(neighbor)
                        let scoreText = String(format: "%.2f", candidateScore)
                        reasons[neighbor] = "related to critical definition \(current), depth \(depth), score \(scoreText)"
                        next.append(neighbor)
                    }
                }
                frontier = next
                if frontier.isEmpty { break }
            }
        }
        return ProtectionEvaluation(
            rootDefinitionIDs: roots,
            protectedDefinitionIDs: protectedIDs.sorted(),
            propagationReasons: reasons,
            propagationScores: scores
        )
    }

    private static func propagationCoefficient(for relationType: RelationType) -> Double {
        switch relationType {
        case .contains: 1.0
        case .calls: 0.90
        case .uses: 0.90
        case .dependsOn: 0.85
        case .triggers: 0.80
        case .displays: 0.75
        case .owns: 0.90
        case .produces: 0.80
        case .reads: 0.70
        case .writes: 0.80
        }
    }

    public static func requiresChangeRequest(
        definitionID: String,
        evaluation: ProtectionEvaluation,
        impact: ImpactDimensions,
        configuration: ScoringConfiguration = ScoringConfiguration()
    ) -> Bool {
        guard evaluation.protectedDefinitionIDs.contains(definitionID) else { return false }
        let maximumImpact = ImpactDimension.allCases.map { impact.value(for: $0) }.max() ?? 0
        return maximumImpact >= configuration.criticalPropagationThreshold
    }
}

public struct EvolutionPlan: Codable, Equatable, Sendable {
    public var updatedDefinition: Definition
    public var evolution: DefinitionEvolution
    public var proposal: Proposal?
    public var changeRequest: ChangeRequest?

    public var requiresHumanApproval: Bool { proposal != nil || changeRequest != nil }

    public init(
        updatedDefinition: Definition,
        evolution: DefinitionEvolution,
        proposal: Proposal?,
        changeRequest: ChangeRequest?
    ) {
        self.updatedDefinition = updatedDefinition
        self.evolution = evolution
        self.proposal = proposal
        self.changeRequest = changeRequest
    }
}

public enum DefinitionEvolutionEngine {
    public static func planRename(
        definition: Definition,
        canonicalName: String,
        displayName: String,
        symbol: String? = nil,
        reason: String = "Rename requested"
    ) -> EvolutionPlan {
        var updated = definition
        let oldName = definition.identity.canonicalName
        updated.identity = DefinitionIdentity(canonicalName: canonicalName, displayName: displayName, kind: definition.identity.kind)
        if let symbol { updated.codeLocator.symbol = symbol }
        updated.lineage = Array(Set(definition.lineage + [oldName])).sorted()
        updated.updatedAt = Date()
        var changes = [
            "canonical_name": "\(oldName) -> \(canonicalName)",
            "display_name": "\(definition.identity.displayName) -> \(displayName)"
        ]
        if let symbol {
            changes["symbol"] = "\(definition.codeLocator.symbol) -> \(symbol)"
        }
        let evolution = DefinitionEvolution(
            definitionID: definition.id,
            changeType: "rename",
            changes: changes,
            codeImpact: symbol == nil ? 0.25 : 0.55,
            semanticImpact: 0.35,
            milestone: false
        )
        let request = definition.isProtected
            ? ChangeRequest(
                id: "cr_\(definition.id)_rename",
                projectID: definition.projectID,
                definitionID: definition.id,
                requestedChange: RequestedChange(type: "rename", summary: reason),
                reason: reason,
                risk: "Protected definition identity or locator change.",
                affectedDefinitionIDs: [definition.id],
                proposedValues: RepositoryWritePolicy.protectedChangePayload(for: updated)
            )
            : nil
        return EvolutionPlan(updatedDefinition: updated, evolution: evolution, proposal: nil, changeRequest: request)
    }

    public static func planIdentityChange(
        definitionIDs: [String],
        projectID: String,
        summary: String
    ) -> Proposal {
        Proposal(
            id: "proposal_identity_\(definitionIDs.sorted().joined(separator: "_"))",
            projectID: projectID,
            action: .identityChange,
            definitionIDs: definitionIDs,
            summary: summary,
            payload: ["requiresHumanReview": "true"]
        )
    }
}

public enum GovernanceEngine {
    public struct ProposalApplication: Equatable, Sendable {
        public var updatedDefinitions: [Definition]
        public var cluster: Cluster?

        public init(updatedDefinitions: [Definition] = [], cluster: Cluster? = nil) {
            self.updatedDefinitions = updatedDefinitions
            self.cluster = cluster
        }
    }

    public enum ProposalApplicationError: Error, Equatable, LocalizedError, Sendable {
        case decisionRequired
        case definitionNotFound(String)
        case invalidProject
        case invalidPayload(String)
        case duplicateDefinitionID(String)

        public var errorDescription: String? {
            switch self {
            case .decisionRequired:
                "A proposal must be approved or adjusted before it can be applied."
            case .definitionNotFound(let id):
                "Proposal references a missing definition: \(id)."
            case .invalidProject:
                "All proposal definitions must belong to the same project."
            case .invalidPayload(let key):
                "Proposal payload is missing or invalid: \(key)."
            case .duplicateDefinitionID(let id):
                "Proposal would create a duplicate definition ID: \(id)."
            }
        }
    }

    /// Interactive submissions pass `uniqueSubmissionID: true` so every
    /// edit creates its own ledger record. Deterministic IDs would let a
    /// later edit overwrite an already-approved (or rejected) record and
    /// erase that decision from the governance history.
    public static func makeProposal(
        action: ProposalAction,
        projectID: String,
        definitionIDs: [String],
        summary: String,
        uniqueSubmissionID: Bool = false
    ) -> Proposal {
        let baseID = "proposal_\(action.rawValue)_\(definitionIDs.sorted().joined(separator: "_"))"
        return Proposal(
            id: uniqueSubmissionID ? "\(baseID)_\(UUID().uuidString)" : baseID,
            projectID: projectID,
            action: action,
            definitionIDs: definitionIDs,
            summary: summary,
            payload: ["requiresHumanReview": "true"]
        )
    }

    public static func makeChangeRequest(
        definition: Definition,
        requestedChange: RequestedChange,
        reason: String,
        risk: String,
        relatedDefinitionIDs: [String] = [],
        proposedValues: [String: String] = [:],
        uniqueSubmissionID: Bool = false
    ) -> ChangeRequest {
        let affected = Array(Set([definition.id] + relatedDefinitionIDs)).sorted()
        let baseID = "cr_\(definition.id)_\(requestedChange.type)"
        return ChangeRequest(
            id: uniqueSubmissionID ? "\(baseID)_\(UUID().uuidString)" : baseID,
            projectID: definition.projectID,
            definitionID: definition.id,
            requestedChange: requestedChange,
            reason: reason,
            risk: risk,
            affectedDefinitionIDs: affected,
            proposedValues: proposedValues
        )
    }

    public static func decide(_ proposal: Proposal, approved: Bool) -> Proposal {
        var result = proposal
        result.status = approved ? .approved : .rejected
        return result
    }

    public static func adjust(_ proposal: Proposal, summary: String) -> Proposal {
        var result = proposal
        result.status = .adjusted
        result.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? proposal.summary
            : summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    /// Applies only the data-bearing portion of an already human-approved
    /// proposal. The caller remains responsible for persisting the returned
    /// values as one repository transaction.
    public static func applyApproved(
        _ proposal: Proposal,
        to definitions: [Definition],
        now: Date = Date()
    ) throws -> ProposalApplication {
        guard proposal.status == .approved || proposal.status == .adjusted else {
            throw ProposalApplicationError.decisionRequired
        }
        guard !definitions.isEmpty else {
            throw ProposalApplicationError.definitionNotFound(proposal.definitionIDs.first ?? "")
        }
        guard definitions.allSatisfy({ $0.projectID == proposal.projectID }) else {
            throw ProposalApplicationError.invalidProject
        }
        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        for definitionID in proposal.definitionIDs {
            guard byID[definitionID] != nil else {
                throw ProposalApplicationError.definitionNotFound(definitionID)
            }
        }

        switch proposal.action {
        case .deprecated:
            return ProposalApplication(updatedDefinitions: definitions.map { definition in
                guard proposal.definitionIDs.contains(definition.id) else { return definition }
                var updated = definition
                updated.reviewStatus = .deprecated
                updated.updatedAt = now
                return updated
            })
        case .identityChange:
            guard let firstID = proposal.definitionIDs.first,
                  var updated = byID[firstID] else {
                throw ProposalApplicationError.definitionNotFound(proposal.definitionIDs.first ?? "")
            }
            let canonicalName = proposal.payload["canonical_name"] ?? updated.identity.canonicalName
            let displayName = proposal.payload["display_name"] ?? updated.identity.displayName
            guard !canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProposalApplicationError.invalidPayload("canonical_name")
            }
            updated.identity = DefinitionIdentity(
                canonicalName: canonicalName,
                displayName: displayName,
                kind: proposal.payload["kind"].flatMap { DefinitionKind(rawValue: $0) } ?? updated.identity.kind
            )
            if let symbol = proposal.payload["symbol"] { updated.codeLocator.symbol = symbol }
            if let function = proposal.payload["func"] { updated.codeLocator.function = function }
            if let file = proposal.payload["file"] { updated.codeLocator.file = file }
            if let domain = proposal.payload["domain"] { updated.function.domain = domain }
            if let purpose = proposal.payload["purpose"] { updated.function.purpose = purpose }
            // Only record lineage when the canonical name actually moves;
            // re-applying an already applied proposal must stay a no-op
            // instead of appending the name to its own lineage.
            if canonicalName != byID[firstID]?.identity.canonicalName {
                updated.lineage = Array(Set(updated.lineage + [byID[firstID]?.identity.canonicalName ?? ""])).filter { !$0.isEmpty }.sorted()
            }
            updated.updatedAt = now
            return ProposalApplication(updatedDefinitions: [updated])
        case .merge:
            guard proposal.definitionIDs.count >= 2,
                  let firstDefinitionID = proposal.definitionIDs.sorted().first else {
                throw ProposalApplicationError.invalidPayload("definition_ids")
            }
            let primaryID = proposal.payload["primary_definition_id"] ?? firstDefinitionID
            guard byID[primaryID] != nil else {
                throw ProposalApplicationError.definitionNotFound(primaryID)
            }
            return ProposalApplication(updatedDefinitions: definitions.map { definition in
                guard proposal.definitionIDs.contains(definition.id) else { return definition }
                var updated = definition
                if definition.id == primaryID {
                    let mergedIDs = proposal.definitionIDs.filter { $0 != primaryID }
                    updated.lineage = Array(Set(updated.lineage + mergedIDs)).sorted()
                } else {
                    updated.reviewStatus = .merged
                    updated.lineage = Array(Set(updated.lineage + [primaryID])).sorted()
                }
                updated.updatedAt = now
                return updated
            })
        case .split:
            guard let sourceID = proposal.definitionIDs.first,
                  let source = byID[sourceID] else {
                throw ProposalApplicationError.definitionNotFound(proposal.definitionIDs.first ?? "")
            }
            guard let rawIDs = proposal.payload["new_definition_ids"] else {
                throw ProposalApplicationError.invalidPayload("new_definition_ids")
            }
            let newIDs = rawIDs
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !newIDs.isEmpty else {
                throw ProposalApplicationError.invalidPayload("new_definition_ids")
            }
            var knownIDs = Set(byID.keys)
            for newID in newIDs {
                guard IdentifierValidator.isValid(newID, prefix: "def_") else {
                    throw ProposalApplicationError.invalidPayload("new_definition_ids")
                }
                guard knownIDs.insert(newID).inserted else {
                    throw ProposalApplicationError.duplicateDefinitionID(newID)
                }
            }
            var updatedSource = source
            updatedSource.reviewStatus = .split
            updatedSource.lineage = Array(Set(updatedSource.lineage + newIDs)).sorted()
            updatedSource.updatedAt = now
            var created = [updatedSource]
            created.append(contentsOf: newIDs.enumerated().map { index, newID in
                Definition(
                    id: newID,
                    projectID: source.projectID,
                    identity: DefinitionIdentity(
                        canonicalName: "\(source.identity.canonicalName).\(newID.dropFirst(4))",
                        displayName: "\(source.identity.displayName) Part \(index + 1)",
                        kind: source.identity.kind
                    ),
                    function: source.function,
                    codeLocator: CodeLocator(
                        symbol: source.codeLocator.symbol.isEmpty ? "" : "\(source.codeLocator.symbol)_\(index + 1)",
                        symbolType: source.codeLocator.symbolType,
                        function: source.codeLocator.function,
                        signature: source.codeLocator.signature,
                        owner: source.codeLocator.owner,
                        file: source.codeLocator.file,
                        module: source.codeLocator.module,
                        lineHint: source.codeLocator.lineHint
                    ),
                    visualLocator: source.visualLocator,
                    functionalLocator: source.functionalLocator,
                    fuzzyTerms: [],
                    relations: [],
                    references: [],
                    snapshots: [],
                    implementationHistory: [],
                    humanPriority: nil,
                    reviewStatus: .unreviewed,
                    lineage: [source.id],
                    createdAt: now,
                    updatedAt: now
                )
            })
            return ProposalApplication(updatedDefinitions: created)
        case .cluster:
            let clusterIDs = proposal.definitionIDs
            guard clusterIDs.count >= 2 else {
                throw ProposalApplicationError.invalidPayload("definition_ids")
            }
            let primaryID = proposal.payload["primary_definition_id"] ?? clusterIDs.sorted().first!
            guard clusterIDs.contains(primaryID) else {
                throw ProposalApplicationError.invalidPayload("primary_definition_id")
            }
            let name = proposal.payload["name"] ?? clusterIDs.compactMap { byID[$0]?.identity.displayName }.joined(separator: " · ")
            let clusterID = proposal.payload["cluster_id"] ?? "cluster_\(proposal.id)"
            let cluster = Cluster(
                id: clusterID,
                projectID: proposal.projectID,
                name: name,
                definitionIDs: clusterIDs.sorted(),
                primaryDefinitionID: primaryID,
                status: proposal.status,
                createdAt: now,
                updatedAt: now
            )
            return ProposalApplication(cluster: cluster)
        }
    }

    public static func decide(_ request: ChangeRequest, approved: Bool) -> ChangeRequest {
        var result = request
        result.status = approved ? .approved : .rejected
        return result
    }
}
