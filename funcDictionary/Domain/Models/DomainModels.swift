import Foundation

public enum SchemaVersion {
    public static let current = "1.0"
}

public enum ReviewStatus: String, Codable, CaseIterable, Sendable {
    case unreviewed
    case approved
    case deprecated
    case split
    case merged
    case archived
}

public enum DefinitionKind: String, Codable, CaseIterable, Sendable {
    case component
    case screen
    case controller
    case state
    case service
    case dataModel = "data_model"
    case function
    case other
}

public enum FuzzyTermSource: String, Codable, CaseIterable, Sendable {
    case user
    case humanAdded = "human_added"
    case aiGenerated = "ai_generated"
}

public enum RelationType: String, Codable, CaseIterable, Sendable {
    case contains
    /// A directly observed call from sourceDefinitionID to targetDefinitionID.
    case calls
    case uses
    case dependsOn = "depends_on"
    case triggers
    case displays
    case owns
    case produces
    case reads
    case writes
}

public enum HumanPriorityLevel: String, Codable, CaseIterable, Sendable {
    case important
    case critical
}

public enum LifecycleState: String, Codable, CaseIterable, Sendable {
    case experimental = "Experimental"
    case active = "Active"
    case evolving = "Evolving"
    case stabilizing = "Stabilizing"
    case stable = "Stable"
    case stableCore = "Stable Core"
    case evolvingCore = "Evolving Core"
    case activeCore = "Active Core"
}

public enum ProposalAction: String, Codable, CaseIterable, Sendable {
    case split
    case merge
    case deprecated
    case identityChange = "identity_change"
    case cluster
}

public enum ProposalStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case approved
    case adjusted
    case rejected
}

public enum ChangeRequestStatus: String, Codable, CaseIterable, Sendable {
    case pending
    case approved
    case rejected
}

public enum ConflictStatus: String, Codable, CaseIterable, Sendable {
    case needsReview = "needs_review"
    case resolved
}

public enum SyncState: String, Codable, CaseIterable, Sendable {
    case synced
    case syncing
    case needsConfirmation = "needs_confirmation"
    case conflict
    case offline
}

public struct Project: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var schemaVersion: String
    public var createdAt: Date
    public var updatedAt: Date
    public var archived: Bool

    public init(
        id: String,
        name: String,
        schemaVersion: String = SchemaVersion.current,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        archived: Bool = false
    ) {
        self.id = id
        self.name = name
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.archived = archived
    }
}

public struct DefinitionIdentity: Codable, Equatable, Hashable, Sendable {
    public var canonicalName: String
    public var displayName: String
    public var kind: DefinitionKind

    public init(canonicalName: String, displayName: String, kind: DefinitionKind) {
        self.canonicalName = canonicalName
        self.displayName = displayName
        self.kind = kind
    }
}

public struct FunctionDescriptor: Codable, Equatable, Hashable, Sendable {
    public var domain: String
    public var purpose: String
    public var actions: [String]

    public init(domain: String, purpose: String, actions: [String] = []) {
        self.domain = domain
        self.purpose = purpose
        self.actions = actions
    }
}

public struct CodeLocator: Codable, Equatable, Hashable, Sendable {
    public var symbol: String
    public var symbolType: String
    public var function: String
    public var signature: String
    public var owner: String
    public var file: String
    public var module: String
    public var lineHint: Int?
    /// 人类维护的短注释：一句话说明这个 func 当前做什么，展示在词典里。
    public var comment: String

    public init(
        symbol: String = "",
        symbolType: String = "",
        function: String = "",
        signature: String = "",
        owner: String = "",
        file: String = "",
        module: String = "",
        lineHint: Int? = nil,
        comment: String = ""
    ) {
        self.symbol = symbol
        self.symbolType = symbolType
        self.function = function
        self.signature = signature
        self.owner = owner
        self.file = file
        self.module = module
        self.lineHint = lineHint
        self.comment = comment
    }
}

// `func` is the exchange-protocol key. The Swift property stays named
// `function` so callers read naturally, while JSON remains compatible with
// the PRD examples and the repository Skill.
extension CodeLocator {
    private enum DecodeKeys: String, CodingKey {
        case symbol
        case symbolType
        case function
        case signature
        case owner
        case file
        case module
        case lineHint
        // 解码键不带 rawValue：策略把 JSON 键 func_comment 驼峰化为
        // funcComment，按 case 名匹配；带 rawValue 会退化成精确 rawValue
        // 匹配而导致永远解不出来。
        case funcComment
    }

    private enum EncodeKeys: String, CodingKey {
        case symbol
        case symbolType = "symbol_type"
        case function = "func"
        case signature
        case owner
        case file
        case module
        case lineHint = "line_hint"
        case comment = "func_comment"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodeKeys.self)
        symbol = try container.decodeIfPresent(String.self, forKey: .symbol) ?? ""
        symbolType = try container.decodeIfPresent(String.self, forKey: .symbolType) ?? ""
        function = try container.decodeIfPresent(String.self, forKey: .function) ?? ""
        signature = try container.decodeIfPresent(String.self, forKey: .signature) ?? ""
        owner = try container.decodeIfPresent(String.self, forKey: .owner) ?? ""
        file = try container.decodeIfPresent(String.self, forKey: .file) ?? ""
        module = try container.decodeIfPresent(String.self, forKey: .module) ?? ""
        lineHint = try container.decodeIfPresent(Int.self, forKey: .lineHint)
        comment = try container.decodeIfPresent(String.self, forKey: .funcComment) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EncodeKeys.self)
        try container.encode(symbol, forKey: .symbol)
        try container.encode(symbolType, forKey: .symbolType)
        try container.encode(function, forKey: .function)
        try container.encode(signature, forKey: .signature)
        try container.encode(owner, forKey: .owner)
        try container.encode(file, forKey: .file)
        try container.encode(module, forKey: .module)
        try container.encodeIfPresent(lineHint, forKey: .lineHint)
        try container.encode(comment, forKey: .comment)
    }
}

public struct VisualLocator: Codable, Equatable, Hashable, Sendable {
    public var screen: String
    public var container: String
    public var region: String
    public var hierarchy: [String]

    public init(screen: String = "", container: String = "", region: String = "", hierarchy: [String] = []) {
        self.screen = screen
        self.container = container
        self.region = region
        self.hierarchy = hierarchy
    }
}

/// 一条 UI 实测数值（如「网格列间距 = 16pt」），property 是中文属性名，
/// value 是带单位的当前值，source 可选，标注数值来自哪个常量或文件。
public struct UIDatum: Codable, Equatable, Hashable, Sendable {
    public var property: String
    public var value: String
    public var source: String

    public init(property: String, value: String, source: String = "") {
        self.property = property
        self.value = value
        self.source = source
    }
}

public struct FunctionalLocator: Codable, Equatable, Hashable, Sendable {
    public var domain: String
    public var role: String
    public var trigger: String

    public init(domain: String = "", role: String = "", trigger: String = "") {
        self.domain = domain
        self.role = role
        self.trigger = trigger
    }
}

public struct FuzzyTerm: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var text: String
    public var source: FuzzyTermSource
    public var weight: Double
    public var usageCount: Int

    public init(
        id: String = UUID().uuidString,
        text: String,
        source: FuzzyTermSource,
        weight: Double = 1,
        usageCount: Int = 1
    ) {
        self.id = id
        self.text = text
        self.source = source
        self.weight = min(max(weight, 0), 1)
        self.usageCount = max(usageCount, 1)
    }
}

public struct Relation: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var type: RelationType
    public var sourceDefinitionID: String
    public var targetDefinitionID: String
    public var metadata: [String: String]

    public init(
        id: String = UUID().uuidString,
        type: RelationType,
        sourceDefinitionID: String,
        targetDefinitionID: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.type = type
        self.sourceDefinitionID = sourceDefinitionID
        self.targetDefinitionID = targetDefinitionID
        self.metadata = metadata
    }
}

public extension Relation {
    var historyChanges: [String: String] {
        var changes = [
            "relation_id": id,
            "type": type.rawValue,
            "source_definition_id": sourceDefinitionID,
            "target_definition_id": targetDefinitionID
        ]
        for (key, value) in metadata { changes["metadata.\(key)"] = value }
        return changes
    }
}

public struct Reference: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var value: String

    public init(id: String = UUID().uuidString, kind: String, value: String) {
        self.id = id
        self.kind = kind
        self.value = value
    }
}

public struct DefinitionReferenceChange: Codable, Equatable, Hashable, Sendable {
    public var definitionID: String
    public var reference: Reference

    public init(definitionID: String, reference: Reference) {
        self.definitionID = definitionID
        self.reference = reference
    }
}

public struct DefinitionSnapshotChange: Codable, Equatable, Hashable, Sendable {
    public var definitionID: String
    public var snapshot: SnapshotMetadata

    public init(definitionID: String, snapshot: SnapshotMetadata) {
        self.definitionID = definitionID
        self.snapshot = snapshot
    }
}

public struct SnapshotMetadata: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var file: String
    public var width: Int
    public var height: Int
    public var sizeBytes: Int
    public var perceptualHash: String
    public var revision: Int
    public var milestone: Bool

    public init(
        id: String,
        file: String,
        width: Int,
        height: Int,
        sizeBytes: Int,
        perceptualHash: String,
        revision: Int,
        milestone: Bool = false
    ) {
        self.id = id
        self.file = file
        self.width = width
        self.height = height
        self.sizeBytes = sizeBytes
        self.perceptualHash = perceptualHash
        self.revision = revision
        self.milestone = milestone
    }
}

public struct ImplementationEvent: Codable, Equatable, Hashable, Sendable {
    public var revision: Int
    public var changeType: String
    public var changes: [String: String]
    public var codeImpact: Double
    public var semanticImpact: Double
    public var milestone: Bool
    public var occurredAt: Date

    public init(
        revision: Int,
        changeType: String,
        changes: [String: String] = [:],
        codeImpact: Double,
        semanticImpact: Double,
        milestone: Bool,
        occurredAt: Date = Date()
    ) {
        self.revision = revision
        self.changeType = changeType
        self.changes = changes
        self.codeImpact = min(max(codeImpact, 0), 1)
        self.semanticImpact = min(max(semanticImpact, 0), 1)
        self.milestone = milestone
        self.occurredAt = occurredAt
    }

    private enum CodingKeys: String, CodingKey {
        case revision
        case changeType
        case changes
        case codeImpact
        case semanticImpact
        case milestone
        case occurredAt
    }

    private enum ChangeObjectKeys: String, CodingKey {
        case from
        case to
    }

    private struct FlexibleChangeValue: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let singleValue = try decoder.singleValueContainer()
            if let string = try? singleValue.decode(String.self) {
                value = string
                return
            }
            let object = try decoder.container(keyedBy: ChangeObjectKeys.self)
            let from = try object.decode(String.self, forKey: .from)
            let to = try object.decode(String.self, forKey: .to)
            value = "\(from) -> \(to)"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        revision = try container.decode(Int.self, forKey: .revision)
        changeType = try container.decode(String.self, forKey: .changeType)
        let flexibleChanges = try container.decode([String: FlexibleChangeValue].self, forKey: .changes)
        changes = flexibleChanges.mapValues(\.value)
        codeImpact = try container.decode(Double.self, forKey: .codeImpact)
        semanticImpact = try container.decode(Double.self, forKey: .semanticImpact)
        milestone = try container.decode(Bool.self, forKey: .milestone)
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(revision, forKey: .revision)
        try container.encode(changeType, forKey: .changeType)
        try container.encode(changes, forKey: .changes)
        try container.encode(codeImpact, forKey: .codeImpact)
        try container.encode(semanticImpact, forKey: .semanticImpact)
        try container.encode(milestone, forKey: .milestone)
        try container.encode(occurredAt, forKey: .occurredAt)
    }
}

public struct HumanPriority: Codable, Equatable, Hashable, Sendable {
    public var level: HumanPriorityLevel
    public var label: String
    public var note: String

    public init(level: HumanPriorityLevel, label: String, note: String) {
        self.level = level
        self.label = label
        self.note = note
    }
}

public struct CollectionScore: Codable, Equatable, Hashable, Sendable {
    public var independentlyEditable: Double
    public var independentlyLocatable: Double
    public var functionalBoundary: Double
    public var stableIdentity: Double
    public var reusePotential: Double
    public var total: Double
    public var threshold: Double
    public var shouldCreate: Bool
    public var explanation: String
    public var evidence: [String]

    public init(
        independentlyEditable: Double,
        independentlyLocatable: Double,
        functionalBoundary: Double,
        stableIdentity: Double,
        reusePotential: Double,
        threshold: Double,
        shouldCreate: Bool,
        explanation: String,
        evidence: [String]
    ) {
        self.independentlyEditable = independentlyEditable
        self.independentlyLocatable = independentlyLocatable
        self.functionalBoundary = functionalBoundary
        self.stableIdentity = stableIdentity
        self.reusePotential = reusePotential
        self.total = independentlyEditable * 0.30
            + independentlyLocatable * 0.25
            + functionalBoundary * 0.20
            + stableIdentity * 0.15
            + reusePotential * 0.10
        self.threshold = threshold
        self.shouldCreate = shouldCreate
        self.explanation = explanation
        self.evidence = evidence
    }
}

public struct LifecycleEvaluation: Codable, Equatable, Hashable, Sendable {
    public var state: LifecycleState
    public var activity: Double
    public var centrality: Double
    public var stability: Double
    public var maturity: Double
    public var matchedRules: [String]
    public var calculatedAt: Date
    public var algorithmVersion: String

    public init(
        state: LifecycleState,
        activity: Double,
        centrality: Double,
        stability: Double,
        maturity: Double,
        matchedRules: [String],
        calculatedAt: Date = Date(),
        algorithmVersion: String = "1.0"
    ) {
        self.state = state
        self.activity = activity
        self.centrality = centrality
        self.stability = stability
        self.maturity = maturity
        self.matchedRules = matchedRules
        self.calculatedAt = calculatedAt
        self.algorithmVersion = algorithmVersion
    }
}

public struct ChangeHeatResult: Codable, Equatable, Hashable, Sendable {
    public var score: Double
    public var percentile: Double
    public var eventCount: Int
    public var explanation: String
    public var calculatedAt: Date

    public init(score: Double, percentile: Double, eventCount: Int, explanation: String, calculatedAt: Date = Date()) {
        self.score = score
        self.percentile = percentile
        self.eventCount = eventCount
        self.explanation = explanation
        self.calculatedAt = calculatedAt
    }
}

public struct Definition: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var projectID: String
    public var schemaVersion: String
    public var identity: DefinitionIdentity
    public var function: FunctionDescriptor
    public var codeLocator: CodeLocator
    public var visualLocator: VisualLocator
    public var functionalLocator: FunctionalLocator
    public var fuzzyTerms: [FuzzyTerm]
    public var relations: [Relation]
    public var references: [Reference]
    public var snapshots: [SnapshotMetadata]
    public var implementationHistory: [ImplementationEvent]
    public var humanPriority: HumanPriority?
    public var reviewStatus: ReviewStatus
    public var lifecycle: LifecycleEvaluation?
    public var changeHeat: ChangeHeatResult?
    public var activeContext: Bool
    public var lineage: [String]
    /// 元素相关的 UI 实测数值（px/pt），由 agent 读代码后经 Delta 演进写入。
    /// Optional 使旧 payload/旧 Delta 解码向后兼容。
    public var uiMetrics: [UIDatum]?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        projectID: String,
        identity: DefinitionIdentity,
        function: FunctionDescriptor,
        codeLocator: CodeLocator,
        visualLocator: VisualLocator,
        functionalLocator: FunctionalLocator,
        fuzzyTerms: [FuzzyTerm] = [],
        relations: [Relation] = [],
        references: [Reference] = [],
        snapshots: [SnapshotMetadata] = [],
        implementationHistory: [ImplementationEvent] = [],
        humanPriority: HumanPriority? = nil,
        reviewStatus: ReviewStatus = .unreviewed,
        lifecycle: LifecycleEvaluation? = nil,
        changeHeat: ChangeHeatResult? = nil,
        activeContext: Bool = false,
        lineage: [String] = [],
        uiMetrics: [UIDatum]? = nil,
        schemaVersion: String = SchemaVersion.current,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.schemaVersion = schemaVersion
        self.identity = identity
        self.function = function
        self.codeLocator = codeLocator
        self.visualLocator = visualLocator
        self.functionalLocator = functionalLocator
        self.fuzzyTerms = fuzzyTerms
        self.relations = relations
        self.references = references
        self.snapshots = snapshots
        self.implementationHistory = implementationHistory
        self.humanPriority = humanPriority
        self.reviewStatus = reviewStatus
        self.lifecycle = lifecycle
        self.changeHeat = changeHeat
        self.activeContext = activeContext
        self.lineage = lineage
        self.uiMetrics = uiMetrics
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var isProtected: Bool {
        humanPriority?.level == .critical
    }
}

public struct Cluster: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var projectID: String
    public var name: String
    public var definitionIDs: [String]
    public var primaryDefinitionID: String
    public var status: ProposalStatus
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String,
        projectID: String,
        name: String,
        definitionIDs: [String],
        primaryDefinitionID: String,
        status: ProposalStatus = .pending,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.name = name
        self.definitionIDs = definitionIDs
        self.primaryDefinitionID = primaryDefinitionID
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Proposal: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var projectID: String
    public var action: ProposalAction
    public var definitionIDs: [String]
    public var status: ProposalStatus
    public var summary: String
    public var payload: [String: String]
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        action: ProposalAction,
        definitionIDs: [String],
        status: ProposalStatus = .pending,
        summary: String,
        payload: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.action = action
        self.definitionIDs = definitionIDs
        self.status = status
        self.summary = summary
        self.payload = payload
        self.createdAt = createdAt
    }
}

public struct RequestedChange: Codable, Equatable, Hashable, Sendable {
    public var type: String
    public var summary: String

    public init(type: String, summary: String) {
        self.type = type
        self.summary = summary
    }
}

public struct ChangeRequest: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var projectID: String
    public var definitionID: String
    public var requestedChange: RequestedChange
    public var reason: String
    public var risk: String
    public var affectedDefinitionIDs: [String]
    /// Optional exact requested state.  Older exchange records may omit this
    /// field, but new protected edits populate it so an approval cannot be
    /// reused for a different structural change.
    public var proposedValues: [String: String]
    public var status: ChangeRequestStatus
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        definitionID: String,
        requestedChange: RequestedChange,
        reason: String,
        risk: String,
        affectedDefinitionIDs: [String],
        proposedValues: [String: String] = [:],
        status: ChangeRequestStatus = .pending,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.definitionID = definitionID
        self.requestedChange = requestedChange
        self.reason = reason
        self.risk = risk
        self.affectedDefinitionIDs = affectedDefinitionIDs
        self.proposedValues = proposedValues
        self.status = status
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case projectID
        case definitionID
        case requestedChange
        case reason
        case risk
        case affectedDefinitionIDs
        case proposedValues
        case status
        case createdAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        projectID = try container.decode(String.self, forKey: .projectID)
        definitionID = try container.decode(String.self, forKey: .definitionID)
        requestedChange = try container.decode(RequestedChange.self, forKey: .requestedChange)
        reason = try container.decode(String.self, forKey: .reason)
        risk = try container.decode(String.self, forKey: .risk)
        affectedDefinitionIDs = try container.decode([String].self, forKey: .affectedDefinitionIDs)
        proposedValues = try container.decodeIfPresent([String: String].self, forKey: .proposedValues) ?? [:]
        status = try container.decode(ChangeRequestStatus.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(definitionID, forKey: .definitionID)
        try container.encode(requestedChange, forKey: .requestedChange)
        try container.encode(reason, forKey: .reason)
        try container.encode(risk, forKey: .risk)
        try container.encode(affectedDefinitionIDs, forKey: .affectedDefinitionIDs)
        try container.encode(proposedValues, forKey: .proposedValues)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
    }
}

public struct FieldRevision: Codable, Equatable, Hashable, Sendable {
    public var entityID: String
    public var projectID: String
    public var field: String
    public var revision: Int
    public var source: String
    public var updatedAt: Date

    public init(entityID: String, projectID: String, field: String, revision: Int, source: String, updatedAt: Date = Date()) {
        self.entityID = entityID
        self.projectID = projectID
        self.field = field
        self.revision = revision
        self.source = source
        self.updatedAt = updatedAt
    }
}

public struct ConflictRecord: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var projectID: String
    public var definitionID: String
    public var field: String
    public var baseRevision: Int
    public var localRevision: Int
    public var remoteRevision: Int
    public var localValue: String
    public var remoteValue: String
    public var status: ConflictStatus
    public var createdAt: Date

    public init(
        id: String,
        projectID: String,
        definitionID: String,
        field: String,
        baseRevision: Int,
        localRevision: Int,
        remoteRevision: Int,
        localValue: String,
        remoteValue: String,
        status: ConflictStatus = .needsReview,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.projectID = projectID
        self.definitionID = definitionID
        self.field = field
        self.baseRevision = baseRevision
        self.localRevision = localRevision
        self.remoteRevision = remoteRevision
        self.localValue = localValue
        self.remoteValue = remoteValue
        self.status = status
        self.createdAt = createdAt
    }
}

public struct ImpactDimensions: Codable, Equatable, Hashable, Sendable {
    public var behavior: Double
    public var structure: Double
    public var data: Double
    public var visual: Double

    public init(behavior: Double = 0, structure: Double = 0, data: Double = 0, visual: Double = 0) {
        self.behavior = min(max(behavior, 0), 1)
        self.structure = min(max(structure, 0), 1)
        self.data = min(max(data, 0), 1)
        self.visual = min(max(visual, 0), 1)
    }

    public func value(for dimension: ImpactDimension) -> Double {
        switch dimension {
        case .behavior: behavior
        case .structure: structure
        case .data: data
        case .visual: visual
        }
    }
}

public enum ImpactDimension: String, Codable, CaseIterable, Sendable {
    case behavior
    case structure
    case data
    case visual
}

public struct ScoringConfiguration: Codable, Equatable, Hashable, Sendable {
    public var collectionThreshold: Double
    public var criticalPropagationThreshold: Double
    public var directSearchThreshold: Double
    public var directSearchMargin: Double
    public var candidateSearchThreshold: Double
    public var changeHeatHalfLifeDays: Double
    public var protectionMaxDepth: Int

    public init(
        collectionThreshold: Double = 0.70,
        criticalPropagationThreshold: Double = 0.60,
        directSearchThreshold: Double = 0.72,
        directSearchMargin: Double = 0.12,
        candidateSearchThreshold: Double = 0.35,
        changeHeatHalfLifeDays: Double = 30,
        protectionMaxDepth: Int = 3
    ) {
        self.collectionThreshold = collectionThreshold
        self.criticalPropagationThreshold = criticalPropagationThreshold
        self.directSearchThreshold = directSearchThreshold
        self.directSearchMargin = directSearchMargin
        self.candidateSearchThreshold = candidateSearchThreshold
        self.changeHeatHalfLifeDays = changeHeatHalfLifeDays
        self.protectionMaxDepth = protectionMaxDepth
    }
}

public struct ProjectSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var project: Project
    public var definitions: [Definition]
    public var clusters: [Cluster]
    public var agentContext: AgentContext
    public var revision: Int
    public var generatedAt: Date

    public init(
        project: Project,
        definitions: [Definition],
        clusters: [Cluster] = [],
        agentContext: AgentContext = .empty,
        revision: Int = 0,
        generatedAt: Date = Date(),
        schemaVersion: String = SchemaVersion.current
    ) {
        self.schemaVersion = schemaVersion
        self.project = project
        self.definitions = definitions
        self.clusters = clusters
        self.agentContext = agentContext
        self.revision = revision
        self.generatedAt = generatedAt
    }
}

public struct AgentContext: Codable, Equatable, Sendable {
    public var definitionID: String
    public var canonicalName: String
    public var currentSymbol: String
    public var currentFunction: String
    public var codeLocator: CodeLocator
    public var visualLocator: VisualLocator
    public var functionalLocator: FunctionalLocator
    public var humanPriority: HumanPriority?
    public var protection: [String: String]?
    public var relevantRelations: [Relation]

    public static let empty = AgentContext(
        definitionID: "",
        canonicalName: "",
        currentSymbol: "",
        currentFunction: "",
        codeLocator: CodeLocator(),
        visualLocator: VisualLocator(),
        functionalLocator: FunctionalLocator(),
        humanPriority: nil,
        protection: nil,
        relevantRelations: []
    )

    public init(
        definitionID: String,
        canonicalName: String,
        currentSymbol: String,
        currentFunction: String,
        codeLocator: CodeLocator,
        visualLocator: VisualLocator,
        functionalLocator: FunctionalLocator,
        humanPriority: HumanPriority?,
        protection: [String: String]?,
        relevantRelations: [Relation]
    ) {
        self.definitionID = definitionID
        self.canonicalName = canonicalName
        self.currentSymbol = currentSymbol
        self.currentFunction = currentFunction
        self.codeLocator = codeLocator
        self.visualLocator = visualLocator
        self.functionalLocator = functionalLocator
        self.humanPriority = humanPriority
        self.protection = protection
        self.relevantRelations = relevantRelations
    }
}

extension AgentContext {
    private enum DecodeKeys: String, CodingKey {
        case definitionID
        case canonicalName
        case currentSymbol
        case currentFunction
        case codeLocator
        case visualLocator
        case functionalLocator
        case humanPriority
        case protection
        case relevantRelations
    }

    private enum EncodeKeys: String, CodingKey {
        case definitionID = "definition_id"
        case canonicalName = "canonical_name"
        case currentSymbol = "current_symbol"
        case currentFunction = "current_func"
        case codeLocator = "code_locator"
        case visualLocator = "visual_locator"
        case functionalLocator = "functional_locator"
        case humanPriority = "human_priority"
        case protection
        case relevantRelations = "relevant_relations"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DecodeKeys.self)
        definitionID = try container.decodeIfPresent(String.self, forKey: .definitionID) ?? ""
        canonicalName = try container.decodeIfPresent(String.self, forKey: .canonicalName) ?? ""
        currentSymbol = try container.decodeIfPresent(String.self, forKey: .currentSymbol) ?? ""
        currentFunction = try container.decodeIfPresent(String.self, forKey: .currentFunction) ?? ""
        codeLocator = try container.decodeIfPresent(CodeLocator.self, forKey: .codeLocator) ?? CodeLocator()
        visualLocator = try container.decodeIfPresent(VisualLocator.self, forKey: .visualLocator) ?? VisualLocator()
        functionalLocator = try container.decodeIfPresent(FunctionalLocator.self, forKey: .functionalLocator) ?? FunctionalLocator()
        humanPriority = try container.decodeIfPresent(HumanPriority.self, forKey: .humanPriority)
        protection = try container.decodeIfPresent([String: String].self, forKey: .protection)
        relevantRelations = try container.decodeIfPresent([Relation].self, forKey: .relevantRelations) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: EncodeKeys.self)
        try container.encode(definitionID, forKey: .definitionID)
        try container.encode(canonicalName, forKey: .canonicalName)
        try container.encode(currentSymbol, forKey: .currentSymbol)
        try container.encode(currentFunction, forKey: .currentFunction)
        try container.encode(codeLocator, forKey: .codeLocator)
        try container.encode(visualLocator, forKey: .visualLocator)
        try container.encode(functionalLocator, forKey: .functionalLocator)
        try container.encodeIfPresent(humanPriority, forKey: .humanPriority)
        try container.encodeIfPresent(protection, forKey: .protection)
        try container.encode(relevantRelations, forKey: .relevantRelations)
    }
}

public struct DictionaryDelta: Codable, Equatable, Sendable {
    public var schemaVersion: String
    public var deltaID: String
    public var projectID: String
    public var baseRevision: Int
    public var targetRevision: Int
    public var createdAt: Date
    public var changedFields: [String]
    public var definitionsCreated: [Definition]
    public var definitionsEvolved: [DefinitionEvolution]
    public var fuzzyTermsAdded: [FuzzyTermChange]
    public var relationsChanged: [Relation]
    public var relationsRemoved: [Relation]
    public var referencesChanged: [DefinitionReferenceChange]
    public var snapshotsChanged: [DefinitionSnapshotChange]
    public var proposals: [Proposal]
    public var changeRequests: [ChangeRequest]
    public var conflictRecords: [ConflictRecord]

    public init(
        deltaID: String,
        projectID: String,
        baseRevision: Int,
        targetRevision: Int,
        createdAt: Date = Date(),
        changedFields: [String] = [],
        definitionsCreated: [Definition] = [],
        definitionsEvolved: [DefinitionEvolution] = [],
        fuzzyTermsAdded: [FuzzyTermChange] = [],
        relationsChanged: [Relation] = [],
        relationsRemoved: [Relation] = [],
        referencesChanged: [DefinitionReferenceChange] = [],
        snapshotsChanged: [DefinitionSnapshotChange] = [],
        proposals: [Proposal] = [],
        changeRequests: [ChangeRequest] = [],
        conflictRecords: [ConflictRecord] = [],
        schemaVersion: String = SchemaVersion.current
    ) {
        self.schemaVersion = schemaVersion
        self.deltaID = deltaID
        self.projectID = projectID
        self.baseRevision = baseRevision
        self.targetRevision = targetRevision
        self.createdAt = createdAt
        self.changedFields = changedFields
        self.definitionsCreated = definitionsCreated
        self.definitionsEvolved = definitionsEvolved
        self.fuzzyTermsAdded = fuzzyTermsAdded
        self.relationsChanged = relationsChanged
        self.relationsRemoved = relationsRemoved
        self.referencesChanged = referencesChanged
        self.snapshotsChanged = snapshotsChanged
        self.proposals = proposals
        self.changeRequests = changeRequests
        self.conflictRecords = conflictRecords
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case deltaID
        case projectID
        case baseRevision
        case targetRevision
        case createdAt
        case changedFields
        case definitionsCreated
        case definitionsEvolved
        case fuzzyTermsAdded
        case relationsChanged
        case relationsRemoved
        case referencesChanged
        case snapshotsChanged
        case proposals
        case changeRequests
        case conflictRecords
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(String.self, forKey: .schemaVersion)
        deltaID = try container.decode(String.self, forKey: .deltaID)
        projectID = try container.decode(String.self, forKey: .projectID)
        baseRevision = try container.decode(Int.self, forKey: .baseRevision)
        targetRevision = try container.decode(Int.self, forKey: .targetRevision)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        changedFields = try container.decode([String].self, forKey: .changedFields)
        definitionsCreated = try container.decode([Definition].self, forKey: .definitionsCreated)
        definitionsEvolved = try container.decode([DefinitionEvolution].self, forKey: .definitionsEvolved)
        fuzzyTermsAdded = try container.decode([FuzzyTermChange].self, forKey: .fuzzyTermsAdded)
        relationsChanged = try container.decode([Relation].self, forKey: .relationsChanged)
        relationsRemoved = try container.decodeIfPresent([Relation].self, forKey: .relationsRemoved) ?? []
        referencesChanged = try container.decode([DefinitionReferenceChange].self, forKey: .referencesChanged)
        snapshotsChanged = try container.decode([DefinitionSnapshotChange].self, forKey: .snapshotsChanged)
        proposals = try container.decode([Proposal].self, forKey: .proposals)
        changeRequests = try container.decode([ChangeRequest].self, forKey: .changeRequests)
        conflictRecords = try container.decode([ConflictRecord].self, forKey: .conflictRecords)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(deltaID, forKey: .deltaID)
        try container.encode(projectID, forKey: .projectID)
        try container.encode(baseRevision, forKey: .baseRevision)
        try container.encode(targetRevision, forKey: .targetRevision)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(changedFields, forKey: .changedFields)
        try container.encode(definitionsCreated, forKey: .definitionsCreated)
        try container.encode(definitionsEvolved, forKey: .definitionsEvolved)
        try container.encode(fuzzyTermsAdded, forKey: .fuzzyTermsAdded)
        try container.encode(relationsChanged, forKey: .relationsChanged)
        try container.encode(relationsRemoved, forKey: .relationsRemoved)
        try container.encode(referencesChanged, forKey: .referencesChanged)
        try container.encode(snapshotsChanged, forKey: .snapshotsChanged)
        try container.encode(proposals, forKey: .proposals)
        try container.encode(changeRequests, forKey: .changeRequests)
        try container.encode(conflictRecords, forKey: .conflictRecords)
    }
}

public struct DefinitionEvolution: Codable, Equatable, Hashable, Sendable {
    public var definitionID: String
    public var changeType: String
    public var changes: [String: String]
    public var codeImpact: Double
    public var semanticImpact: Double
    public var milestone: Bool

    public init(
        definitionID: String,
        changeType: String,
        changes: [String: String],
        codeImpact: Double,
        semanticImpact: Double,
        milestone: Bool
    ) {
        self.definitionID = definitionID
        self.changeType = changeType
        self.changes = changes
        self.codeImpact = codeImpact
        self.semanticImpact = semanticImpact
        self.milestone = milestone
    }

    private enum CodingKeys: String, CodingKey {
        case definitionID
        case changeType
        case changes
        case codeImpact
        case semanticImpact
        case milestone
    }

    private enum ChangeObjectKeys: String, CodingKey {
        case from
        case to
    }

    private struct FlexibleChangeValue: Decodable {
        let value: String

        init(from decoder: Decoder) throws {
            let singleValue = try decoder.singleValueContainer()
            if let string = try? singleValue.decode(String.self) {
                value = string
                return
            }
            let object = try decoder.container(keyedBy: ChangeObjectKeys.self)
            let from = try object.decode(String.self, forKey: .from)
            let to = try object.decode(String.self, forKey: .to)
            value = "\(from) -> \(to)"
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        definitionID = try container.decode(String.self, forKey: .definitionID)
        changeType = try container.decode(String.self, forKey: .changeType)
        let flexibleChanges = try container.decode([String: FlexibleChangeValue].self, forKey: .changes)
        changes = flexibleChanges.mapValues(\.value)
        codeImpact = try container.decode(Double.self, forKey: .codeImpact)
        semanticImpact = try container.decode(Double.self, forKey: .semanticImpact)
        milestone = try container.decode(Bool.self, forKey: .milestone)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(definitionID, forKey: .definitionID)
        try container.encode(changeType, forKey: .changeType)
        // The canonical emitted form is a compact string map. Decoder support
        // above also accepts the PRD's {from,to} object form from older
        // producers.
        try container.encode(changes, forKey: .changes)
        try container.encode(codeImpact, forKey: .codeImpact)
        try container.encode(semanticImpact, forKey: .semanticImpact)
        try container.encode(milestone, forKey: .milestone)
    }

    /// Applies the current-value portion of an evolution while preserving the
    /// stable Definition ID. Exchange producers use strings such as
    /// `oldValue -> newValue`; accepting a plain value keeps the protocol
    /// forward-compatible with producers that already send the new value.
    public func applying(to definition: Definition) -> Definition {
        var updated = definition
        let previousCanonicalName = definition.identity.canonicalName

        for key in changes.keys.sorted() {
            guard let rawValue = changes[key] else { continue }
            let value = Self.newValue(from: rawValue)
            // ui_metric.<属性名> 键维护元素的 UI 实测数值表，值必须原样保留。
            if key.hasPrefix("ui_metric.") {
                let name = String(key.dropFirst("ui_metric.".count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                var metrics = updated.uiMetrics ?? []
                if let index = metrics.firstIndex(where: { $0.property == name }) {
                    metrics[index].value = value
                } else {
                    metrics.append(UIDatum(property: name, value: value))
                }
                updated.uiMetrics = metrics
                continue
            }
            switch Self.normalizedFieldName(key) {
            case "canonical_name":
                updated.identity.canonicalName = value
            case "display_name":
                updated.identity.displayName = value
            case "kind":
                if let kind = DefinitionKind(rawValue: value) {
                    updated.identity.kind = kind
                }
            case "symbol":
                updated.codeLocator.symbol = value
            case "symbol_type":
                updated.codeLocator.symbolType = value
            case "func", "function":
                updated.codeLocator.function = value
            case "func_comment":
                updated.codeLocator.comment = value
            case "signature":
                updated.codeLocator.signature = value
            case "owner":
                updated.codeLocator.owner = value
            case "file":
                updated.codeLocator.file = value
            case "module":
                updated.codeLocator.module = value
            case "screen":
                updated.visualLocator.screen = value
            case "container":
                updated.visualLocator.container = value
            case "region":
                updated.visualLocator.region = value
            case "domain" where key.localizedCaseInsensitiveContains("functional"):
                updated.functionalLocator.domain = value
            case "role" where key.localizedCaseInsensitiveContains("functional"):
                updated.functionalLocator.role = value
            case "trigger" where key.localizedCaseInsensitiveContains("functional"):
                updated.functionalLocator.trigger = value
            case "purpose":
                updated.function.purpose = value
            default:
                continue
            }
        }

        if previousCanonicalName != updated.identity.canonicalName {
            updated.lineage = Array(Set(updated.lineage + [previousCanonicalName])).sorted()
        }
        return updated
    }

    private static func normalizedFieldName(_ key: String) -> String {
        let components = key
            .replacingOccurrences(of: "-", with: "_")
            .split(separator: ".", omittingEmptySubsequences: true)
        return components.last.map(String.init)?.lowercased() ?? key.lowercased()
    }

    private static func newValue(from rawValue: String) -> String {
        guard let separator = rawValue.range(of: "->") else {
            return rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rawValue[separator.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public struct FuzzyTermChange: Codable, Equatable, Hashable, Sendable {
    public var definitionID: String
    public var term: FuzzyTerm

    public init(definitionID: String, term: FuzzyTerm) {
        self.definitionID = definitionID
        self.term = term
    }
}

public enum IdentifierValidator {
    public static func isValid(_ value: String, prefix: String? = nil) -> Bool {
        guard !value.isEmpty else { return false }
        if let prefix, !value.hasPrefix(prefix) { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x41 && scalar.value <= 0x5A)
                || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
                || scalar.value == 0x5F
                || scalar.value == 0x2D
        }
    }
}

public enum DomainValidationError: Error, Equatable, LocalizedError, Sendable {
    case emptyProjectID
    case emptyProjectName
    case invalidDefinitionID
    case invalidProjectID
    case definitionProjectMismatch
    case emptyCanonicalName
    case emptyCodeLocator
    case duplicateStableID
    case relationOwnership

    public var errorDescription: String? {
        switch self {
        case .emptyProjectID: "Project ID cannot be empty."
        case .emptyProjectName: "Project name cannot be empty."
        case .invalidDefinitionID: "Definition ID is invalid."
        case .invalidProjectID: "Project ID is invalid."
        case .definitionProjectMismatch: "Definition belongs to another project."
        case .emptyCanonicalName: "Canonical name cannot be empty."
        case .emptyCodeLocator: "Code locator must contain a symbol, function, or file."
        case .duplicateStableID: "The stable ID already exists in this project."
        case .relationOwnership: "A relation must be owned by its source definition."
        }
    }
}

public enum DomainValidator {
    public static func validate(project: Project) throws {
        guard IdentifierValidator.isValid(project.id, prefix: "project_") else {
            throw DomainValidationError.invalidProjectID
        }
        guard !project.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyProjectName
        }
    }

    public static func validate(definition: Definition, projectID: String? = nil) throws {
        guard IdentifierValidator.isValid(definition.id, prefix: "def_") else {
            throw DomainValidationError.invalidDefinitionID
        }
        guard IdentifierValidator.isValid(definition.projectID, prefix: "project_") else {
            throw DomainValidationError.invalidProjectID
        }
        if let projectID, projectID != definition.projectID {
            throw DomainValidationError.definitionProjectMismatch
        }
        guard !definition.identity.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DomainValidationError.emptyCanonicalName
        }
        let locator = definition.codeLocator
        guard !locator.symbol.isEmpty || !locator.function.isEmpty || !locator.file.isEmpty else {
            throw DomainValidationError.emptyCodeLocator
        }
        guard definition.relations.allSatisfy({ relation in
            guard relation.sourceDefinitionID == definition.id else { return false }
            guard relation.type == .calls else { return true }
            let file = relation.metadata["file"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let line = Int(relation.metadata["line"] ?? "") ?? 0
            let evidence = relation.metadata["evidence"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !file.isEmpty && !file.hasPrefix("/") && !file.split(separator: "/").contains("..") && line > 0 && !evidence.isEmpty
        }) else {
            throw DomainValidationError.relationOwnership
        }
    }
}
