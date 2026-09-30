import Foundation

/// Outcome of applying one Delta file discovered by the watcher.
enum DeltaSyncOutcome: Equatable, Sendable {
    case applied(revision: Int)
    case needsAttention(revision: Int, conflictCount: Int)
    case duplicate
}

/// Status surfaced in the project header for one watched Delta file.
enum DeltaSyncEventStatus: Equatable, Sendable {
    case applied(revision: Int)
    case needsAttention(revision: Int, conflictCount: Int)
    case duplicate
    case stale(expected: Int, actual: Int)
    case failed(message: String)
}

struct DeltaSyncEvent: Identifiable, Equatable {
    let id = UUID()
    let projectID: String
    let fileName: String
    let status: DeltaSyncEventStatus
    let date: Date

    init(projectID: String, fileName: String, status: DeltaSyncEventStatus) {
        self.projectID = projectID
        self.fileName = fileName
        self.status = status
        self.date = Date()
    }
}

/// Applies Delta JSON files found in a workspace exchange directory through
/// the same repository path as the manual import, so governance, schema
/// validation, revision checks, and idempotency behave identically.
@MainActor
struct DeltaSyncService {
    let repository: ProjectScopedRepository

    /// Applies one Delta file and, on success, archives it under
    /// `deltas/applied/`. A failed file stays where it is so a later edit
    /// (mtime change) can retry it.
    func applyDeltaFile(at url: URL, projectID: String) throws -> DeltaSyncOutcome {
        let data = try Data(contentsOf: url)
        try DictionarySchemaValidator.validateJSONData(data)
        let delta = try JSONCodec.decode(DictionaryDelta.self, from: data)
        guard delta.projectID == projectID else {
            throw ExchangeValidationError.projectMismatch(
                "Delta project (\(delta.projectID)) does not match (\(projectID))"
            )
        }
        let result = try repository.apply(delta: delta, in: projectID)
        let outcome: DeltaSyncOutcome
        if result.alreadyApplied {
            outcome = .duplicate
        } else if result.conflictCount > 0 {
            outcome = .needsAttention(revision: result.newRevision, conflictCount: result.conflictCount)
        } else {
            outcome = .applied(revision: result.newRevision)
        }
        archiveAppliedDelta(at: url)
        return outcome
    }

    /// Applied files move to `deltas/applied/` so the watched directory only
    /// ever holds pending deltas and the exchange dir doubles as an audit log.
    func archiveAppliedDelta(at url: URL) {
        let appliedDirectory = url.deletingLastPathComponent().appendingPathComponent("applied", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: appliedDirectory, withIntermediateDirectories: true)
            let destination = appliedDirectory.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withInternetDateTime])
                    .replacingOccurrences(of: ":", with: "-")
                let stamped = appliedDirectory.appendingPathComponent(
                    url.deletingPathExtension().lastPathComponent + "-\(stamp).json"
                )
                try FileManager.default.moveItem(at: url, to: stamped)
            } else {
                try FileManager.default.moveItem(at: url, to: destination)
            }
        } catch {
            // Archiving is an audit convenience; a failure must not undo the
            // applied Delta or crash the watcher loop.
        }
    }
}

/// Watches one directory (normally `.funcdictionary/deltas/`) and debounces
/// file-system events into a single callback. Until the watched directory
/// exists, callers can watch an ancestor so late directory creation is caught.
@MainActor
final class DeltaDirectoryWatcher {
    private(set) var watchedURL: URL?
    private var source: DispatchSourceFileSystemObject?
    private var scanTask: Task<Void, Never>?
    private var processedFiles: [String: Date] = [:]
    var onDirectoryChanged: (() -> Void)?

    func start(watching url: URL) {
        if watchedURL == url, source != nil { return }
        stop()
        processedFiles.removeAll()
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        watchedURL = url
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: .write,
            queue: DispatchQueue(label: "funcDictionary.deltaWatcher")
        )
        // Both handlers must be @Sendable: without it they inherit the
        // caller's MainActor isolation and dispatch_assert_queue traps the
        // process the moment libdispatch invokes them on its own queue.
        source.setEventHandler { @Sendable [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleScan()
            }
        }
        source.setCancelHandler { @Sendable in
            close(descriptor)
        }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
        source = nil
        watchedURL = nil
        scanTask?.cancel()
        scanTask = nil
    }

    /// A file is pending when it has never been seen or changed since the
    /// last processing attempt, so failed files retry only on real edits.
    func hasPendingFile(_ url: URL) -> Bool {
        guard let seen = processedFiles[url.standardizedFileURL.path] else { return true }
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let modified else { return true }
        return modified > seen
    }

    func markProcessed(_ url: URL) {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        processedFiles[url.standardizedFileURL.path] = modified ?? Date()
    }

    private func scheduleScan() {
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.onDirectoryChanged?()
        }
    }
}
