import CoreData

@objc(CDRecord)
class CDRecord: NSManagedObject {
    @NSManaged var stableID: String?
    @NSManaged var projectID: String?
    @NSManaged var recordKind: String?
    @NSManaged var schemaVersion: String?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var softDeleted: Bool
    @NSManaged var payload: Data?
}

/// Snapshot keeps its image bytes in the Core Data Binary attribute while the
/// Definition payload keeps only portable metadata.  A separate subclass
/// prevents snapshot-only scalar fields from leaking into other Cloud Store
/// entities that share the generic record envelope.
@objc(CDSnapshotRecord)
final class CDSnapshotRecord: CDRecord {
    @NSManaged var file: String?
    @NSManaged var width: Int64
    @NSManaged var height: Int64
    @NSManaged var sizeBytes: Int64
    @NSManaged var perceptualHash: String?
    @NSManaged var revision: Int64
    @NSManaged var milestone: Bool
}

@objc(CDLocalRecord)
class CDLocalRecord: CDRecord {}

// Core Data requires every entity to resolve to a unique managed-object class.
// These records intentionally share the same scalar envelope through CDRecord,
// while keeping the entity/class mapping unambiguous for model validation and
// persistent-store loading.
@objc(CDProjectRecord)
final class CDProjectRecord: CDRecord {}

@objc(CDDefinitionRecord)
final class CDDefinitionRecord: CDRecord {}

@objc(CDCodeLocatorRecord)
final class CDCodeLocatorRecord: CDRecord {}

@objc(CDVisualLocatorRecord)
final class CDVisualLocatorRecord: CDRecord {}

@objc(CDFunctionalLocatorRecord)
final class CDFunctionalLocatorRecord: CDRecord {}

@objc(CDFuzzyTermRecord)
final class CDFuzzyTermRecord: CDRecord {}

@objc(CDRelationRecord)
final class CDRelationRecord: CDRecord {}

@objc(CDReferenceRecord)
final class CDReferenceRecord: CDRecord {}

@objc(CDImplementationEventRecord)
final class CDImplementationEventRecord: CDRecord {}

@objc(CDClusterRecord)
final class CDClusterRecord: CDRecord {}

@objc(CDClusterMembershipRecord)
final class CDClusterMembershipRecord: CDRecord {}

@objc(CDProposalRecord)
final class CDProposalRecord: CDRecord {}

@objc(CDChangeRequestRecord)
final class CDChangeRequestRecord: CDRecord {}

@objc(CDHumanPriorityRecord)
final class CDHumanPriorityRecord: CDRecord {}

@objc(CDActiveContextRecord)
final class CDActiveContextRecord: CDRecord {}

@objc(CDFieldRevisionRecord)
final class CDFieldRevisionRecord: CDRecord {}

@objc(CDConflictEntityRecord)
final class CDConflictEntityRecord: CDRecord {}

@objc(CDProjectAccessRecord)
final class CDProjectAccessRecord: CDRecord {}

@objc(CDExportStateRecord)
final class CDExportStateRecord: CDRecord {}

@objc(CDDeviceStateRecord)
final class CDDeviceStateRecord: CDRecord {}

private final class ModelBundleAnchor: NSObject {}

extension NSManagedObjectModel {
    static func funcDictionaryModel() throws -> NSManagedObjectModel {
        let bundle = Bundle(for: ModelBundleAnchor.self)
        guard let url = bundle.url(forResource: "funcDictionary", withExtension: "momd"),
              let model = NSManagedObjectModel(contentsOf: url) else {
            throw PersistenceError.modelNotFound
        }

        // The model is shared by the UIKit and native macOS targets.  The
        // source XML contains the original target module name, so resolving
        // it literally on macOS would create plain NSManagedObject values.
        // Bind every entity to the class compiled into the current bundle.
        let managedClasses: [String: NSManagedObject.Type] = [
            "Project": CDProjectRecord.self,
            "Definition": CDDefinitionRecord.self,
            "CodeLocator": CDCodeLocatorRecord.self,
            "VisualLocator": CDVisualLocatorRecord.self,
            "FunctionalLocator": CDFunctionalLocatorRecord.self,
            "FuzzyTerm": CDFuzzyTermRecord.self,
            "Relation": CDRelationRecord.self,
            "Reference": CDReferenceRecord.self,
            "ImplementationEvent": CDImplementationEventRecord.self,
            "Snapshot": CDSnapshotRecord.self,
            "Cluster": CDClusterRecord.self,
            "ClusterMembership": CDClusterMembershipRecord.self,
            "Proposal": CDProposalRecord.self,
            "ChangeRequest": CDChangeRequestRecord.self,
            "HumanPriority": CDHumanPriorityRecord.self,
            "ActiveContext": CDActiveContextRecord.self,
            "FieldRevision": CDFieldRevisionRecord.self,
            "ConflictRecord": CDConflictEntityRecord.self,
            "ProjectAccess": CDProjectAccessRecord.self,
            "ExportState": CDExportStateRecord.self,
            "DeviceState": CDDeviceStateRecord.self
        ]
        for entity in model.entities {
            guard let name = entity.name, let managedClass = managedClasses[name] else { continue }
            entity.managedObjectClassName = NSStringFromClass(managedClass)
        }
        return model
    }
}
