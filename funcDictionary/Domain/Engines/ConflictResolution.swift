import Foundation

public struct FieldMergeInput: Equatable, Sendable {
    public var definitionID: String
    public var projectID: String
    public var field: String
    public var baseRevision: Int
    public var localRevision: Int
    public var remoteRevision: Int
    public var baseValue: String
    public var localValue: String
    public var remoteValue: String

    public init(
        definitionID: String,
        projectID: String,
        field: String,
        baseRevision: Int,
        localRevision: Int,
        remoteRevision: Int,
        baseValue: String,
        localValue: String,
        remoteValue: String
    ) {
        self.definitionID = definitionID
        self.projectID = projectID
        self.field = field
        self.baseRevision = baseRevision
        self.localRevision = localRevision
        self.remoteRevision = remoteRevision
        self.baseValue = baseValue
        self.localValue = localValue
        self.remoteValue = remoteValue
    }
}

public struct FieldMergeResult: Equatable, Sendable {
    public var definitionID: String
    public var field: String
    public var mergedValue: String?
    public var conflict: ConflictRecord?

    public var isConflict: Bool { conflict != nil }

    public init(definitionID: String, field: String, mergedValue: String?, conflict: ConflictRecord?) {
        self.definitionID = definitionID
        self.field = field
        self.mergedValue = mergedValue
        self.conflict = conflict
    }
}

public struct FieldMergeBatchResult: Equatable, Sendable {
    public var automatic: [FieldMergeResult]
    public var conflicts: [ConflictRecord]

    public init(automatic: [FieldMergeResult], conflicts: [ConflictRecord]) {
        self.automatic = automatic
        self.conflicts = conflicts
    }
}

public enum FieldConflictResolver {
    public static func merge(_ input: FieldMergeInput) -> FieldMergeResult {
        if input.localValue == input.remoteValue {
            return FieldMergeResult(
                definitionID: input.definitionID,
                field: input.field,
                mergedValue: input.localValue,
                conflict: nil
            )
        }
        if input.localValue == input.baseValue {
            return FieldMergeResult(
                definitionID: input.definitionID,
                field: input.field,
                mergedValue: input.remoteValue,
                conflict: nil
            )
        }
        if input.remoteValue == input.baseValue {
            return FieldMergeResult(
                definitionID: input.definitionID,
                field: input.field,
                mergedValue: input.localValue,
                conflict: nil
            )
        }

        let conflict = ConflictRecord(
            id: "conflict_\(input.definitionID)_\(input.field.replacingOccurrences(of: ".", with: "_"))_\(input.localRevision)_\(input.remoteRevision)",
            projectID: input.projectID,
            definitionID: input.definitionID,
            field: input.field,
            baseRevision: input.baseRevision,
            localRevision: input.localRevision,
            remoteRevision: input.remoteRevision,
            localValue: input.localValue,
            remoteValue: input.remoteValue
        )
        return FieldMergeResult(
            definitionID: input.definitionID,
            field: input.field,
            mergedValue: nil,
            conflict: conflict
        )
    }

    public static func merge(_ inputs: [FieldMergeInput]) -> FieldMergeBatchResult {
        let results = inputs.map(merge)
        return FieldMergeBatchResult(
            automatic: results.filter { !$0.isConflict },
            conflicts: results.compactMap(\.conflict)
        )
    }
}

