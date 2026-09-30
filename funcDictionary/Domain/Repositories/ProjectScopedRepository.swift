import Foundation

@MainActor
public protocol ProjectScopedRepository: AnyObject {
    func project(id: String) throws -> Project?
    func projects(includeArchived: Bool) throws -> [Project]
    func save(project: Project) throws
    func archive(projectID: String) throws
    func softDelete(projectID: String) throws

    func definitions(in projectID: String) throws -> [Definition]
    func definition(id: String, in projectID: String) throws -> Definition?
    func save(definition: Definition, in projectID: String) throws
    func softDelete(definitionID: String, in projectID: String) throws

    func clusters(in projectID: String) throws -> [Cluster]
    func save(cluster: Cluster, in projectID: String) throws
    func proposals(in projectID: String) throws -> [Proposal]
    func pendingProposals(in projectID: String) throws -> [Proposal]
    func save(proposal: Proposal, in projectID: String) throws
    func changeRequests(in projectID: String) throws -> [ChangeRequest]
    func pendingChangeRequests(in projectID: String) throws -> [ChangeRequest]
    func save(changeRequest: ChangeRequest, in projectID: String) throws

    func fieldRevisions(for entityID: String, in projectID: String) throws -> [FieldRevision]
    func save(fieldRevision: FieldRevision) throws
    func conflicts(in projectID: String) throws -> [ConflictRecord]
    func save(conflict: ConflictRecord) throws

    func apply(delta: DictionaryDelta, in projectID: String) throws -> DeltaApplyResult
    /// Applies an already human-approved Proposal as one transaction and
    /// writes the ImplementationEvent / FieldRevision audit trail required
    /// by ADR-007. Returns `false` when the application is blocked pending
    /// a paired approved Change Request; the caller may retry after the
    /// missing governance record is approved.
    func apply(approved proposal: Proposal, in projectID: String) throws -> Bool
    /// Same transaction and audit contract as `apply(approved proposal:)`
    /// for an approved Change Request. Returns `false` when the request is
    /// unapproved, carries no proposed values, or its identity-bearing
    /// change has no payload-bound approved Proposal yet.
    func apply(approved request: ChangeRequest, in projectID: String) throws -> Bool
    func currentRevision(in projectID: String) throws -> Int
}

public struct DeltaApplyResult: Equatable, Sendable {
    public var imported: Bool
    public var alreadyApplied: Bool
    public var newRevision: Int
    public var conflictCount: Int

    public init(imported: Bool, alreadyApplied: Bool, newRevision: Int, conflictCount: Int) {
        self.imported = imported
        self.alreadyApplied = alreadyApplied
        self.newRevision = newRevision
        self.conflictCount = conflictCount
    }
}

public enum RepositoryError: Error, Equatable, LocalizedError, Sendable {
    case projectNotFound(String)
    case definitionNotFound(String)
    case projectMismatch
    case duplicateStableID(String)
    case invalidDeltaProject
    case baseRevisionMismatch(expected: Int, actual: Int)
    case negativeRevision
    case invalidRevisionRange
    case invalidPayload
    case governanceRequired(String)
    case invalidCluster(String)
    case persistenceFailure(String)

    public var errorDescription: String? {
        switch self {
        case .projectNotFound(let id): "Project not found: \(id)"
        case .definitionNotFound(let id): "Definition not found: \(id)"
        case .projectMismatch: "The record does not belong to the requested project."
        case .duplicateStableID(let id): "Duplicate stable ID: \(id)"
        case .invalidDeltaProject: "The delta project does not match the requested project."
        case .baseRevisionMismatch(let expected, let actual): "Base revision mismatch. Expected \(expected), got \(actual)."
        case .negativeRevision: "Revision cannot be negative."
        case .invalidRevisionRange: "Target revision must be greater than or equal to the base revision."
        case .invalidPayload: "The persisted payload could not be decoded."
        case .governanceRequired(let detail): "Human approval is required before saving this change: \(detail)"
        case .invalidCluster(let detail): "Invalid cluster: \(detail)"
        case .persistenceFailure(let message): message
        }
    }
}

enum RepositoryWritePolicy {
    private static let editableKeys = [
        "canonical_name",
        "display_name",
        "kind",
        "symbol",
        "func",
        "file",
        "domain",
        "purpose"
    ]

    private static let protectedStateKeys = [
        "identity",
        "function",
        "code_locator",
        "functional_locator",
        "relations",
        "lineage"
    ]

    static func requiredProposalActions(from _: Definition, to _: Definition) -> [ProposalAction] { [] }

    static func editableValues(for definition: Definition) -> [String: String] {
        [
            "canonical_name": definition.identity.canonicalName,
            "display_name": definition.identity.displayName,
            "kind": definition.identity.kind.rawValue,
            "symbol": definition.codeLocator.symbol,
            "func": definition.codeLocator.function,
            "file": definition.codeLocator.file,
            "domain": definition.function.domain,
            "purpose": definition.function.purpose
        ]
    }

    static func applyingEditableValues(_ values: [String: String], to definition: Definition) -> Definition {
        var updated = definition
        if let value = values["canonical_name"] { updated.identity.canonicalName = value }
        if let value = values["display_name"] { updated.identity.displayName = value }
        if let value = values["kind"], let kind = DefinitionKind(rawValue: value) {
            updated.identity.kind = kind
        }
        if let value = values["symbol"] { updated.codeLocator.symbol = value }
        if let value = values["func"] { updated.codeLocator.function = value }
        if let value = values["file"] { updated.codeLocator.file = value }
        if let value = values["domain"] { updated.function.domain = value }
        if let value = values["purpose"] { updated.function.purpose = value }
        updated.updatedAt = Date()
        return updated
    }

    /// Serializes exactly the structural state protected by a Change Request.
    /// Dates, derived heat/lifecycle values, and active-context state are
    /// intentionally excluded so an approved request remains stable while
    /// runtime bookkeeping changes.
    static func protectedChangePayload(for definition: Definition) -> [String: String] {
        [
            "identity": encoded(definition.identity),
            "function": encoded(definition.function),
            "code_locator": encoded(definition.codeLocator),
            "functional_locator": encoded(definition.functionalLocator),
            "relations": encoded(definition.relations),
            "lineage": encoded(definition.lineage)
        ].merging(editableValues(for: definition)) { _, new in new }
    }

    static func matchesApprovedProposal(
        _ proposal: Proposal,
        action: ProposalAction,
        existing: Definition,
        candidate: Definition
    ) -> Bool {
        guard (proposal.status == .approved || proposal.status == .adjusted),
              proposal.action == action,
              proposal.definitionIDs.contains(candidate.id) else {
            return false
        }
        guard action == .identityChange else { return true }

        let existingValues = editableValues(for: existing)
        let candidateValues = editableValues(for: candidate)
        let changedKeys = editableKeys.filter { existingValues[$0] != candidateValues[$0] }
        guard !changedKeys.isEmpty else { return false }
        return changedKeys.allSatisfy { proposal.payload[$0] == candidateValues[$0] }
    }

    static func matchesApprovedChangeRequest(
        _ request: ChangeRequest,
        existing: Definition,
        candidate: Definition
    ) -> Bool {
        guard request.status == .approved,
              request.projectID == candidate.projectID,
              (request.definitionID == candidate.id || request.affectedDefinitionIDs.contains(candidate.id)) else {
            return false
        }
        let expected = protectedChangePayload(for: candidate)
        for key in protectedStateKeys where key != "lineage" {
            guard request.proposedValues[key] == expected[key] else { return false }
        }
        // Applying an identity Proposal appends lineage entries as engine
        // bookkeeping. A request stays valid while every approved lineage
        // entry is still present; every other protected key must match
        // exactly so an approval cannot be reused for different state.
        guard let approvedLineage = decodeLineage(request.proposedValues["lineage"]),
              let candidateLineage = decodeLineage(expected["lineage"]) else {
            return false
        }
        return Set(approvedLineage).isSubset(of: Set(candidateLineage))
    }

    private static func decodeLineage(_ encodedValue: String?) -> [String]? {
        // A Change Request that does not bind its lineage at all is an
        // incomplete record; refuse it rather than matching unbounded.
        guard let encodedValue,
              let data = encodedValue.data(using: .utf8),
              let lineage = try? JSONCodec.decode([String].self, from: data) else {
            return nil
        }
        return lineage
    }

    /// Stable per-field diffs for every field an approved Proposal or
    /// Change Request can move. Feeds both the ImplementationEvent payload
    /// and the FieldRevision audit entries.
    static func changedFields(from existing: Definition, to candidate: Definition) -> [(field: String, value: String)] {
        var changes: [(field: String, value: String)] = []
        let existingValues = editableValues(for: existing)
        let candidateValues = editableValues(for: candidate)
        for key in editableKeys where existingValues[key] != candidateValues[key] {
            changes.append((field: key, value: candidateValues[key] ?? ""))
        }
        if existing.reviewStatus != candidate.reviewStatus {
            changes.append((field: "review_status", value: candidate.reviewStatus.rawValue))
        }
        if existing.lineage != candidate.lineage {
            changes.append((field: "lineage", value: encoded(candidate.lineage)))
        }
        if existing.functionalLocator != candidate.functionalLocator {
            changes.append((field: "functional_locator", value: encoded(candidate.functionalLocator)))
        }
        if existing.relations != candidate.relations {
            changes.append((field: "relations", value: encoded(candidate.relations)))
        }
        return changes
    }

    /// Full field baseline recorded when a Proposal creates a Definition
    /// (for example the parts produced by a Split).
    static func createdDefinitionBaseline(for definition: Definition) -> [(field: String, value: String)] {
        var changes = editableValues(for: definition)
            .sorted { $0.key < $1.key }
            .map { (field: $0.key, value: $0.value) }
        changes.append((field: "review_status", value: definition.reviewStatus.rawValue))
        changes.append((field: "lineage", value: encoded(definition.lineage)))
        changes.append((field: "code_locator", value: encoded(definition.codeLocator)))
        changes.append((field: "visual_locator", value: encoded(definition.visualLocator)))
        changes.append((field: "functional_locator", value: encoded(definition.functionalLocator)))
        changes.append((field: "function", value: encoded(definition.function)))
        return changes
    }

    static func implementationEvent(
        changeType: String,
        changes: [(field: String, value: String)],
        revision: Int,
        occurredAt: Date = Date()
    ) -> ImplementationEvent {
        let codeKeys: Set<String> = ["symbol", "func", "file"]
        let semanticKeys: Set<String> = [
            "canonical_name", "display_name", "kind",
            "domain", "purpose", "review_status", "lineage",
            "functional_locator", "relations"
        ]
        return ImplementationEvent(
            revision: revision,
            changeType: changeType,
            changes: Dictionary(
                changes.map { ($0.field, $0.value) },
                uniquingKeysWith: { _, new in new }
            ),
            codeImpact: changes.contains { codeKeys.contains($0.field) } ? 1.0 : 0.0,
            semanticImpact: changes.contains { semanticKeys.contains($0.field) } ? 1.0 : 0.0,
            milestone: changeType == ProposalAction.identityChange.rawValue,
            occurredAt: occurredAt
        )
    }

    /// Everything one repository transaction needs to persist a human-approved
    /// governance decision: updated definitions carrying their audit events,
    /// FieldRevision entries and the next project revision. Execution stays in
    /// each repository so all writes land inside that repository's single
    /// rollback boundary.
    struct ApprovedApplicationPlan {
        let auditedDefinitions: [Definition]
        let cluster: Cluster?
        let fieldRevisions: [FieldRevision]
        let newRevision: Int

        var isEmpty: Bool {
            auditedDefinitions.isEmpty && cluster == nil && fieldRevisions.isEmpty
        }
    }

    /// Builds the transaction payload for an approved Proposal.
    static func planApplication(
        of proposal: Proposal,
        definitions: [Definition],
        currentRevision: Int,
        now: Date = Date()
    ) throws -> ApprovedApplicationPlan {
        let application = try GovernanceEngine.applyApproved(proposal, to: definitions)
        let newRevision = currentRevision + 1
        var auditedDefinitions: [Definition] = []
        var fieldRevisions: [FieldRevision] = []
        for updated in application.updatedDefinitions {
            let changes: [(field: String, value: String)]
            if let existing = definitions.first(where: { $0.id == updated.id }) {
                changes = changedFields(from: existing, to: updated)
                guard !changes.isEmpty else { continue }
            } else {
                changes = createdDefinitionBaseline(for: updated)
            }
            var auditedDefinition = updated
            auditedDefinition.implementationHistory.append(
                implementationEvent(
                    changeType: proposal.action.rawValue,
                    changes: changes,
                    revision: newRevision,
                    occurredAt: now
                )
            )
            auditedDefinitions.append(auditedDefinition)
            fieldRevisions.append(contentsOf: changes.map { change in
                FieldRevision(
                    entityID: updated.id,
                    projectID: proposal.projectID,
                    field: change.field,
                    revision: newRevision,
                    source: "proposal:\(proposal.id)",
                    updatedAt: now
                )
            })
        }
        return ApprovedApplicationPlan(
            auditedDefinitions: auditedDefinitions,
            cluster: application.cluster,
            fieldRevisions: fieldRevisions,
            newRevision: newRevision
        )
    }

    /// Builds the transaction payload for an approved Change Request, or
    /// returns `nil` when the request cannot be applied yet: it is not
    /// approved, carries no proposed values, its Definition is missing, or
    /// its identity-bearing change has no payload-bound approved Proposal.
    static func planApplication(
        of request: ChangeRequest,
        proposals: [Proposal],
        definition: Definition?,
        currentRevision: Int,
        now: Date = Date()
    ) throws -> ApprovedApplicationPlan? {
        guard request.status == .approved,
              !request.proposedValues.isEmpty,
              let current = definition else {
            return nil
        }

        let candidate = applyingEditableValues(request.proposedValues, to: current)
        var applied = candidate
        if current.identity != candidate.identity {
            guard let matchingProposal = proposals.first(where: {
                matchesApprovedProposal($0, action: .identityChange, existing: current, candidate: candidate)
            }) else {
                return nil
            }
            let application = try GovernanceEngine.applyApproved(matchingProposal, to: [current])
            guard let identityUpdated = application.updatedDefinitions.first else { return nil }
            applied = identityUpdated
        }

        let changes = changedFields(from: current, to: applied)
        guard !changes.isEmpty else {
            return ApprovedApplicationPlan(
                auditedDefinitions: [],
                cluster: nil,
                fieldRevisions: [],
                newRevision: currentRevision
            )
        }
        let newRevision = currentRevision + 1
        var auditedDefinition = applied
        auditedDefinition.implementationHistory.append(
            implementationEvent(
                changeType: request.requestedChange.type,
                changes: changes,
                revision: newRevision,
                occurredAt: now
            )
        )
        return ApprovedApplicationPlan(
            auditedDefinitions: [auditedDefinition],
            cluster: nil,
            fieldRevisions: changes.map { change in
                FieldRevision(
                    entityID: current.id,
                    projectID: request.projectID,
                    field: change.field,
                    revision: newRevision,
                    source: "change_request:\(request.id)",
                    updatedAt: now
                )
            },
            newRevision: newRevision
        )
    }


    private static func encoded<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONCodec.encode(value) else { return "<encoding-failed>" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Converts Delta field paths into stable per-Definition revision keys.
    /// A producer may prefix a field with its Definition ID, or omit that
    /// prefix when a Delta touches one Definition.
    static func fieldRevisionKeys(for delta: DictionaryDelta) -> [(entityID: String, field: String)] {
        var touchedIDs = Set(delta.definitionsCreated.map(\.id))
        touchedIDs.formUnion(delta.definitionsEvolved.map(\.definitionID))
        touchedIDs.formUnion(delta.fuzzyTermsAdded.map(\.definitionID))
        touchedIDs.formUnion(delta.referencesChanged.map(\.definitionID))
        touchedIDs.formUnion(delta.snapshotsChanged.map(\.definitionID))
        touchedIDs.formUnion(delta.relationsChanged.flatMap { [$0.sourceDefinitionID, $0.targetDefinitionID] })
        touchedIDs.formUnion(delta.relationsRemoved.flatMap { [$0.sourceDefinitionID, $0.targetDefinitionID] })

        var rawFields = delta.changedFields
        rawFields.append(contentsOf: delta.definitionsEvolved.flatMap { $0.changes.keys })
        if !delta.fuzzyTermsAdded.isEmpty { rawFields.append("fuzzy_terms") }
        if !delta.relationsChanged.isEmpty { rawFields.append("relations") }
        if !delta.relationsRemoved.isEmpty { rawFields.append("relations") }
        if !delta.referencesChanged.isEmpty { rawFields.append("references") }
        if !delta.snapshotsChanged.isEmpty { rawFields.append("snapshots") }

        var keys = Set<String>()
        for rawField in rawFields {
            let field = rawField.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !field.isEmpty else { continue }
            let components = field.split(separator: ".", omittingEmptySubsequences: true).map(String.init)
            if let first = components.first, touchedIDs.contains(first), components.count > 1 {
                keys.insert("\(first)|\(components.dropFirst().joined(separator: "."))")
            } else if touchedIDs.count == 1, let onlyID = touchedIDs.first {
                keys.insert("\(onlyID)|\(field)")
            } else {
                for definitionID in touchedIDs {
                    keys.insert("\(definitionID)|\(field)")
                }
            }
        }

        return keys.compactMap { key in
            guard let separator = key.firstIndex(of: "|") else { return nil }
            return (
                entityID: String(key[..<separator]),
                field: String(key[key.index(after: separator)...])
            )
        }.sorted {
            if $0.entityID == $1.entityID { return $0.field < $1.field }
            return $0.entityID < $1.entityID
        }
    }

    static func requiresProtectedChangeRequest(from _: Definition, to _: Definition) -> Bool { false }
}

@MainActor
public final class InMemoryProjectRepository: ProjectScopedRepository {
    private var projectStore: [String: Project] = [:]
    private var definitionStore: [String: Definition] = [:]
    private var clusterStore: [String: Cluster] = [:]
    private var proposalStore: [String: Proposal] = [:]
    private var changeRequestStore: [String: ChangeRequest] = [:]
    private var fieldRevisionStore: [String: [FieldRevision]] = [:]
    private var conflictStore: [String: ConflictRecord] = [:]
    private var appliedDeltaIDs: Set<String> = []
    private var projectRevisions: [String: Int] = [:]

    public init() {}

    public func project(id: String) throws -> Project? {
        projectStore[id]
    }

    public func projects(includeArchived: Bool = false) throws -> [Project] {
        projectStore.values
            .filter { includeArchived || !$0.archived }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(project: Project) throws {
        try DomainValidator.validate(project: project)
        projectStore[project.id] = project
        projectRevisions[project.id, default: 0] = projectRevisions[project.id, default: 0]
    }

    public func archive(projectID: String) throws {
        guard var project = projectStore[projectID] else { throw RepositoryError.projectNotFound(projectID) }
        project.archived = true
        project.updatedAt = Date()
        projectStore[projectID] = project
    }

    public func softDelete(projectID: String) throws {
        guard projectStore[projectID] != nil else { throw RepositoryError.projectNotFound(projectID) }
        try archive(projectID: projectID)
        let definitionIDs = definitionStore.values.filter { $0.projectID == projectID }.map(\.id)
        for id in definitionIDs {
            definitionStore[id]?.reviewStatus = .archived
        }
    }

    public func definitions(in projectID: String) throws -> [Definition] {
        guard projectStore[projectID] != nil else { throw RepositoryError.projectNotFound(projectID) }
        return definitionStore.values
            .filter { $0.projectID == projectID && $0.reviewStatus != .archived }
            .sorted { $0.identity.canonicalName.localizedStandardCompare($1.identity.canonicalName) == .orderedAscending }
    }

    public func definition(id: String, in projectID: String) throws -> Definition? {
        guard let definition = definitionStore[id] else { return nil }
        guard definition.projectID == projectID else { throw RepositoryError.projectMismatch }
        return definition.reviewStatus == .archived ? nil : definition
    }

    public func save(definition: Definition, in projectID: String) throws {
        try DomainValidator.validate(definition: definition, projectID: projectID)
        guard projectStore[projectID] != nil else { throw RepositoryError.projectNotFound(projectID) }
        if let existing = definitionStore[definition.id] {
            if existing.reviewStatus == .archived && definition.reviewStatus != .archived {
                throw RepositoryError.duplicateStableID(definition.id)
            }
            for action in RepositoryWritePolicy.requiredProposalActions(from: existing, to: definition)
                where !hasApprovedProposal(
                    for: definition.id,
                    action: action,
                    existing: existing,
                    candidate: definition,
                    in: projectID
                ) {
                throw RepositoryError.governanceRequired(
                    action == .identityChange ? "an approved identity_change Proposal" : "an approved Proposal"
                )
            }
            if RepositoryWritePolicy.requiresProtectedChangeRequest(from: existing, to: definition),
               !hasApprovedChangeRequest(
                   for: definition.id,
                   existing: existing,
                   candidate: definition,
                   in: projectID
               ) {
                throw RepositoryError.governanceRequired("an approved Change Request")
            }
        }
        if let existing = definitionStore[definition.id], existing.projectID != projectID {
            throw RepositoryError.duplicateStableID(definition.id)
        }
        definitionStore[definition.id] = definition
    }

    public func softDelete(definitionID: String, in projectID: String) throws {
        guard var definition = try definition(id: definitionID, in: projectID) else {
            throw RepositoryError.definitionNotFound(definitionID)
        }
        definition.reviewStatus = .archived
        definition.updatedAt = Date()
        definitionStore[definitionID] = definition
    }

    public func clusters(in projectID: String) throws -> [Cluster] {
        try ensureProject(projectID)
        return clusterStore.values.filter { $0.projectID == projectID }.sorted { $0.name < $1.name }
    }

    public func save(cluster: Cluster, in projectID: String) throws {
        try ensureProject(projectID)
        guard cluster.projectID == projectID else { throw RepositoryError.projectMismatch }
        guard IdentifierValidator.isValid(cluster.id, prefix: "cluster_"),
              !cluster.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cluster.definitionIDs.count >= 2,
              Set(cluster.definitionIDs).count == cluster.definitionIDs.count,
              cluster.definitionIDs.contains(cluster.primaryDefinitionID) else {
            throw RepositoryError.invalidCluster(cluster.id)
        }
        let knownDefinitionIDs = Set(definitionStore.values.filter { $0.projectID == projectID }.map(\.id))
        guard cluster.definitionIDs.allSatisfy({ knownDefinitionIDs.contains($0) }) else {
            throw RepositoryError.invalidCluster(cluster.id)
        }
        if [.approved, .adjusted].contains(cluster.status),
           !hasApprovedClusterProposal(cluster, in: projectID) {
            throw RepositoryError.governanceRequired("an approved cluster Proposal")
        }
        clusterStore[cluster.id] = cluster
    }

    public func proposals(in projectID: String) throws -> [Proposal] {
        try ensureProject(projectID)
        return proposalStore.values
            .filter { $0.projectID == projectID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func pendingProposals(in projectID: String) throws -> [Proposal] {
        try proposals(in: projectID).filter { $0.status == .pending }
    }

    public func save(proposal: Proposal, in projectID: String) throws {
        try ensureProject(projectID)
        guard proposal.projectID == projectID else { throw RepositoryError.projectMismatch }
        proposalStore[proposal.id] = proposal
    }

    public func changeRequests(in projectID: String) throws -> [ChangeRequest] {
        try ensureProject(projectID)
        return changeRequestStore.values
            .filter { $0.projectID == projectID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    public func pendingChangeRequests(in projectID: String) throws -> [ChangeRequest] {
        try changeRequests(in: projectID).filter { $0.status == .pending }
    }

    public func save(changeRequest: ChangeRequest, in projectID: String) throws {
        try ensureProject(projectID)
        guard changeRequest.projectID == projectID else { throw RepositoryError.projectMismatch }
        changeRequestStore[changeRequest.id] = changeRequest
    }

    public func fieldRevisions(for entityID: String, in projectID: String) throws -> [FieldRevision] {
        try ensureProject(projectID)
        return fieldRevisionStore[entityID, default: []].filter { $0.projectID == projectID }
    }

    public func save(fieldRevision: FieldRevision) throws {
        try ensureProject(fieldRevision.projectID)
        fieldRevisionStore[fieldRevision.entityID, default: []].append(fieldRevision)
    }

    public func conflicts(in projectID: String) throws -> [ConflictRecord] {
        try ensureProject(projectID)
        return conflictStore.values.filter { $0.projectID == projectID }
    }

    public func save(conflict: ConflictRecord) throws {
        try ensureProject(conflict.projectID)
        conflictStore[conflict.id] = conflict
    }

    public func apply(delta: DictionaryDelta, in projectID: String) throws -> DeltaApplyResult {
        try DictionarySchemaValidator.validate(delta: delta)
        try ensureProject(projectID)
        guard delta.projectID == projectID else { throw RepositoryError.invalidDeltaProject }
        guard delta.baseRevision >= 0, delta.targetRevision >= 0 else { throw RepositoryError.negativeRevision }
        guard delta.targetRevision >= delta.baseRevision else { throw RepositoryError.invalidRevisionRange }
        if appliedDeltaIDs.contains(delta.deltaID) {
            return DeltaApplyResult(
                imported: false,
                alreadyApplied: true,
                newRevision: projectRevisions[projectID, default: 0],
                conflictCount: 0
            )
        }

        let currentRevision = projectRevisions[projectID, default: 0]
        guard delta.baseRevision == currentRevision else {
            throw RepositoryError.baseRevisionMismatch(expected: currentRevision, actual: delta.baseRevision)
        }

        let originalDefinitions = definitionStore
        let originalProposals = proposalStore
        let originalRequests = changeRequestStore
        let originalConflicts = conflictStore
        let originalFieldRevisions = fieldRevisionStore

        do {
            for proposal in delta.proposals { try save(proposal: proposal, in: projectID) }
            for request in delta.changeRequests { try save(changeRequest: request, in: projectID) }
            for conflict in delta.conflictRecords { try save(conflict: conflict) }
            for definition in delta.definitionsCreated {
                guard definitionStore[definition.id] == nil else {
                    throw RepositoryError.duplicateStableID(definition.id)
                }
                try save(definition: definition, in: projectID)
            }
            for evolution in delta.definitionsEvolved {
                guard var definition = try definition(id: evolution.definitionID, in: projectID) else {
                    throw RepositoryError.definitionNotFound(evolution.definitionID)
                }
                definition = evolution.applying(to: definition)
                definition.implementationHistory.append(
                    ImplementationEvent(
                        revision: delta.targetRevision,
                        changeType: evolution.changeType,
                        changes: evolution.changes,
                        codeImpact: evolution.codeImpact,
                        semanticImpact: evolution.semanticImpact,
                        milestone: evolution.milestone,
                        occurredAt: delta.createdAt
                    )
                )
                definition.updatedAt = delta.createdAt
                try save(definition: definition, in: projectID)
            }
            for change in delta.fuzzyTermsAdded {
                guard var definition = try definition(id: change.definitionID, in: projectID) else {
                    throw RepositoryError.definitionNotFound(change.definitionID)
                }
                if !definition.fuzzyTerms.contains(where: { $0.id == change.term.id }) {
                    definition.fuzzyTerms.append(change.term)
                    definition.updatedAt = delta.createdAt
                    try save(definition: definition, in: projectID)
                }
            }
            for relation in delta.relationsChanged {
                guard var source = try definition(id: relation.sourceDefinitionID, in: projectID) else {
                    throw RepositoryError.definitionNotFound(relation.sourceDefinitionID)
                }
                guard try definition(id: relation.targetDefinitionID, in: projectID) != nil else {
                    throw RepositoryError.definitionNotFound(relation.targetDefinitionID)
                }
                if let index = source.relations.firstIndex(where: { $0.id == relation.id }) {
                    source.relations[index] = relation
                } else {
                    source.relations.append(relation)
                }
                source.implementationHistory.append(
                    ImplementationEvent(
                        revision: delta.targetRevision,
                        changeType: "relation_changed",
                        changes: relation.historyChanges,
                        codeImpact: 0.1,
                        semanticImpact: 0.1,
                        milestone: false,
                        occurredAt: delta.createdAt
                    )
                )
                source.updatedAt = delta.createdAt
                try save(definition: source, in: projectID)
            }
            for relation in delta.relationsRemoved {
                guard var source = try definition(id: relation.sourceDefinitionID, in: projectID),
                      let index = source.relations.firstIndex(where: { $0.id == relation.id }),
                      source.relations[index].targetDefinitionID == relation.targetDefinitionID else {
                    throw RepositoryError.invalidPayload
                }
                source.relations.remove(at: index)
                source.implementationHistory.append(
                    ImplementationEvent(
                        revision: delta.targetRevision,
                        changeType: "relation_removed",
                        changes: relation.historyChanges,
                        codeImpact: 0.1,
                        semanticImpact: 0.1,
                        milestone: false,
                        occurredAt: delta.createdAt
                    )
                )
                source.updatedAt = delta.createdAt
                try save(definition: source, in: projectID)
            }
            for change in delta.referencesChanged {
                guard var definition = try definition(id: change.definitionID, in: projectID) else {
                    throw RepositoryError.definitionNotFound(change.definitionID)
                }
                if let index = definition.references.firstIndex(where: { $0.id == change.reference.id }) {
                    definition.references[index] = change.reference
                } else {
                    definition.references.append(change.reference)
                }
                definition.updatedAt = delta.createdAt
                try save(definition: definition, in: projectID)
            }
            for change in delta.snapshotsChanged {
                guard var definition = try definition(id: change.definitionID, in: projectID) else {
                    throw RepositoryError.definitionNotFound(change.definitionID)
                }
                if let index = definition.snapshots.firstIndex(where: { $0.id == change.snapshot.id }) {
                    definition.snapshots[index] = change.snapshot
                } else {
                    definition.snapshots.append(change.snapshot)
                }
                definition.updatedAt = delta.createdAt
                try save(definition: definition, in: projectID)
            }
            for key in RepositoryWritePolicy.fieldRevisionKeys(for: delta) {
                try save(
                    fieldRevision: FieldRevision(
                        entityID: key.entityID,
                        projectID: projectID,
                        field: key.field,
                        revision: delta.targetRevision,
                        source: "delta:\(delta.deltaID)",
                        updatedAt: delta.createdAt
                    )
                )
            }
        } catch {
            definitionStore = originalDefinitions
            proposalStore = originalProposals
            changeRequestStore = originalRequests
            conflictStore = originalConflicts
            fieldRevisionStore = originalFieldRevisions
            throw error
        }

        projectRevisions[projectID] = delta.targetRevision
        appliedDeltaIDs.insert(delta.deltaID)
        return DeltaApplyResult(
            imported: true,
            alreadyApplied: false,
            newRevision: delta.targetRevision,
            conflictCount: delta.conflictRecords.count
        )
    }

    public func apply(approved proposal: Proposal, in projectID: String) throws -> Bool {
        try ensureProject(projectID)
        guard proposal.projectID == projectID else { throw RepositoryError.projectMismatch }
        let plan = try RepositoryWritePolicy.planApplication(
            of: proposal,
            definitions: try definitions(in: projectID),
            currentRevision: try currentRevision(in: projectID)
        )
        return try execute(plan: plan, revisionMarkerID: proposal.id, in: projectID)
    }

    public func apply(approved request: ChangeRequest, in projectID: String) throws -> Bool {
        try ensureProject(projectID)
        guard request.projectID == projectID else { throw RepositoryError.projectMismatch }
        guard let plan = try RepositoryWritePolicy.planApplication(
            of: request,
            proposals: try proposals(in: projectID),
            definition: try definition(id: request.definitionID, in: projectID),
            currentRevision: try currentRevision(in: projectID)
        ) else { return false }
        return try execute(plan: plan, revisionMarkerID: request.id, in: projectID)
    }

    /// Persists one approved-application plan atomically. A governance
    /// rejection rolls the whole plan back and reports "not applied" so
    /// the caller can wait for the paired governance record.
    private func execute(
        plan: RepositoryWritePolicy.ApprovedApplicationPlan,
        revisionMarkerID: String,
        in projectID: String
    ) throws -> Bool {
        guard !plan.isEmpty else { return true }
        let originalDefinitions = definitionStore
        let originalClusters = clusterStore
        let originalFieldRevisions = fieldRevisionStore
        do {
            for definition in plan.auditedDefinitions {
                try save(definition: definition, in: projectID)
            }
            if let cluster = plan.cluster {
                try save(cluster: cluster, in: projectID)
            }
            for revision in plan.fieldRevisions {
                try save(fieldRevision: revision)
            }
            projectRevisions[projectID] = plan.newRevision
            return true
        } catch let error as RepositoryError {
            definitionStore = originalDefinitions
            clusterStore = originalClusters
            fieldRevisionStore = originalFieldRevisions
            if case .governanceRequired = error { return false }
            throw error
        }
    }

    public func currentRevision(in projectID: String) throws -> Int {
        try ensureProject(projectID)
        return projectRevisions[projectID, default: 0]
    }

    public func setCurrentRevision(_ revision: Int, for projectID: String) throws {
        try ensureProject(projectID)
        guard revision >= 0 else { throw RepositoryError.negativeRevision }
        projectRevisions[projectID] = revision
    }

    private func ensureProject(_ projectID: String) throws {
        guard projectStore[projectID] != nil else { throw RepositoryError.projectNotFound(projectID) }
    }

    private func hasApprovedProposal(
        for definitionID: String,
        action: ProposalAction,
        existing: Definition,
        candidate: Definition,
        in projectID: String
    ) -> Bool {
        proposalStore.values.contains {
            $0.projectID == projectID
                && RepositoryWritePolicy.matchesApprovedProposal(
                    $0,
                    action: action,
                    existing: existing,
                    candidate: candidate
                )
        }
    }

    private func hasApprovedChangeRequest(
        for definitionID: String,
        existing: Definition,
        candidate: Definition,
        in projectID: String
    ) -> Bool {
        changeRequestStore.values.contains {
            $0.projectID == projectID
                && RepositoryWritePolicy.matchesApprovedChangeRequest(
                    $0,
                    existing: existing,
                    candidate: candidate
                )
        }
    }

    private func hasApprovedClusterProposal(_ cluster: Cluster, in projectID: String) -> Bool {
        proposalStore.values.contains {
            ($0.status == .approved || $0.status == .adjusted)
                && $0.projectID == projectID
                && $0.action == .cluster
                && Set($0.definitionIDs) == Set(cluster.definitionIDs)
        }
    }
}
