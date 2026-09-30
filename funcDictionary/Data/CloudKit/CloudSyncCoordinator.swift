import CloudKit
import CoreData
import Foundation

public struct CloudKitConfiguration: Equatable, Sendable {
    public var containerIdentifier: String?
    public var environment: String

    public init(containerIdentifier: String? = nil, environment: String = "production") {
        self.containerIdentifier = containerIdentifier
        self.environment = environment
    }

    public var isConfigured: Bool {
        guard let containerIdentifier else { return false }
        return containerIdentifier.hasPrefix("iCloud.") && containerIdentifier.count > "iCloud.".count
    }

    public static func fromInfoDictionary(_ bundle: Bundle = .main) -> CloudKitConfiguration {
        let identifier = bundle.object(forInfoDictionaryKey: "CKContainerIdentifier") as? String
        let environment = bundle.object(forInfoDictionaryKey: "CKEnvironment") as? String ?? "production"
        return CloudKitConfiguration(containerIdentifier: identifier, environment: environment)
    }
}

public enum CloudSyncAvailability: Equatable, Sendable {
    case configured(containerIdentifier: String, environment: String)
    case notConfigured(String)

    public var summary: String {
        switch self {
        case .configured(let containerIdentifier, let environment):
            return "Configured, verification pending: \(containerIdentifier) (\(environment))"
        case .notConfigured(let reason):
            return "Not configured: \(reason)"
        }
    }
}

@MainActor
public final class CloudSyncCoordinator {
    public let availability: CloudSyncAvailability
    public private(set) var state: SyncState

    private let persistence: PersistenceController?
    private let configuration: CloudKitConfiguration
    private var remoteChangeObserver: NSObjectProtocol?

    public init(
        persistence: PersistenceController?,
        configuration: CloudKitConfiguration = .fromInfoDictionary()
    ) {
        self.persistence = persistence
        self.configuration = configuration
        if configuration.isConfigured,
           persistence?.container is NSPersistentCloudKitContainer,
           let identifier = configuration.containerIdentifier {
            availability = .configured(containerIdentifier: identifier, environment: configuration.environment)
            // A valid identifier and container type prove configuration only.
            // They do not prove account access, entitlement validity, or that
            // a remote change has actually been imported.
            state = .needsConfirmation
        } else {
            availability = .notConfigured(
                persistence == nil
                    ? "Persistent storage is unavailable"
                    : "Team, entitlement, or iCloud container is not configured"
            )
            state = .offline
        }
    }

    public func start() {
        stop()
        guard case .configured = availability else {
            state = .offline
            return
        }
        state = .needsConfirmation
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.state = .synced
            }
        }
    }

    public func stop() {
        if let remoteChangeObserver {
            NotificationCenter.default.removeObserver(remoteChangeObserver)
            self.remoteChangeObserver = nil
        }
    }

    public func requestSync() {
        guard case .configured = availability,
              persistence?.container is NSPersistentCloudKitContainer else {
            state = .offline
            return
        }
        state = .syncing
    }

    public func markNeedsConfirmation() {
        state = .needsConfirmation
    }

    public func markConflict() {
        state = .conflict
    }

    public var statusSummary: String {
        "\(availability.summary); state=\(state.rawValue)"
    }
}
