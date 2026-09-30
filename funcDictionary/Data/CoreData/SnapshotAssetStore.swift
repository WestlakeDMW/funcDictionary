import CoreData
import Foundation

public struct SnapshotAsset: Equatable, Sendable {
    public let metadata: SnapshotMetadata
    public let jpegData: Data

    public init(metadata: SnapshotMetadata, jpegData: Data) {
        self.metadata = metadata
        self.jpegData = jpegData
    }
}

public enum SnapshotAssetStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidProjectID
    case projectNotFound(String)
    case invalidSnapshotMetadata
    case sizeMismatch(expected: Int, actual: Int)
    case assetNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProjectID:
            "Snapshot assets must belong to a valid project."
        case .projectNotFound(let projectID):
            "Snapshot project not found: \(projectID)."
        case .invalidSnapshotMetadata:
            "Snapshot metadata is invalid or does not point to a safe JPEG path."
        case .sizeMismatch(let expected, let actual):
            "Snapshot byte count mismatch. Metadata says \(expected), received \(actual)."
        case .assetNotFound(let id):
            "Snapshot asset not found: \(id)."
        }
    }
}

/// Stores the binary JPEG in the Cloud Store's Snapshot entity. Portable JSON
/// continues to carry only SnapshotMetadata, so images never become Base64
/// fields in a delta or a .funcdictionary package.
@MainActor
public final class SnapshotAssetStore {
    private let persistence: PersistenceController

    public init(persistence: PersistenceController) {
        self.persistence = persistence
    }

    @discardableResult
    public func save(
        metadata: SnapshotMetadata,
        jpegData: Data,
        projectID: String
    ) throws -> SnapshotMetadata {
        guard IdentifierValidator.isValid(projectID, prefix: "project_") else {
            throw SnapshotAssetStoreError.invalidProjectID
        }
        guard try projectExists(projectID) else {
            throw SnapshotAssetStoreError.projectNotFound(projectID)
        }
        guard IdentifierValidator.isValid(metadata.id),
              DictionarySchemaValidator.isSafeSnapshotPath(metadata.file),
              metadata.width > 0,
              metadata.height > 0,
              metadata.revision >= 0,
              !metadata.perceptualHash.isEmpty,
              !jpegData.isEmpty else {
            throw SnapshotAssetStoreError.invalidSnapshotMetadata
        }
        guard metadata.sizeBytes == jpegData.count else {
            throw SnapshotAssetStoreError.sizeMismatch(
                expected: metadata.sizeBytes,
                actual: jpegData.count
            )
        }

        let request = NSFetchRequest<CDSnapshotRecord>(entityName: "Snapshot")
        request.fetchLimit = 1
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "stableID == %@", metadata.id),
            NSPredicate(format: "projectID == %@", projectID),
            NSPredicate(format: "recordKind == %@", "snapshot")
        ])
        let record: CDSnapshotRecord
        if let existing = try persistence.viewContext.fetch(request).first {
            record = existing
        } else {
            guard let inserted = NSEntityDescription.insertNewObject(
                forEntityName: "Snapshot",
                into: persistence.viewContext
            ) as? CDSnapshotRecord else {
                throw SnapshotAssetStoreError.invalidSnapshotMetadata
            }
            record = inserted
        }
        record.stableID = metadata.id
        record.projectID = projectID
        record.recordKind = "snapshot"
        record.schemaVersion = SchemaVersion.current
        record.createdAt = record.createdAt ?? Date()
        record.updatedAt = Date()
        record.softDeleted = false
        record.payload = jpegData
        record.file = metadata.file
        record.width = Int64(metadata.width)
        record.height = Int64(metadata.height)
        record.sizeBytes = Int64(metadata.sizeBytes)
        record.perceptualHash = metadata.perceptualHash
        record.revision = Int64(metadata.revision)
        record.milestone = metadata.milestone
        try persistence.saveIfNeeded()
        return metadata
    }

    private func projectExists(_ projectID: String) throws -> Bool {
        let request = NSFetchRequest<CDProjectRecord>(entityName: "Project")
        request.fetchLimit = 1
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "stableID == %@", projectID),
            NSPredicate(format: "projectID == %@", projectID),
            NSPredicate(format: "recordKind == %@", "project"),
            NSPredicate(format: "softDeleted == NO")
        ])
        return try !persistence.viewContext.fetch(request).isEmpty
    }

    public func read(snapshotID: String, projectID: String) throws -> SnapshotAsset {
        guard IdentifierValidator.isValid(projectID, prefix: "project_") else {
            throw SnapshotAssetStoreError.invalidProjectID
        }
        let request = NSFetchRequest<CDSnapshotRecord>(entityName: "Snapshot")
        request.fetchLimit = 1
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "stableID == %@", snapshotID),
            NSPredicate(format: "projectID == %@", projectID),
            NSPredicate(format: "recordKind == %@", "snapshot"),
            NSPredicate(format: "softDeleted == NO")
        ])
        guard let record = try persistence.viewContext.fetch(request).first,
              let jpegData = record.payload,
              let perceptualHash = record.perceptualHash else {
            throw SnapshotAssetStoreError.assetNotFound(snapshotID)
        }
        let metadata = SnapshotMetadata(
            id: snapshotID,
            file: record.file ?? ("snapshots/" + snapshotID + ".jpg"),
            width: Int(record.width),
            height: Int(record.height),
            sizeBytes: Int(record.sizeBytes),
            perceptualHash: perceptualHash,
            revision: Int(record.revision),
            milestone: record.milestone
        )
        guard metadata.sizeBytes == jpegData.count else {
            throw SnapshotAssetStoreError.sizeMismatch(
                expected: metadata.sizeBytes,
                actual: jpegData.count
            )
        }
        return SnapshotAsset(metadata: metadata, jpegData: jpegData)
    }

    public func delete(snapshotID: String, projectID: String) throws {
        guard IdentifierValidator.isValid(projectID, prefix: "project_") else {
            throw SnapshotAssetStoreError.invalidProjectID
        }
        let request = NSFetchRequest<CDSnapshotRecord>(entityName: "Snapshot")
        request.fetchLimit = 1
        request.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [
            NSPredicate(format: "stableID == %@", snapshotID),
            NSPredicate(format: "projectID == %@", projectID),
            NSPredicate(format: "recordKind == %@", "snapshot")
        ])
        guard let record = try persistence.viewContext.fetch(request).first else {
            throw SnapshotAssetStoreError.assetNotFound(snapshotID)
        }
        record.softDeleted = true
        record.updatedAt = Date()
        try persistence.saveIfNeeded()
    }
}
