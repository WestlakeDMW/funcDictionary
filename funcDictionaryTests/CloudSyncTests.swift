import XCTest
@testable import funcDictionary

@MainActor
final class CloudSyncTests: XCTestCase {
    func testUnavailableCloudKitNeverClaimsSynced() {
        let coordinator = CloudSyncCoordinator(
            persistence: nil,
            configuration: CloudKitConfiguration(containerIdentifier: nil)
        )

        XCTAssertEqual(coordinator.state, .offline)
        XCTAssertTrue(coordinator.statusSummary.contains("Not configured"))
        coordinator.start()
        coordinator.requestSync()
        XCTAssertEqual(coordinator.state, .offline)
    }

    func testFieldResolverAutoMergesDifferentSideAndFlagsSameField() {
        let remoteOnly = FieldMergeInput(
            definitionID: "def_conflict",
            projectID: "project_conflict",
            field: "visual_locator.region",
            baseRevision: 4,
            localRevision: 5,
            remoteRevision: 6,
            baseValue: "center",
            localValue: "center",
            remoteValue: "trailing"
        )
        let merged = FieldConflictResolver.merge(remoteOnly)
        XCTAssertEqual(merged.mergedValue, "trailing")
        XCTAssertNil(merged.conflict)

        let sameField = FieldMergeInput(
            definitionID: "def_conflict",
            projectID: "project_conflict",
            field: "identity.canonical_name",
            baseRevision: 4,
            localRevision: 5,
            remoteRevision: 5,
            baseValue: "SyncControl",
            localValue: "PrimarySyncControl",
            remoteValue: "ProjectSyncEntry"
        )
        let conflict = FieldConflictResolver.merge(sameField)
        XCTAssertNil(conflict.mergedValue)
        XCTAssertEqual(conflict.conflict?.status, .needsReview)
        XCTAssertEqual(conflict.conflict?.field, "identity.canonical_name")
    }

    func testCloudKitConfigurationRequiresRealContainerIdentifier() {
        XCTAssertFalse(CloudKitConfiguration(containerIdentifier: "container.invalid").isConfigured)
        XCTAssertTrue(CloudKitConfiguration(containerIdentifier: "iCloud.com.example.funcDictionary").isConfigured)
    }
}

