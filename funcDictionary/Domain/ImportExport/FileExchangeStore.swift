import Foundation

public struct ExchangeDirectory: Equatable, Sendable {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public init(projectRootURL: URL) {
        self.init(rootURL: projectRootURL.appendingPathComponent(".funcdictionary", isDirectory: true))
    }

    public var snapshotsURL: URL {
        rootURL.appendingPathComponent("snapshots", isDirectory: true)
    }

    public var deltasURL: URL {
        rootURL.appendingPathComponent("deltas", isDirectory: true)
    }

    public func snapshotFileURL(relativePath: String) throws -> URL {
        guard DictionarySchemaValidator.isSafeSnapshotPath(relativePath) else {
            throw ExchangeValidationError.invalidSnapshotPath(relativePath)
        }
        return rootURL.appendingPathComponent(relativePath, isDirectory: false)
    }
}

public struct FileExchangeStore {
    public let directory: ExchangeDirectory
    private let fileManager: FileManager

    public init(directory: ExchangeDirectory, fileManager: FileManager = .default) {
        self.directory = directory
        self.fileManager = fileManager
    }

    @discardableResult
    public func write(
        snapshot: ProjectSnapshot,
        jpegDataBySnapshotID: [String: Data] = [:],
        preserveLiveExchange: Bool = false
    ) throws -> [URL] {
        try DictionarySchemaValidator.validate(snapshot: snapshot)
        let stagingURL = directory.rootURL
            .deletingLastPathComponent()
            .appendingPathComponent(".\(directory.rootURL.lastPathComponent).staging-\(UUID().uuidString)", isDirectory: true)
        let stagingStore = FileExchangeStore(
            directory: ExchangeDirectory(rootURL: stagingURL),
            fileManager: fileManager
        )
        defer {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
        }
        try stagingStore.prepareDirectories()

        let definitionsFile = DefinitionsExchangeFile(
            schemaVersion: snapshot.schemaVersion,
            projectID: snapshot.project.id,
            revision: snapshot.revision,
            definitions: snapshot.definitions
        )
        let clustersFile = ClustersExchangeFile(
            schemaVersion: snapshot.schemaVersion,
            projectID: snapshot.project.id,
            revision: snapshot.revision,
            clusters: snapshot.clusters
        )
        let contextFile = AgentContextExchangeFile(
            schemaVersion: snapshot.schemaVersion,
            projectID: snapshot.project.id,
            revision: snapshot.revision,
            agentContext: snapshot.agentContext
        )

        let files: [(URL, Data)] = [
            (stagingURL.appendingPathComponent("project.json"), try JSONCodec.encode(snapshot.project)),
            (stagingURL.appendingPathComponent("definitions.json"), try JSONCodec.encode(definitionsFile)),
            (stagingURL.appendingPathComponent("clusters.json"), try JSONCodec.encode(clustersFile)),
            (stagingURL.appendingPathComponent("agent-context.json"), try JSONCodec.encode(contextFile)),
            (stagingURL.appendingPathComponent("snapshot.json"), try JSONCodec.encode(snapshot))
        ]
        for (url, data) in files {
            try stagingStore.atomicWrite(data, to: url)
        }
        var writtenURLs = files.map { directory.rootURL.appendingPathComponent($0.0.lastPathComponent) }
        for definition in snapshot.definitions {
            for metadata in definition.snapshots {
                guard let jpegData = jpegDataBySnapshotID[metadata.id] else {
                    throw ExchangeValidationError.invalidSnapshotMetadata(metadata.id)
                }
                guard jpegData.count == metadata.sizeBytes else {
                    throw ExchangeValidationError.invalidSnapshotMetadata(metadata.id)
                }
                let relativePath = metadata.file
                guard DictionarySchemaValidator.isSafeSnapshotPath(relativePath) else {
                    throw ExchangeValidationError.invalidSnapshotPath(relativePath)
                }
                let stagedURL = stagingURL.appendingPathComponent(relativePath, isDirectory: false)
                try stagingStore.atomicWrite(jpegData, to: stagedURL)
                writtenURLs.append(directory.rootURL.appendingPathComponent(relativePath, isDirectory: false))
            }
        }
        if preserveLiveExchange {
            // Publish validated files without replacing the live exchange directory:
            // it also owns an Agent inbox, receipts, and the running directory watch.
            // snapshot.json is the final commit marker for snapshot readers.
            for destination in writtenURLs.filter({ $0.lastPathComponent != "snapshot.json" }) + writtenURLs.filter({ $0.lastPathComponent == "snapshot.json" }) {
                let relative = String(destination.path.dropFirst(directory.rootURL.path.count + 1))
                try atomicWrite(Data(contentsOf: stagingURL.appendingPathComponent(relative)), to: destination)
            }
        } else if fileManager.fileExists(atPath: directory.rootURL.path) {
            _ = try fileManager.replaceItemAt(directory.rootURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: directory.rootURL)
        }
        return writtenURLs
    }

    public func writeAgentContext(
        _ context: AgentContext,
        projectID: String,
        revision: Int
    ) throws -> URL {
        guard IdentifierValidator.isValid(projectID, prefix: "project_"), revision >= 0 else {
            throw ExchangeValidationError.invalidRevision
        }
        try prepareDirectories()
        let file = AgentContextExchangeFile(
            schemaVersion: SchemaVersion.current,
            projectID: projectID,
            revision: revision,
            agentContext: context
        )
        let url = directory.rootURL.appendingPathComponent("agent-context.json")
        try atomicWrite(try JSONCodec.encode(file), to: url)
        return url
    }

    @discardableResult
    public func write(delta: DictionaryDelta) throws -> URL {
        try DictionarySchemaValidator.validate(delta: delta)
        try prepareDirectories()
        let url = directory.deltasURL.appendingPathComponent("\(delta.deltaID).json")
        try atomicWrite(try JSONCodec.encode(delta), to: url)
        return url
    }

    public func read(deltaID: String) throws -> DictionaryDelta {
        guard IdentifierValidator.isValid(deltaID, prefix: "delta_") else {
            throw ExchangeValidationError.invalidRevision
        }
        let url = directory.deltasURL.appendingPathComponent("\(deltaID).json")
        let data = try Data(contentsOf: url)
        try DictionarySchemaValidator.validateJSONData(data)
        let delta = try JSONCodec.decode(DictionaryDelta.self, from: data)
        try DictionarySchemaValidator.validate(delta: delta)
        return delta
    }

    public func readSnapshot() throws -> ProjectSnapshot {
        let url = directory.rootURL.appendingPathComponent("snapshot.json")
        let data = try Data(contentsOf: url)
        try DictionarySchemaValidator.validateJSONData(data)
        let snapshot = try JSONCodec.decode(ProjectSnapshot.self, from: data)
        try DictionarySchemaValidator.validate(snapshot: snapshot)
        try validateSnapshotAssets(in: snapshot)
        return snapshot
    }

    /// The write path refuses packages whose JPEG payloads are missing or
    /// do not match the declared byte count; reading an externally produced
    /// package enforces the same contract before callers trust the bundle.
    private func validateSnapshotAssets(in snapshot: ProjectSnapshot) throws {
        for definition in snapshot.definitions {
            for metadata in definition.snapshots {
                let assetURL = try directory.snapshotFileURL(relativePath: metadata.file)
                guard fileManager.fileExists(atPath: assetURL.path) else {
                    throw ExchangeValidationError.invalidSnapshotMetadata(metadata.id)
                }
                let attributes = try fileManager.attributesOfItem(atPath: assetURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      (attributes[.size] as? NSNumber)?.intValue == metadata.sizeBytes else {
                    throw ExchangeValidationError.invalidSnapshotMetadata(metadata.id)
                }
                guard try isJPEG(at: assetURL) else {
                    throw ExchangeValidationError.invalidSnapshotMetadata(metadata.id)
                }
            }
        }
    }

    private func isJPEG(at url: URL) throws -> Bool {
        let fileHandle = try FileHandle(forReadingFrom: url)
        defer { try? fileHandle.close() }
        guard let header = try fileHandle.read(upToCount: 2), header == Data([0xFF, 0xD8]) else {
            return false
        }
        return true
    }

    private func prepareDirectories() throws {
        try fileManager.createDirectory(at: directory.rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.snapshotsURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: directory.deltasURL, withIntermediateDirectories: true)
    }

    private func atomicWrite(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let temporaryURL = parent.appendingPathComponent(".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
        defer {
            if fileManager.fileExists(atPath: temporaryURL.path) {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: url.path) {
            _ = try fileManager.replaceItemAt(url, withItemAt: temporaryURL)
        } else {
            try fileManager.moveItem(at: temporaryURL, to: url)
        }
    }
}

private struct DefinitionsExchangeFile: Codable {
    let schemaVersion: String
    let projectID: String
    let revision: Int
    let definitions: [Definition]
}

private struct ClustersExchangeFile: Codable {
    let schemaVersion: String
    let projectID: String
    let revision: Int
    let clusters: [Cluster]
}

public struct AgentContextExchangeFile: Codable, Equatable, Sendable {
    public let schemaVersion: String
    public let projectID: String
    public let revision: Int
    public let agentContext: AgentContext

    public init(schemaVersion: String, projectID: String, revision: Int, agentContext: AgentContext) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.revision = revision
        self.agentContext = agentContext
    }
}

public enum AgentContextBuilder {
    public static func make(
        for definition: Definition,
        definitions: [Definition] = [],
        protection: [String: String]? = nil
    ) -> AgentContext {
        let relations = definitions
            .flatMap(\.relations)
            .filter { relation in
                relation.sourceDefinitionID == definition.id || relation.targetDefinitionID == definition.id
            }
        let resolvedProtection = protection ?? (definition.isProtected ? ["level": "critical"] : nil)
        return AgentContext(
            definitionID: definition.id,
            canonicalName: definition.identity.canonicalName,
            currentSymbol: definition.codeLocator.symbol,
            currentFunction: definition.codeLocator.function,
            codeLocator: definition.codeLocator,
            visualLocator: definition.visualLocator,
            functionalLocator: definition.functionalLocator,
            humanPriority: definition.humanPriority,
            protection: resolvedProtection,
            relevantRelations: relations
        )
    }
}
