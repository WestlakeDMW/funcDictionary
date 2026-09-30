import Foundation

public enum JSONCodec {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in try encodeDate(date, into: encoder) }
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { try decodeDate(from: $0) }
        decoder.keyDecodingStrategy = .custom { path in
            let rawKey = path.last?.stringValue ?? ""
            // Evolution change keys are schema paths (e.g.
            // "code_locator.func_comment"), not data keys; they must survive
            // verbatim so DefinitionEvolution.applying can match its cases.
            if path.count >= 2, path[path.count - 2].stringValue == "changes" {
                return DynamicCodingKey(stringValue: rawKey)
            }
            switch rawKey {
            case "func", "current_func", "current_function":
                return DynamicCodingKey(stringValue: rawKey == "func" ? "function" : "currentFunction")
            default:
                return DynamicCodingKey(stringValue: Self.camelCaseKey(rawKey))
            }
        }
        return try decoder.decode(type, from: data)
    }

    private static func encodeDate(_ date: Date, into encoder: Encoder) throws {
        let seconds = date.timeIntervalSince1970
        var wholeSeconds = floor(seconds)
        let fractionalSeconds = seconds - wholeSeconds
        var fractionText = String(format: "%.17f", fractionalSeconds)
            .dropFirst(2)
        if fractionText.allSatisfy({ $0 == "9" }) {
            wholeSeconds += 1
            fractionText = String(repeating: "0", count: 17)[...]
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let base = formatter.string(from: Date(timeIntervalSince1970: wholeSeconds))
        var container = encoder.singleValueContainer()
        let timezone = base.last == "Z" ? "Z" : ""
        let baseWithoutTimezone = timezone.isEmpty ? base : String(base.dropLast())
        try container.encode("\(baseWithoutTimezone).\(fractionText)\(timezone)")
    }

    private static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        guard let dot = string.firstIndex(of: ".") else {
            guard let date = formatter.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO-8601 date: \(string)"
                )
            }
            return date
        }

        let fractionAndZone = string[string.index(after: dot)...]
        guard let zoneIndex = fractionAndZone.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 timezone: \(string)"
            )
        }
        let fraction = fractionAndZone[..<zoneIndex]
        let timezone = fractionAndZone[zoneIndex...]
        guard !fraction.isEmpty, fraction.allSatisfy(\.isNumber),
              Double("0.\(fraction)") != nil else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 fractional seconds: \(string)"
            )
        }
        let baseString = String(string[..<dot]) + String(timezone)
        guard let baseDate = formatter.date(from: baseString) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 date: \(string)"
            )
        }
        // Parse the complete epoch value in one Double conversion. Adding a
        // separately parsed fraction to the base date can move the result by
        // one ULP on some Foundation runtimes.
        let wholeSeconds = String(format: "%.0f", baseDate.timeIntervalSince1970)
        guard let exactSeconds = Double("\(wholeSeconds).\(fraction)") else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid ISO-8601 epoch value: \(string)"
            )
        }
        return Date(timeIntervalSince1970: exactSeconds)
    }

    private static func camelCaseKey(_ value: String) -> String {
        let parts = value.split(separator: "_", omittingEmptySubsequences: true)
        guard let first = parts.first else { return value }
        var result = first.lowercased()
        for part in parts.dropFirst() {
            if part == "id" {
                result += "ID"
            } else {
                result += part.prefix(1).uppercased() + part.dropFirst()
            }
        }
        return result
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

public enum ExchangeValidationError: Error, Equatable, LocalizedError, Sendable {
    case unsupportedSchemaVersion(String)
    case invalidProjectID(String)
    case invalidDefinitionID(String)
    case projectMismatch(String)
    case duplicateDefinitionID(String)
    case invalidRevision
    case invalidSnapshotPath(String)
    case invalidSnapshotMetadata(String)
    case invalidCluster(String)
    case invalidRelation(String)
    case invalidEntity(String)
    case invalidAgentContext
    case embeddedBinaryPayload
    case invalidJSON

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let version): "Unsupported schema version: \(version)."
        case .invalidProjectID(let id): "Invalid project ID: \(id)."
        case .invalidDefinitionID(let id): "Invalid definition ID: \(id)."
        case .projectMismatch(let detail): "Project boundary violation: \(detail)."
        case .duplicateDefinitionID(let id): "Duplicate definition ID: \(id)."
        case .invalidRevision: "Revision must be non-negative and target revision cannot be below base revision."
        case .invalidSnapshotPath(let path): "Snapshot path is not a safe relative JPEG path: \(path)."
        case .invalidSnapshotMetadata(let detail): "Invalid snapshot metadata: \(detail)."
        case .invalidCluster(let detail): "Invalid cluster: \(detail)."
        case .invalidRelation(let detail): "Invalid relation: \(detail)."
        case .invalidEntity(let detail): "Invalid exchange entity: \(detail)."
        case .invalidAgentContext: "Agent context does not point to a definition in the same project."
        case .embeddedBinaryPayload: "JSON exchange files must not contain Base64 or data-URI binary payloads."
        case .invalidJSON: "The exchange data is not a JSON object."
        }
    }
}

public enum DictionarySchemaValidator {
    public static func validate(snapshot: ProjectSnapshot) throws {
        try validateSchemaVersion(snapshot.schemaVersion)
        try DomainValidator.validate(project: snapshot.project)
        try validateSchemaVersion(snapshot.project.schemaVersion)
        guard IdentifierValidator.isValid(snapshot.project.id, prefix: "project_") else {
            throw ExchangeValidationError.invalidProjectID(snapshot.project.id)
        }
        guard snapshot.revision >= 0 else { throw ExchangeValidationError.invalidRevision }

        var definitionIDs = Set<String>()
        for definition in snapshot.definitions {
            guard definitionIDs.insert(definition.id).inserted else {
                throw ExchangeValidationError.duplicateDefinitionID(definition.id)
            }
            guard definition.projectID == snapshot.project.id else {
                throw ExchangeValidationError.projectMismatch("definition \(definition.id)")
            }
            try validateSchemaVersion(definition.schemaVersion)
            try DomainValidator.validate(definition: definition, projectID: snapshot.project.id)
            try validateFuzzyTerms(definition.fuzzyTerms, owner: definition.id)
            try validateReferences(definition.references, owner: definition.id)
            try validateHistory(definition.implementationHistory, owner: definition.id)
            try validateSnapshots(definition.snapshots)
        }

        for definition in snapshot.definitions {
            try validateRelations(
                definition.relations,
                projectID: snapshot.project.id,
                knownDefinitionIDs: definitionIDs
            )
        }

        for cluster in snapshot.clusters {
            try validateCluster(cluster, projectID: snapshot.project.id, knownDefinitionIDs: definitionIDs)
        }

        try validateAgentContext(snapshot.agentContext, projectID: snapshot.project.id, knownDefinitionIDs: definitionIDs)

        if !snapshot.agentContext.definitionID.isEmpty {
            guard let definition = snapshot.definitions.first(where: { $0.id == snapshot.agentContext.definitionID }),
                  definition.projectID == snapshot.project.id else {
                throw ExchangeValidationError.invalidAgentContext
            }
        }

        try rejectEmbeddedBinaryPayload(try JSONCodec.encode(snapshot))
    }

    public static func validate(delta: DictionaryDelta) throws {
        try validateSchemaVersion(delta.schemaVersion)
        guard IdentifierValidator.isValid(delta.projectID, prefix: "project_") else {
            throw ExchangeValidationError.invalidProjectID(delta.projectID)
        }
        guard IdentifierValidator.isValid(delta.deltaID, prefix: "delta_") else {
            throw ExchangeValidationError.invalidRevision
        }
        guard delta.baseRevision >= 0,
              delta.targetRevision >= 0,
              delta.targetRevision >= delta.baseRevision else {
            throw ExchangeValidationError.invalidRevision
        }

        var createdIDs = Set<String>()
        for definition in delta.definitionsCreated {
            guard createdIDs.insert(definition.id).inserted else {
                throw ExchangeValidationError.duplicateDefinitionID(definition.id)
            }
            guard definition.projectID == delta.projectID else {
                throw ExchangeValidationError.projectMismatch("created definition \(definition.id)")
            }
            try validateSchemaVersion(definition.schemaVersion)
            try DomainValidator.validate(definition: definition, projectID: delta.projectID)
            try validateFuzzyTerms(definition.fuzzyTerms, owner: definition.id)
            try validateReferences(definition.references, owner: definition.id)
            try validateHistory(definition.implementationHistory, owner: definition.id)
            try validateSnapshots(definition.snapshots)
            try validateRelations(definition.relations, projectID: delta.projectID)
        }
        for evolution in delta.definitionsEvolved {
            guard IdentifierValidator.isValid(evolution.definitionID, prefix: "def_") else {
                throw ExchangeValidationError.invalidDefinitionID(evolution.definitionID)
            }
            try validateEvolution(evolution)
        }
        for change in delta.fuzzyTermsAdded {
            guard IdentifierValidator.isValid(change.definitionID, prefix: "def_") else {
                throw ExchangeValidationError.invalidDefinitionID(change.definitionID)
            }
            try validateFuzzyTerms([change.term], owner: change.definitionID)
        }
        try validateRelations(delta.relationsChanged, projectID: delta.projectID)
        let removedRelations = delta.relationsRemoved
        try validateRelations(removedRelations, projectID: delta.projectID)
        let removedRelationIDs = removedRelations.map(\.id)
        guard Set(removedRelationIDs).count == removedRelationIDs.count,
              removedRelationIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ExchangeValidationError.invalidEntity("removed relation IDs")
        }
        for change in delta.referencesChanged {
            guard IdentifierValidator.isValid(change.definitionID, prefix: "def_") else {
                throw ExchangeValidationError.invalidDefinitionID(change.definitionID)
            }
            try validateReferences([change.reference], owner: change.definitionID)
        }
        for change in delta.snapshotsChanged {
            guard IdentifierValidator.isValid(change.definitionID, prefix: "def_") else {
                throw ExchangeValidationError.invalidDefinitionID(change.definitionID)
            }
            try validateSnapshots([change.snapshot])
        }
        for proposal in delta.proposals where proposal.projectID != delta.projectID {
            throw ExchangeValidationError.projectMismatch("proposal \(proposal.id)")
        }
        for proposal in delta.proposals {
            try validateProposal(proposal, projectID: delta.projectID)
        }
        for request in delta.changeRequests where request.projectID != delta.projectID {
            throw ExchangeValidationError.projectMismatch("change request \(request.id)")
        }
        for request in delta.changeRequests {
            try validateChangeRequest(request, projectID: delta.projectID)
        }
        for conflict in delta.conflictRecords where conflict.projectID != delta.projectID {
            throw ExchangeValidationError.projectMismatch("conflict \(conflict.id)")
        }
        for conflict in delta.conflictRecords {
            try validateConflict(conflict, projectID: delta.projectID)
        }

        try rejectEmbeddedBinaryPayload(try JSONCodec.encode(delta))
    }

    public static func validateJSONData(_ data: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: data), object is [String: Any] else {
            throw ExchangeValidationError.invalidJSON
        }
        try rejectEmbeddedBinaryPayload(data)
        do {
            if let object = object as? [String: Any], object["delta_id"] != nil {
                try validate(delta: JSONCodec.decode(DictionaryDelta.self, from: data))
            } else {
                try validate(snapshot: JSONCodec.decode(ProjectSnapshot.self, from: data))
            }
        } catch let error as ExchangeValidationError {
            throw error
        } catch {
            throw ExchangeValidationError.invalidJSON
        }
    }

    public static func isSafeSnapshotPath(_ path: String) -> Bool {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard normalized == path,
              components.count == 2,
              components[0] == "snapshots",
              !components[1].isEmpty else { return false }
        return normalized.lowercased().hasSuffix(".jpg")
    }

    private static func validateSchemaVersion(_ version: String) throws {
        guard version == SchemaVersion.current else {
            throw ExchangeValidationError.unsupportedSchemaVersion(version)
        }
    }

    private static func validateSnapshots(_ snapshots: [SnapshotMetadata]) throws {
        for snapshot in snapshots {
            guard isSafeSnapshotPath(snapshot.file) else {
                throw ExchangeValidationError.invalidSnapshotPath(snapshot.file)
            }
            guard snapshot.width > 0,
                  snapshot.height > 0,
                  snapshot.sizeBytes > 0,
                  snapshot.revision >= 0,
                  !snapshot.perceptualHash.isEmpty else {
                throw ExchangeValidationError.invalidSnapshotMetadata(snapshot.id)
            }
        }
    }

    private static func validateFuzzyTerms(_ terms: [FuzzyTerm], owner: String) throws {
        for term in terms {
            guard !term.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !term.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  term.weight.isFinite,
                  (0...1).contains(term.weight),
                  term.usageCount >= 1 else {
                throw ExchangeValidationError.invalidEntity("fuzzy term for \(owner)")
            }
        }
    }

    private static func validateReferences(_ references: [Reference], owner: String) throws {
        for reference in references {
            guard !reference.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !reference.kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !reference.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ExchangeValidationError.invalidEntity("reference for \(owner)")
            }
        }
    }

    private static func validateHistory(_ history: [ImplementationEvent], owner: String) throws {
        for event in history {
            guard event.revision >= 0,
                  !event.changeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  event.codeImpact.isFinite,
                  event.semanticImpact.isFinite,
                  (0...1).contains(event.codeImpact),
                  (0...1).contains(event.semanticImpact) else {
                throw ExchangeValidationError.invalidEntity("implementation history for \(owner)")
            }
        }
    }

    private static func validateEvolution(_ evolution: DefinitionEvolution) throws {
        guard !evolution.changeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              evolution.codeImpact.isFinite,
              evolution.semanticImpact.isFinite,
              (0...1).contains(evolution.codeImpact),
              (0...1).contains(evolution.semanticImpact),
              evolution.changes.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ExchangeValidationError.invalidEntity("definition evolution for \(evolution.definitionID)")
        }
    }

    private static func validateCluster(
        _ cluster: Cluster,
        projectID: String,
        knownDefinitionIDs: Set<String>
    ) throws {
        guard !cluster.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              cluster.projectID == projectID,
              cluster.definitionIDs.count >= 2,
              Set(cluster.definitionIDs).count == cluster.definitionIDs.count,
              cluster.definitionIDs.allSatisfy({ knownDefinitionIDs.contains($0) }),
              cluster.definitionIDs.contains(cluster.primaryDefinitionID) else {
            throw ExchangeValidationError.invalidCluster(cluster.id)
        }
    }

    private static func validateProposal(_ proposal: Proposal, projectID: String) throws {
        guard !proposal.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              proposal.projectID == projectID,
              !proposal.definitionIDs.isEmpty,
              Set(proposal.definitionIDs).count == proposal.definitionIDs.count,
              proposal.definitionIDs.allSatisfy({ IdentifierValidator.isValid($0, prefix: "def_") }),
              !proposal.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExchangeValidationError.invalidEntity("proposal \(proposal.id)")
        }
        if proposal.action == .cluster {
            guard proposal.definitionIDs.count >= 2 else {
                throw ExchangeValidationError.invalidEntity("cluster proposal \(proposal.id)")
            }
        }
    }

    private static func validateChangeRequest(_ request: ChangeRequest, projectID: String) throws {
        guard !request.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.projectID == projectID,
              IdentifierValidator.isValid(request.definitionID, prefix: "def_"),
              !request.requestedChange.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.requestedChange.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !request.risk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              request.affectedDefinitionIDs.allSatisfy({ IdentifierValidator.isValid($0, prefix: "def_") }),
              request.proposedValues.keys.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ExchangeValidationError.invalidEntity("change request \(request.id)")
        }
    }

    private static func validateConflict(_ conflict: ConflictRecord, projectID: String) throws {
        guard !conflict.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              conflict.projectID == projectID,
              IdentifierValidator.isValid(conflict.definitionID, prefix: "def_"),
              !conflict.field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              conflict.baseRevision >= 0,
              conflict.localRevision >= 0,
              conflict.remoteRevision >= 0 else {
            throw ExchangeValidationError.invalidEntity("conflict \(conflict.id)")
        }
    }

    private static func validateAgentContext(
        _ context: AgentContext,
        projectID: String,
        knownDefinitionIDs: Set<String>
    ) throws {
        guard context.definitionID.isEmpty || (
            IdentifierValidator.isValid(context.definitionID, prefix: "def_")
                && knownDefinitionIDs.contains(context.definitionID)
        ) else {
            throw ExchangeValidationError.invalidAgentContext
        }
        try validateRelations(context.relevantRelations, projectID: projectID, knownDefinitionIDs: knownDefinitionIDs)
    }

    private static func validateRelations(
        _ relations: [Relation],
        projectID: String,
        knownDefinitionIDs: Set<String>? = nil
    ) throws {
        guard !projectID.isEmpty else { throw ExchangeValidationError.invalidProjectID(projectID) }
        for relation in relations {
            guard !relation.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  IdentifierValidator.isValid(relation.sourceDefinitionID, prefix: "def_"),
                  IdentifierValidator.isValid(relation.targetDefinitionID, prefix: "def_") else {
                throw ExchangeValidationError.projectMismatch("relation \(relation.id)")
            }
            if relation.type == .calls {
                let file = relation.metadata["file"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let line = relation.metadata["line"].flatMap(Int.init) ?? 0
                let evidence = relation.metadata["evidence"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let pathComponents = file.split(separator: "/")
                guard !file.isEmpty, !file.hasPrefix("/"), !pathComponents.contains(".."), line > 0, !evidence.isEmpty else {
                    throw ExchangeValidationError.invalidRelation(relation.id)
                }
            }
            if let knownDefinitionIDs,
               !knownDefinitionIDs.contains(relation.sourceDefinitionID)
                    || !knownDefinitionIDs.contains(relation.targetDefinitionID) {
                throw ExchangeValidationError.invalidRelation(relation.id)
            }
        }
    }

    private static func rejectEmbeddedBinaryPayload(_ data: Data) throws {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ExchangeValidationError.invalidJSON
        }
        let lowercased = text.lowercased()
        if lowercased.contains("data:image/") || lowercased.contains("base64,") {
            throw ExchangeValidationError.embeddedBinaryPayload
        }
    }
}
