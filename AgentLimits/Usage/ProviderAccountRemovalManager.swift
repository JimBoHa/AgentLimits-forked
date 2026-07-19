import Foundation
import WebKit

@MainActor
protocol IdentifiedWebsiteDataStoreRemoving {
    func containsDataStore(for identifier: UUID) async -> Bool
    func removeDataStore(for identifier: UUID) async throws
}

@MainActor
struct DefaultIdentifiedWebsiteDataStoreRemover:
    IdentifiedWebsiteDataStoreRemoving {
    func containsDataStore(for identifier: UUID) async -> Bool {
        await WKWebsiteDataStore.allDataStoreIdentifiers.contains(identifier)
    }

    func removeDataStore(for identifier: UUID) async throws {
        try await WKWebsiteDataStore.remove(forIdentifier: identifier)
    }
}

@MainActor
protocol ProviderAccountLocalDataRemoving {
    func removeLocalData(for account: ProviderAccount) throws
}

struct DefaultProviderAccountLocalDataRemover:
    ProviderAccountLocalDataRemoving {
    private let visibilityStore: any SnapshotVisibilityControlling
    private let makeUsageSnapshotStore: (UUID) -> UsageSnapshotStore

    init(
        visibilityStore: any SnapshotVisibilityControlling =
            SnapshotVisibilityStore.shared,
        makeUsageSnapshotStore: @escaping (UUID) -> UsageSnapshotStore = {
            UsageSnapshotStore(accountID: $0)
        }
    ) {
        self.visibilityStore = visibilityStore
        self.makeUsageSnapshotStore = makeUsageSnapshotStore
    }

    func removeLocalData(for account: ProviderAccount) throws {
        try makeUsageSnapshotStore(account.id).deleteAccountNamespace()

        let prefix = "accounts/\(account.snapshotNamespace)/"
        let fileNames = UsageProvider.allCases.map(\.snapshotFileName)
            + TokenUsageProvider.allCases.map(\.snapshotFileName)
        for fileName in fileNames {
            visibilityStore.setSnapshotSuppressed(
                false,
                fileName: prefix + fileName
            )
        }
    }
}

enum ProviderAccountRemovalOutcome: Equatable {
    case removed
    /// Registry removal succeeded. Durable cleanup will retry next launch.
    case removedWithPendingCleanup
}

enum ProviderAccountRemovalManagerError: LocalizedError, Equatable {
    case operationAlreadyInProgress

    var errorDescription: String? {
        switch self {
        case .operationAlreadyInProgress:
            return "Another provider-account cleanup is already running."
        }
    }
}

/// Owns the crash-safe boundary between the account registry, local snapshots,
/// live WKWebViews, and identified WKWebsiteDataStore deletion.
@MainActor
final class ProviderAccountRemovalManager {
    private let accountStore: ProviderAccountStore
    private let webViewPool: UsageWebViewPool
    private let localDataRemover: any ProviderAccountLocalDataRemoving
    private let websiteDataStoreRemover: any IdentifiedWebsiteDataStoreRemoving
    private let cleanupAttempts: Int
    private let cleanupRetryDelay: Duration
    private var isOperationInProgress = false

    init(
        accountStore: ProviderAccountStore,
        webViewPool: UsageWebViewPool,
        localDataRemover: (any ProviderAccountLocalDataRemoving)? = nil,
        websiteDataStoreRemover:
            (any IdentifiedWebsiteDataStoreRemoving)? = nil,
        cleanupAttempts: Int = 4,
        cleanupRetryDelay: Duration = .milliseconds(50)
    ) {
        self.accountStore = accountStore
        self.webViewPool = webViewPool
        self.localDataRemover = localDataRemover
            ?? DefaultProviderAccountLocalDataRemover()
        self.websiteDataStoreRemover = websiteDataStoreRemover
            ?? DefaultIdentifiedWebsiteDataStoreRemover()
        self.cleanupAttempts = max(1, cleanupAttempts)
        self.cleanupRetryDelay = cleanupRetryDelay
    }

    func removeAccount(id: UUID) async throws -> ProviderAccountRemovalOutcome {
        guard !isOperationInProgress else {
            throw ProviderAccountRemovalManagerError.operationAlreadyInProgress
        }
        isOperationInProgress = true
        defer { isOperationInProgress = false }

        let plan = try accountStore.prepareRemoval(id: id)
        let token = try webViewPool.beginAccountRetirement(plan)
        var registryCommitted = false

        do {
            try await webViewPool.quiesceAccountForRetirement(token)
            try localDataRemover.removeLocalData(for: plan.target)
            let commit = try accountStore.commitRemoval(plan)
            registryCommitted = true

            do {
                try webViewPool.finalizeAccountRetirement(token, commit: commit)
            } catch {
                // Account and durable tombstone are already committed. A later
                // process can finish cleanup after all current references die.
                return .removedWithPendingCleanup
            }

            guard let identifier = commit.queuedWebKitDataStoreIdentifier else {
                return .removed
            }
            guard await removeIdentifiedDataStore(identifier) else {
                return .removedWithPendingCleanup
            }
            do {
                try accountStore.markWebKitDataStoreDeletionComplete(id: identifier)
                return .removed
            } catch {
                // Store is gone; leaving the id queued is safe and self-heals.
                return .removedWithPendingCleanup
            }
        } catch {
            if !registryCommitted {
                _ = webViewPool.cancelAccountRetirement(token)
            }
            throw error
        }
    }

    /// Retries cleanup tombstones from prior crashes or temporary WebKit
    /// retention. Failed identifiers remain durable for the next launch.
    @discardableResult
    func drainPendingWebKitDataStoreDeletions() async -> Set<UUID> {
        guard !isOperationInProgress else {
            return accountStore.pendingWebKitDataStoreDeletionIDs
        }
        isOperationInProgress = true
        defer { isOperationInProgress = false }

        let identifiers = accountStore.pendingWebKitDataStoreDeletionIDs.sorted {
            $0.uuidString < $1.uuidString
        }
        for identifier in identifiers {
            guard await removeIdentifiedDataStore(identifier) else { continue }
            try? accountStore.markWebKitDataStoreDeletionComplete(id: identifier)
        }
        return accountStore.pendingWebKitDataStoreDeletionIDs
    }

    private func removeIdentifiedDataStore(_ identifier: UUID) async -> Bool {
        for attempt in 0..<cleanupAttempts {
            guard await websiteDataStoreRemover.containsDataStore(
                for: identifier
            ) else {
                return true
            }
            try? await websiteDataStoreRemover.removeDataStore(for: identifier)
            await Task.yield()
            if attempt + 1 < cleanupAttempts {
                try? await Task.sleep(for: cleanupRetryDelay)
            }
        }
        return !(await websiteDataStoreRemover.containsDataStore(for: identifier))
    }
}
