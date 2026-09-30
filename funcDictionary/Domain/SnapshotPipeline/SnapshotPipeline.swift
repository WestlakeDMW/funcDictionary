import CoreGraphics
import Foundation

#if canImport(UIKit)
import UIKit
public typealias SnapshotImage = UIImage
#elseif canImport(AppKit)
import AppKit
import ImageIO
import UniformTypeIdentifiers
public typealias SnapshotImage = NSImage
#endif

public enum SnapshotPipelineError: Error, Equatable, LocalizedError, Sendable {
    case invalidSnapshotID(String)
    case invalidRevision
    case imageCannotBeRasterized
    case jpegEncodingFailed
    case fileWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidSnapshotID(let id):
            return "Snapshot ID is invalid or unsafe: \(id)."
        case .invalidRevision:
            return "Snapshot revision must be zero or greater."
        case .imageCannotBeRasterized:
            return "The snapshot image could not be rasterized."
        case .jpegEncodingFailed:
            return "The snapshot image could not be encoded as JPEG."
        case .fileWriteFailed(let message):
            return "The snapshot JPEG could not be written: \(message)"
        }
    }
}

public struct SnapshotArtifact: Equatable, Sendable {
    public let metadata: SnapshotMetadata
    public let jpegData: Data

    public var meetsTargetByteRange: Bool {
        SnapshotPipeline.targetByteRange.contains(jpegData.count)
    }

    public init(metadata: SnapshotMetadata, jpegData: Data) {
        self.metadata = metadata
        self.jpegData = jpegData
    }
}

/// Converts a platform image into the portable JPEG representation used by
/// the exchange protocol.  UIKit and AppKit share the same domain API so the
/// Core Data/domain layer can be compiled into both the deferred iOS target
/// and the native macOS MVP target.
@MainActor
public final class SnapshotPipeline {
    /// The exchange contract treats this as a target rather than a reason to
    /// reject a tiny or exceptionally detailed source image. Encoding adapts
    /// quality toward the range and exposes the measured result for QA.
    public nonisolated static let targetByteRange = 30_000...120_000

    private let directory: ExchangeDirectory
    private let maxDimension: CGFloat
    private let compressionQuality: CGFloat

    public init(
        directory: ExchangeDirectory,
        maxDimension: CGFloat = 720,
        compressionQuality: CGFloat = 0.60
    ) {
        self.directory = directory
        self.maxDimension = max(1, maxDimension)
        self.compressionQuality = min(max(compressionQuality, 0), 1)
    }

    public func makeArtifact(
        image: SnapshotImage,
        snapshotID: String,
        revision: Int,
        milestone: Bool = false
    ) throws -> SnapshotArtifact {
        guard IdentifierValidator.isValid(snapshotID),
              DictionarySchemaValidator.isSafeSnapshotPath("snapshots/\(snapshotID).jpg") else {
            throw SnapshotPipelineError.invalidSnapshotID(snapshotID)
        }
        guard revision >= 0 else { throw SnapshotPipelineError.invalidRevision }

        let renderedImage = try resizedImage(image)
        let jpegData = try encodeTargetJPEG(renderedImage)
        let metadata = SnapshotMetadata(
            id: snapshotID,
            file: "snapshots/\(snapshotID).jpg",
            width: max(1, Int(renderedImageSize(renderedImage).width.rounded())),
            height: max(1, Int(renderedImageSize(renderedImage).height.rounded())),
            sizeBytes: jpegData.count,
            perceptualHash: try perceptualHash(for: renderedImage),
            revision: revision,
            milestone: milestone
        )
        return SnapshotArtifact(metadata: metadata, jpegData: jpegData)
    }

    @discardableResult
    public func write(
        image: SnapshotImage,
        snapshotID: String,
        revision: Int,
        milestone: Bool = false
    ) throws -> SnapshotMetadata {
        let artifact = try makeArtifact(
            image: image,
            snapshotID: snapshotID,
            revision: revision,
            milestone: milestone
        )
        let url = try directory.snapshotFileURL(relativePath: artifact.metadata.file)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try artifact.jpegData.write(to: url, options: .atomic)
        } catch {
            throw SnapshotPipelineError.fileWriteFailed(error.localizedDescription)
        }
        return artifact.metadata
    }

    public func perceptualHash(for image: SnapshotImage) throws -> String {
        guard let source = cgImage(for: image) else {
            throw SnapshotPipelineError.imageCannotBeRasterized
        }

        let width = 8
        let height = 8
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw SnapshotPipelineError.imageCannotBeRasterized
        }
        context.interpolationQuality = .low
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

        let average = pixels.reduce(0) { $0 + Int($1) } / pixels.count
        var hash = ""
        for byteOffset in stride(from: 0, to: pixels.count, by: 8) {
            var byte: UInt8 = 0
            for bit in 0..<8 where Int(pixels[byteOffset + bit]) >= average {
                byte |= UInt8(1 << (7 - bit))
            }
            hash += String(format: "%02x", byte)
        }
        return hash
    }

    private func resizedImage(_ image: SnapshotImage) throws -> SnapshotImage {
        let sourceSize = renderedImageSize(image)
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            throw SnapshotPipelineError.imageCannotBeRasterized
        }
        let scale = maxDimension / max(sourceSize.width, sourceSize.height)
        let targetSize = CGSize(
            width: max(1, (sourceSize.width * scale).rounded()),
            height: max(1, (sourceSize.height * scale).rounded())
        )

        #if canImport(UIKit)
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        #elseif canImport(AppKit)
        let rendered = NSImage(size: targetSize)
        rendered.lockFocus()
        image.draw(
            in: NSRect(origin: .zero, size: targetSize),
            from: NSRect(origin: .zero, size: sourceSize),
            operation: .copy,
            fraction: 1
        )
        rendered.unlockFocus()
        return rendered
        #else
        throw SnapshotPipelineError.imageCannotBeRasterized
        #endif
    }

    private func renderedImageSize(_ image: SnapshotImage) -> CGSize {
        #if canImport(UIKit)
        image.size
        #elseif canImport(AppKit)
        image.size
        #else
        .zero
        #endif
    }

    private func cgImage(for image: SnapshotImage) -> CGImage? {
        #if canImport(UIKit)
        image.cgImage
        #elseif canImport(AppKit)
        image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        #else
        nil
        #endif
    }

    private func encodeTargetJPEG(_ image: SnapshotImage) throws -> Data {
        let initial = try encodeJPEG(image, quality: compressionQuality)
        if SnapshotPipeline.targetByteRange.contains(initial.count) {
            return initial
        }

        let candidateQualities: [CGFloat]
        if initial.count > SnapshotPipeline.targetByteRange.upperBound {
            candidateQualities = [0.55, 0.50, 0.45, 0.40, 0.35, 0.30, 0.25, 0.20, 0.15, 0.10, 0.08, 0.06, 0.04, 0.02, 0.01]
        } else {
            candidateQualities = [0.70, 0.80, 0.90, 1.0]
        }

        var best = initial
        for quality in candidateQualities {
            let candidate = try encodeJPEG(image, quality: quality)
            if SnapshotPipeline.targetByteRange.contains(candidate.count) {
                return candidate
            }
            if initial.count > SnapshotPipeline.targetByteRange.upperBound {
                if candidate.count < best.count { best = candidate }
            } else if candidate.count > best.count {
                best = candidate
            }
        }
        return best
    }

    private func encodeJPEG(_ image: SnapshotImage, quality: CGFloat) throws -> Data {
        #if canImport(UIKit)
        guard let data = image.jpegData(compressionQuality: quality) else {
            throw SnapshotPipelineError.jpegEncodingFailed
        }
        return data
        #elseif canImport(AppKit)
        guard let source = cgImage(for: image),
              let data = NSMutableData(capacity: 0),
              let destination = CGImageDestinationCreateWithData(
                  data,
                  UTType.jpeg.identifier as CFString,
                  1,
                  nil
              ) else {
            throw SnapshotPipelineError.jpegEncodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, source, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotPipelineError.jpegEncodingFailed
        }
        return data as Data
        #else
        throw SnapshotPipelineError.jpegEncodingFailed
        #endif
    }
}
