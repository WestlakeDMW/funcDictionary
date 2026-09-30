import CoreData
import Foundation

@MainActor
public final class CoreDataProjectRepository: ProjectScopedRepository {
    private let persistence: PersistenceController
    private var isApplyingDelta = false

    private struct AppliedDeltaMarker: Codable {
        let deltaID: String
        let targetRevision: Int
        let appliedAt: Date
    }

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    public func project(id: String) throws -> Project? {
        let records = try fetchRecords(kind: "project", projectID: id, includeDeleted: false)
        guard let record = records.first else { return nil }
        return try decode(Project.self, from: record)
    }

    public func projects(includeArchived: Bool = false) throws -> [Project] {
        let records = try fetchRecords(kind: "project", projectID: nil, includeDeleted: false)
        return try records.compactMap { record -> Project? in
            let project = try decode(Project.self, from: record)
            return includeArchived || !project.archived ? project : nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(project: Project) throws {
        try DomainValidator.validate(project: project)
        try upsert(
            kind: "project",
            stableID: project.id,
            projectID: project.id,
            value: project,
            entityName: "Project"
        )
    }

    public func archive(projectID: String) throws {
        guard var project = try project(id: projectID) else { throw RepositoryError.projectNotFound(projectID) }
        project.archived = true
        project.updatedAt = Date()
        try save(project: project)
    }

    public func softDelete(projectID: String) throws {
        try archive(projectID: projectID)
        let records = try fetchRecords(kind: "definition", projectID: projectID, includeDeleted: false)
        for record in records {
            record.softDeleted = true
        }
        try persist()
    }

    public func definitions(in projectID: String) throws -> [Definition] {
        try ensureProjectExists(projectID)
        return try fetchRecords(kind: "definition", projectID: projectID, includeDeleted: false)
            .map { try decode(Definition.self, from: $0) }
            .filter { $0.reviewStatus != .archived }
            .sorted { $0.identity.canonicalName.localizedStandardCompare($1.identity.canonicalName) == .orderedAscending }
    }

    public func definition(id: String, in projectID: String) throws -> Definition? {
        try ensureProjectExists(projectID)
        let records = try fetchRecords(kind: "definition", projectID: projectID, includeDeleted: false)
            .filter { $0.stableID == id }
        guard let record = records.first else { return nil }
        let definition = try decode(Definition.self, from: record)
        return definition.reviewStatus == .archived ? nil : definition
    }

    public func save(definition: Definition, in projectID: String) throws {
        try DomainValidator.validate(definition: definition, projectID: projectID)
        try ensureProjectExists(projectID)
        let foreignRecord = try fetchRecords(kind: "definition", projectID: nil, includeDeleted: true)
            .first { $0.stableID == definition.id && $0.projectID != projectID }
        if foreignRecord != nil {
            throw RepositoryError.duplicateStableID(definition.id)
        }
        if let existing = try existingDefinitionForWrite(id: definition.id, in: projectID) {
            if existing.reviewStatus == .archived && definition.reviewStatus != .archived {
                throw RepositoryError.duplicateStableID(definition.id)
            }
            for action in RepositoryWritePolicy.requiredProposalActions(from: existing, to: definition)
                where !(try hasApprovedProposal(
                    for: definition.id,
                    action: action,
                    existing: existing,
                    candidate: definition,
                    in: projectID
                )) {
                throw RepositoryError.governanceRequired(
                    action == .identityChange ? "an approved identity_change Proposal" : "an approved Proposal"
                )
            }
            if RepositoryWritePolicy.requiresProtectedChangeRequest(from: existing, to: definition),
               !(try hasApprovedChangeRequest(
                   for: definition.id,
                   existing: existing,
                   candidate: definition,
                   in: projectID
               )) {
                throw RepositoryError.governanceRequired("an approved Change Request")
            }
        }
        try upsert(
            kind: "definition",
            stableID: definition.id,
            projectID: projectID,
            value: definition,
            entityName: "Definition"
        )
    }

    public func softDelete(definitionID: String, in projectID: String) throws {
        try ensureProjectExists(projectID)
        let records = try fetchRecords(kind: "definition", projectID: projectID, includeDeleted: false)
            .filter { $0.stableID == definitionID }
        guard let record = records.first else { throw RepositoryError.definitionNotFound(definitionID) }
        record.softDeleted = true
        try persist()
    }

    public func clusters(in projectID: String) throws -> [Cluster] {
        try ensureProjectExists(projectID)
        return try fetchRecords(kind: "cluster", projectID: projectID, includeDeleted: false)
            .map { try decode(Cluster.self, from: $0) }
            .sorted { $0.name < $1.name }
    }

    public func save(cluster: Cluster, in projectID: String) throws {
        try ensureProjectExists(projectID)
        guard cluster.projectID == projectID else { throw RepositoryError.projectMismatch }
        guard IdentifierValidator.isValid(cluster.id, prefix: "cluster_"),
              !cluster.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cluster.definitionIDs.count >= 2,
              Set(cluster.definitionIDs).count == cluster.definitionIDs.count,
              cluster.definitionIDs.contains(cluster.primaryDefinitionID) else {
            throw RepositoryError.invalidCluster(cluster.id)
        }
        let knownDefinitionIDs = Set(try definitions(in: projectID).map(\.id))
        guard cluster.definitionIDs.allSatisfy({ knownDefinitionIDs.contains($0) }) else {
            throw RepositoryError.invalidCluster(cluster.id)
        }
        if [.approved, .adjusted].contains(cluster.status),
           !(try hasApprovedClusterProposal(cluster, in: projectID)) {
            throw RepositoryError.governanceRequired("an approved cluster Proposal")
        }
        try upsert(kind: "cluster", stableID: cluster.id, projectID: projectID, value: cluster, entityName: "Cluster")
    }

    public func proposals(in projectID: String) throws -> [Proposal] {
        try allProposals(in: projectID).sorted { $0.createdAt < $1.createdAt }
    }

    public func pendingProposals(in projectID: String) throws -> [Proposal] {
        try proposals(in: projectID).filter { $0.status == .pending }
    }

    public func save(proposal: Proposal, in projectID: String) throws {
        try ensureProjectExists(projectID)
        guard proposal.projectID == projectID else { throw RepositoryError.projectMismatch }
        try upsert(kind: "proposal", stableID: proposal.id, projectID: projectID, value: proposal, entityName: "Proposal")
    }

    public func changeRequests(in projectID: String) throws -> [ChangeRequest] {
        try allChangeRequests(in: projectID).sorted { $0.createdAt < $1.createdAt }
    }

    public func pendingChangeRequests(in projectID: String) throws -> [ChangeRequest] {
        try changeRequests(in: projectID).filter { $0.status == .pending }
    }

    public func save(changeRequest: ChangeRequest, in projectID: String) throws {
        try ensureProjectExists(projectID)
        guard changeRequest.projectID == projectID else { throw RepositoryError.projectMismatch }
        try upsert(kind: "change_request", stableID: changeRequest.id, projectID: projectID, value: changeRequest, entityName: "ChangeRequest")
    }

    public func fieldRevisions(for entityID: String, in projectID: String) throws -> [FieldRevision] {
        try ensureProjectExists(projectID)
        return try fetchRecords(kind: "field_revision", projectID: projectID, includeDeleted: false)
            .compactMap { record in
                guard record.stableID?.hasPrefix(entityID + "|") == true else { return nil }
                return try? decode(FieldRevision.self, from: record)
            }
    }

    public func save(fieldRevision: FieldRevision) throws {
        try ensureProjectExists(fieldRevision.projectID)
        let stableID = "\(fieldRevision.entityID)|\(fieldRevision.field)|\(fieldRevision.revision)"
        try upsert(kind: "field_revision", stableID: stableID, projectID: fieldRevision.projectID, value: fieldRevision, entityName: "FieldRevision")
    }

    public func conflicts(in projectID: String) throws -> [ConflictRecord] {
        try ensureProjectExists(projectID)
        return try fetchRecords(kind: "conflict", projectID: projectID, includeDeleted: false)
            .map { try decode(ConflictRecord.self, from: $0) }
    }

    public func save(conflict: ConflictRecord) throws {
        try ensureProjectExists(conflict.projectID)
        try upsert(kind: "conflict", stableID: conflict.id, projectID: conflict.projectID, value: conflict, entityName: "ConflictRecord")
    }

    public func currentRevision(in projectID: String) throws -> Int {
        try ensureProjectExists(projectID)
        return try persistedRevision(in: projectID)
    }

    public func apply(delta: DictionaryDelta, in projectID: String) throws -> DeltaApplyResult {
        try DictionarySchemaValidator.validate(delta: delta)
        try ensureProjectExists(projectID)
        guard delta.projectID == projectID else { throw RepositoryError.invalidDeltaProject }
        let currentRevision = try persistedRevision(in: projectID)
        if let marker = try appliedDeltaMarker(deltaID: delta.deltaID, in: projectID) {
            return DeltaApplyResult(
                imported: false,
                alreadyApplied: true,
                newRevision: max(currentRevision, marker.targetRevision),
                conflictCount: 0
            )
        }
        guard delta.baseRevision >= 0, delta.targetRevision >= 0 else { throw RepositoryError.negativeRevision }
        guard delta.targetRevision >= delta.baseRevision else { throw RepositoryError.invalidRevisionRange }
        guard delta.baseRevision == currentRevision else {
            throw RepositoryError.baseRevisionMismatch(expected: currentRevision, actual: delta.baseRevision)
        }

        let memoryAdapter = InMemoryProjectRepository()
        if let existingProject = try project(id: projectID) { try memoryAdapter.save(project: existingProject) }
        for definition in try definitions(in: projectID) { try memoryAdapter.save(definition: definition, in: projectID) }
        // The in-memory preflight must see the complete governance history.
        // Copying only pending records makes an already-approved protected
        // evolution look unapproved before the real Core Data transaction runs.
        for proposal in try allProposals(in: projectID) { try memoryAdapter.save(proposal: proposal, in: projectID) }
        for request in try allChangeRequests(in: projectID) { try memoryAdapter.save(changeRequest: request, in: projectID) }
        for proposal in delta.proposals { try memoryAdapter.save(proposal: proposal, in: projectID) }
        for request in delta.changeRequests { try memoryAdapter.save(changeRequest: request, in: projectID) }
        try memoryAdapter.setCurrentRevision(currentRevision, for: projectID)
        let result = try memoryAdapter.apply(delta: delta, in: projectID)
        guard result.imported else { return result }

        isApplyingDelta = true
        do {
            // Governance records must exist before any associated definition
            // write is evaluated, while the whole operation remains inside
            // the same Core Data rollback boundary.
            for proposal in delta.proposals { try save(proposal: proposal, in: projectID) }
            for request in delta.changeRequests { try save(changeRequest: request, in: projectID) }
            for conflict in delta.conflictRecords { try save(conflict: conflict) }
            for definition in delta.definitionsCreated {
                guard try self.definition(id: definition.id, in: projectID) == nil else {
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
            let marker = AppliedDeltaMarker(
                deltaID: delta.deltaID,
                targetRevision: delta.targetRevision,
                appliedAt: delta.createdAt
            )
            try upsert(
                kind: "applied_delta",
                stableID: delta.deltaID,
                projectID: projectID,
                value: marker,
                entityName: "Definition"
            )
            try persistence.saveIfNeeded()
            isApplyingDelta = false
            return result
        } catch {
            isApplyingDelta = false
            persistence.viewContext.rollback()
            throw error
        }
    }

    public func apply(approved proposal: Proposal, in projectID: String) throws -> Bool {
        try ensureProjectExists(projectID)
        guard proposal.projectID == projectID else { throw RepositoryError.projectMismatch }
        let plan = try RepositoryWritePolicy.planApplication(
            of: proposal,
            definitions: try definitions(in: projectID),
            currentRevision: try currentRevision(in: projectID)
        )
        return try execute(plan: plan, revisionMarkerID: proposal.id, in: projectID)
    }

    public func apply(approved request: ChangeRequest, in projectID: String) throws -> Bool {
        try ensureProjectExists(projectID)
        guard request.projectID == projectID else { throw RepositoryError.projectMismatch }
        guard let plan = try RepositoryWritePolicy.planApplication(
            of: request,
            proposals: try proposals(in: projectID),
            definition: try definition(id: request.definitionID, in: projectID),
            currentRevision: try currentRevision(in: projectID)
        ) else { return false }
        return try execute(plan: plan, revisionMarkerID: request.id, in: projectID)
    }

    /// Persists one approved-application plan inside a single Core Data
    /// rollback boundary. A governance rejection rolls everything back and
    /// reports "not applied" so the caller can wait for the paired record.
    private func execute(
        plan: RepositoryWritePolicy.ApprovedApplicationPlan,
        revisionMarkerID: String,
        in projectID: String
    ) throws -> Bool {
        guard !plan.isEmpty else { return true }
        isApplyingDelta = true
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
            // The applied-delta marker storage doubles as the monotonic
            // project revision log; each governance decision moves the
            // revision exactly like an imported delta does.
            try upsert(
                kind: "applied_delta",
                stableID: revisionMarkerID,
                projectID: projectID,
                value: AppliedDeltaMarker(
                    deltaID: revisionMarkerID,
                    targetRevision: plan.newRevision,
                    appliedAt: Date()
                ),
                entityName: "Definition"
            )
            try persistence.saveIfNeeded()
            isApplyingDelta = false
            return true
        } catch {
            isApplyingDelta = false
            persistence.viewContext.rollback()
            if let repositoryError = error as? RepositoryError,
               case .governanceRequired = repositoryError {
                return false
            }
            throw error
        }
    }

    private func ensureProjectExists(_ projectID: String) throws {
        guard try project(id: projectID) != nil else { throw RepositoryError.projectNotFound(projectID) }
    }

    private func existingDefinitionForWrite(id: String, in projectID: String) throws -> Definition? {
        let records = try fetchRecords(kind: "definition", projectID: projectID, includeDeleted: true)
        guard let record = records.first(where: { $0.stableID == id }) else { return nil }
        return try decode(Definition.self, from: record)
    }

    private func hasApprovedProposal(
        for definitionID: String,
        action: ProposalAction,
        existing: Definition,
        candidate: Definition,
        in projectID: String
    ) throws -> Bool {
        let records = try fetchRecords(kind: "proposal", projectID: projectID, includeDeleted: false)
        let proposals = records.compactMap { try? decode(Proposal.self, from: $0) }
        return proposals.contains {
            $0.projectID == projectID
                && RepositoryWritePolicy.matchesApprovedProposal(
                    $0,
                    action: action,
                    existing: existing,
                    candidate: candidate
                )
        }
    }

    private func allProposals(in projectID: String) throws -> [Proposal] {
        try ensureProjectExists(projectID)
        return try fetchRecords(kind: "proposal", projectID: projectID, includeDeleted: false)
            .compactMap { try? decode(Proposal.self, from: $0) }
    }

    private func allChangeRequests(in projectID: String) throws -> [ChangeRequest] {
        try ensureProjectExists(projectID)
        return try fetchRecords(kind: "change_request", projectID: projectID, includeDeleted: false)
            .compactMap { try? decode(ChangeRequest.self, from: $0) }
    }

    private func hasApprovedChangeRequest(
        for definitionID: String,
        existing: Definition,
        candidate: Definition,
        in projectID: String
    ) throws -> Bool {
        let records = try fetchRecords(kind: "change_request", projectID: projectID, includeDeleted: false)
        let requests = records.compactMap { try? decode(ChangeRequest.self, from: $0) }
        return requests.contains {
            RepositoryWritePolicy.matchesApprovedChangeRequest(
                $0,
                existing: existing,
                candidate: candidate
            )
        }
    }

    private func fetchRecords(kind: String, projectID: String?, includeDeleted: Bool) throws -> [CDRecord] {
        let request = NSFetchRequest<CDRecord>(entityName: kind == "project" ? "Project" : entityName(for: kind))
        var predicates: [NSPredicate] = [NSPredicate(format: "recordKind == %@", kind)]
        if let projectID { predicates.append(NSPredicate(format: "projectID == %@", projectID)) }
        if !includeDeleted { predicates.append(NSPredicate(format: "softDeleted == NO")) }
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        return try perform { try persistence.viewContext.fetch(request) }
    }

    private func upsert<T: Codable>(kind: String, stableID: String, projectID: String, value: T, entityName: String) throws {
        let request = NSFetchRequest<CDRecord>(entityName: entityName)
        request.fetchLimit = 1
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "stableID == %@", stableID),
            NSPredicate(format: "projectID == %@", projectID),
            NSPredicate(format: "recordKind == %@", kind)
        ])
        let record = try perform {
            if let existing = try persistence.viewContext.fetch(request).first { return existing }
            let newRecord = try makeRecord(entityName: entityName)
            newRecord.stableID = stableID
            newRecord.projectID = projectID
            newRecord.recordKind = kind
            return newRecord
        }
        record.schemaVersion = SchemaVersion.current
        record.createdAt = record.createdAt ?? Date()
        record.updatedAt = Date()
        record.softDeleted = false
        record.payload = try JSONCodec.encode(value)
        try persist()
    }

    private func decode<T: Decodable>(_ type: T.Type, from record: CDRecord) throws -> T {
        guard let payload = record.payload else { throw RepositoryError.invalidPayload }
        do { return try JSONCodec.decode(type, from: payload) }
        catch { throw RepositoryError.persistenceFailure(error.localizedDescription) }
    }

    private func entityName(for kind: String) -> String {
        switch kind {
        case "definition": "Definition"
        case "cluster": "Cluster"
        case "proposal": "Proposal"
        case "change_request": "ChangeRequest"
        case "field_revision": "FieldRevision"
        case "conflict": "ConflictRecord"
        default: "Definition"
        }
    }

    private func hasApprovedClusterProposal(_ cluster: Cluster, in projectID: String) throws -> Bool {
        let records = try fetchRecords(kind: "proposal", projectID: projectID, includeDeleted: false)
        let proposals = records.compactMap { try? decode(Proposal.self, from: $0) }
        return proposals.contains {
            ($0.status == .approved || $0.status == .adjusted)
                && $0.action == .cluster
                && Set($0.definitionIDs) == Set(cluster.definitionIDs)
        }
    }

    private func makeRecord(entityName: String) throws -> CDRecord {
        guard let record = NSEntityDescription.insertNewObject(
            forEntityName: entityName,
            into: persistence.viewContext
        ) as? CDRecord else {
            throw RepositoryError.persistenceFailure("Unsupported Core Data entity: \(entityName)")
        }
        return record
    }

    private func appliedDeltaMarker(deltaID: String, in projectID: String) throws -> AppliedDeltaMarker? {
        let records = try fetchRecords(kind: "applied_delta", projectID: projectID, includeDeleted: false)
            .filter { $0.stableID == deltaID }
        guard let record = records.first else { return nil }
        return try decode(AppliedDeltaMarker.self, from: record)
    }

    private func persistedRevision(in projectID: String) throws -> Int {
        try fetchRecords(kind: "applied_delta", projectID: projectID, includeDeleted: false)
            .compactMap { try? decode(AppliedDeltaMarker.self, from: $0).targetRevision }
            .max() ?? 0
    }

    private func persist() throws {
        guard !isApplyingDelta else { return }
        try persistence.saveIfNeeded()
    }

    private func perform<T>(_ block: () throws -> T) throws -> T {
        // The repository and the view context are both main-actor isolated.
        // Keeping this helper synchronous also avoids crossing Core Data's
        // queue boundary with non-Sendable domain values.
        return try block()
    }
}
