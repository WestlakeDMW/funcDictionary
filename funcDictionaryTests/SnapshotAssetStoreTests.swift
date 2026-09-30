import XCTest
@testable import funcDictionary

@MainActor
final class SnapshotAssetStoreTests: XCTestCase {
    func testSnapshotBinaryIsStoredSeparatelyFromPortableMetadata() throws {
        let persistence = try PersistenceController(mode: .inMemory)
        let projectID = "project_snapshot"
        try CoreDataProjectRepository(persistence: persistence)
            .save(project: Project(id: projectID, name: "Snapshot Assets"))
        let metadata = SnapshotMetadata(
            id: "snapshot_one",
            file: "snapshots/snapshot_one.jpg",
            width: 720,
            height: 480,
            sizeBytes: 6,
            perceptualHash: "0123456789abcdef",
            revision: 2,
            milestone: true
        )
        let jpegData = Data([0xff, 0xd8, 0xff, 0xe0, 0xff, 0xd9])
        let store = SnapshotAssetStore(persistence: persistence)

        try store.save(metadata: metadata, jpegData: jpegData, projectID: projectID)
        let asset = try store.read(snapshotID: metadata.id, projectID: projectID)

        XCTAssertEqual(asset.metadata, metadata)
        XCTAssertEqual(asset.jpegData, jpegData)
        let portableJSON = try JSONCodec.encode(metadata)
        XCTAssertFalse(String(decoding: portableJSON, as: UTF8.self).contains("base64"))
    }

    func testSnapshotBinaryRequiresExactMetadataByteCount() throws {
        let persistence = try PersistenceController(mode: .inMemory)
        try CoreDataProjectRepository(persistence: persistence)
            .save(project: Project(id: "project_snapshot", name: "Snapshot Assets"))
        let store = SnapshotAssetStore(persistence: persistence)
        let metadata = SnapshotMetadata(
            id: "snapshot_mismatch",
            file: "snapshots/snapshot_mismatch.jpg",
            width: 720,
            height: 480,
            sizeBytes: 10,
            perceptualHash: "0123456789abcdef",
            revision: 0
        )

        XCTAssertThrowsError(try store.save(metadata: metadata, jpegData: Data([1, 2]), projectID: "project_snapshot")) { error in
            XCTAssertEqual(error as? SnapshotAssetStoreError, .sizeMismatch(expected: 10, actual: 2))
        }
    }
}
