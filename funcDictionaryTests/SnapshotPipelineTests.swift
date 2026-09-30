import XCTest
import UIKit
@testable import funcDictionary

@MainActor
final class SnapshotPipelineTests: XCTestCase {
    func testSnapshotIsScaledEncodedAndHasPerceptualHash() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 320, height: 200))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 320, height: 200))
            UIColor.white.setFill()
            context.fill(CGRect(x: 60, y: 40, width: 200, height: 120))
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("funcDictionary-snapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let pipeline = SnapshotPipeline(directory: ExchangeDirectory(rootURL: root))
        let metadata = try pipeline.write(
            image: image,
            snapshotID: "snapshot_pipeline_1",
            revision: 4,
            milestone: true
        )

        XCTAssertEqual(max(metadata.width, metadata.height), 720)
        XCTAssertGreaterThan(metadata.sizeBytes, 0)
        XCTAssertEqual(metadata.perceptualHash.count, 16)
        XCTAssertTrue(DictionarySchemaValidator.isSafeSnapshotPath(metadata.file))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(metadata.file).path))
    }

    func testSnapshotIDCannotEscapeExchangeDirectory() {
        let pipeline = SnapshotPipeline(directory: ExchangeDirectory(rootURL: FileManager.default.temporaryDirectory))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20))
        let image = renderer.image { _ in UIColor.black.setFill(); UIRectFill(CGRect(x: 0, y: 0, width: 20, height: 20)) }
        XCTAssertThrowsError(try pipeline.makeArtifact(image: image, snapshotID: "../outside", revision: 0))
    }
}

