import CoreData
import Foundation

public enum PersistenceMode: Sendable {
    case inMemory
    case local(directory: URL)
    case cloudCapable(directory: URL, containerIdentifier: String)
}

public enum PersistenceError: Error, LocalizedError, Sendable {
    case modelNotFound
    case storeLoadFailed(String)
    case contextSaveFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound: "The Core Data model could not be found in the application bundle."
        case .storeLoadFailed(let message): "The persistent store could not load: \(message)"
        case .contextSaveFailed(let message): "The Core Data context could not save: \(message)"
        }
    }
}

private final class PersistentStoreLoadState: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingStoreCount: Int
    private var firstErrorMessage: String?
    private var didFinish = false

    init(storeCount: Int) {
        remainingStoreCount = max(1, storeCount)
    }

    func record(error: Error?) -> (finished: Bool, errorMessage: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard !didFinish else { return (false, nil) }
        if firstErrorMessage == nil, let error {
            firstErrorMessage = error.localizedDescription
        }
        remainingStoreCount -= 1
        guard remainingStoreCount == 0 else { return (false, nil) }
        didFinish = true
        return (true, firstErrorMessage)
    }

    func failureMessage() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return firstErrorMessage
    }
}

@MainActor
public final class PersistenceController {
    public let container: NSPersistentContainer
    public let viewContext: NSManagedObjectContext
    public private(set) var isLoaded = false

    public init(mode: PersistenceMode) throws {
        let model = try NSManagedObjectModel.funcDictionaryModel()

        let builtContainer: NSPersistentContainer
        switch mode {
        case .cloudCapable(_, let containerIdentifier):
            builtContainer = NSPersistentCloudKitContainer(name: "funcDictionary", managedObjectModel: model)
            self.container = builtContainer
            self.viewContext = builtContainer.viewContext
            configure(container: builtContainer, mode: mode, containerIdentifier: containerIdentifier)
        case .inMemory, .local:
            builtContainer = NSPersistentContainer(name: "funcDictionary", managedObjectModel: model)
            self.container = builtContainer
            self.viewContext = builtContainer.viewContext
            configure(container: builtContainer, mode: mode, containerIdentifier: nil)
        }

        viewContext.name = "viewContext"
        viewContext.automaticallyMergesChangesFromParent = true
        viewContext.mergePolicy = NSMergePolicy.mergeByPropertyObjectTrump
        viewContext.undoManager = nil

#if os(macOS)
        // Native macOS startup loads stores through the async API below.  A
        // semaphore here would block the main actor while SQLite/CloudKit
        // performs I/O and can make the first window appear hung.
#else
        let semaphore = DispatchSemaphore(value: 0)
        let loadState = PersistentStoreLoadState(storeCount: container.persistentStoreDescriptions.count)
        container.loadPersistentStores { _, error in
            if loadState.record(error: error).finished {
                semaphore.signal()
            }
        }
        semaphore.wait()
        if let message = loadState.failureMessage() {
            throw PersistenceError.storeLoadFailed(message)
        }
        isLoaded = true
#endif
    }

#if os(macOS)
    /// Loads every configured persistent store without blocking the main
    /// actor. The completion handler is called once per store, so the
    /// accumulator waits for all stores before resuming.
    public func loadPersistentStores() async throws {
        guard !isLoaded else { return }
        let loadState = PersistentStoreLoadState(storeCount: container.persistentStoreDescriptions.count)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            container.loadPersistentStores { [weak self] _, error in
                let outcome = loadState.record(error: error)
                guard outcome.finished else { return }
                Task { @MainActor [weak self] in
                    if let message = outcome.errorMessage {
                        continuation.resume(throwing: PersistenceError.storeLoadFailed(message))
                    } else {
                        self?.isLoaded = true
                        continuation.resume()
                    }
                }
            }
        }
    }
#endif

    public func saveIfNeeded() throws {
        guard viewContext.hasChanges else { return }
        do {
            try viewContext.save()
        } catch {
            throw PersistenceError.contextSaveFailed(error.localizedDescription)
        }
    }

    private func configure(
        container: NSPersistentContainer,
        mode: PersistenceMode,
        containerIdentifier: String?
    ) {
        let cloudDescription = NSPersistentStoreDescription()
        cloudDescription.configuration = "CloudStore"
        cloudDescription.shouldMigrateStoreAutomatically = true
        cloudDescription.shouldInferMappingModelAutomatically = true

        let localDescription = NSPersistentStoreDescription()
        localDescription.configuration = "LocalStore"
        localDescription.shouldMigrateStoreAutomatically = true
        localDescription.shouldInferMappingModelAutomatically = true

        switch mode {
        case .inMemory:
            // Core Data rejects two stores that advertise the same URL even
            // when both stores are in-memory. Keep the configurations
            // isolated with distinct synthetic URLs.
            let namespace = UUID().uuidString.lowercased()
            cloudDescription.url = URL(fileURLWithPath: "/funcDictionary-in-memory-\(namespace)-cloud")
            localDescription.url = URL(fileURLWithPath: "/funcDictionary-in-memory-\(namespace)-local")
            cloudDescription.type = NSInMemoryStoreType
            localDescription.type = NSInMemoryStoreType
        case .local(let directory):
            cloudDescription.url = directory.appendingPathComponent("CloudStore.sqlite")
            localDescription.url = directory.appendingPathComponent("LocalStore.sqlite")
        case .cloudCapable(let directory, _):
            cloudDescription.url = directory.appendingPathComponent("CloudStore.sqlite")
            localDescription.url = directory.appendingPathComponent("LocalStore.sqlite")
            if let containerIdentifier,
               let cloudContainer = container as? NSPersistentCloudKitContainer {
                let options = NSPersistentCloudKitContainerOptions(containerIdentifier: containerIdentifier)
                cloudDescription.cloudKitContainerOptions = options
                cloudContainer.viewContext.transactionAuthor = "funcDictionary"
                cloudDescription.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
                cloudDescription.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
            }
        }

        container.persistentStoreDescriptions = [cloudDescription, localDescription]
    }
}
