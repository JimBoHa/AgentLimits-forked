import Foundation
import OSLog

enum AccountUsageSnapshotRepositoryError: Error, Equatable {
    case providerMismatch
}

/// Account identity is mandatory at the production persistence boundary.
/// Provider-only files remain only as a selected-account projection for the
/// existing widgets while their account-aware timeline migration is pending.
@MainActor
protocol AccountUsageSnapshotRepository {
    func loadSnapshot(for account: ProviderAccount) -> UsageSnapshot?
    func saveSnapshot(
        _ snapshot: UsageSnapshot,
        for account: ProviderAccount
    ) throws
    func deleteSnapshot(for account: ProviderAccount) throws
    func setSnapshotSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    )
    func publishSelectedSnapshot(
        _ snapshot: UsageSnapshot?,
        for account: ProviderAccount
    ) throws
}

@MainActor
final class DefaultAccountUsageSnapshotRepository:
    AccountUsageSnapshotRepository {
    private let visibilityStore: any SnapshotVisibilityControlling
    private let migrationDefaults: UserDefaults
    private let makeAccountStore: (ProviderAccount, Bool) -> UsageSnapshotStore
    private let projectionStore: UsageSnapshotStore

    init(
        visibilityStore: (any SnapshotVisibilityControlling)? = nil,
        migrationDefaults: UserDefaults = .standard,
        makeAccountStore:
            ((ProviderAccount, Bool) -> UsageSnapshotStore)? = nil,
        projectionStore: UsageSnapshotStore? = nil
    ) {
        let resolvedVisibilityStore = visibilityStore
            ?? SnapshotVisibilityStore.shared
        self.visibilityStore = resolvedVisibilityStore
        self.migrationDefaults = migrationDefaults
        self.makeAccountStore = makeAccountStore ?? {
            account, migratesLegacySnapshot in
            UsageSnapshotStore(
                visibilityStore: resolvedVisibilityStore,
                accountID: account.id,
                migratesLegacySnapshot: migratesLegacySnapshot
            )
        }
        self.projectionStore = projectionStore ?? .shared
    }

    func loadSnapshot(for account: ProviderAccount) -> UsageSnapshot? {
        let migrationKey = legacyMigrationKey(for: account)
        let shouldMigrate = account.webKitStorage == .legacyDefault
            && !migrationDefaults.bool(forKey: migrationKey)
        let store = makeAccountStore(account, shouldMigrate)
        let snapshot: UsageSnapshot?
        let migrationReachedDurableTerminalState: Bool
        do {
            snapshot = try store.tryLoadSnapshot(for: account.provider)
            migrationReachedDurableTerminalState = true
        } catch let error as UsageSnapshotStoreError {
            snapshot = nil
            switch error {
            case .decodeFailed:
                // Migration already wrote its namespace marker before decode.
                migrationReachedDurableTerminalState = true
            case .readFailed(let underlying):
                // A missing scoped file is a completed "nothing to migrate"
                // result. Other I/O failures must remain retryable.
                migrationReachedDurableTerminalState = Self.isMissingFile(
                    underlying
                )
            case .appGroupUnavailable:
                migrationReachedDurableTerminalState = false
            }
        } catch {
            snapshot = nil
            // Suppression deliberately presents as a missing file after its
            // account-scoped marker has been persisted.
            migrationReachedDurableTerminalState = Self.isMissingFile(error)
        }

        if shouldMigrate, migrationReachedDurableTerminalState {
            // This marker deliberately lives outside the account namespace.
            // A failed account-removal commit may delete that namespace; it
            // must never make a sibling projection eligible for re-import.
            migrationDefaults.set(true, forKey: migrationKey)
            if !migrationDefaults.synchronize() {
                Logger.usage.error(
                    "Could not durably finish legacy snapshot migration"
                )
            }
        }
        guard let snapshot else { return nil }
        guard snapshot.provider == account.provider else {
            // A corrupt or misplaced payload must never be displayed as this
            // account. Keep it suppressed for forensic/recovery purposes.
            visibilityStore.setSnapshotSuppressed(
                true,
                fileName: store.snapshotVisibilityKey(for: account.provider)
            )
            Logger.usage.error(
                "Rejected account snapshot with mismatched provider"
            )
            return nil
        }
        return snapshot
    }

    func saveSnapshot(
        _ snapshot: UsageSnapshot,
        for account: ProviderAccount
    ) throws {
        guard snapshot.provider == account.provider else {
            throw AccountUsageSnapshotRepositoryError.providerMismatch
        }
        try makeAccountStore(account, false).saveSnapshot(snapshot)
    }

    func deleteSnapshot(for account: ProviderAccount) throws {
        try makeAccountStore(account, false).deleteSnapshot(
            for: account.provider
        )
    }

    func setSnapshotSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) {
        let store = makeAccountStore(account, false)
        visibilityStore.setSnapshotSuppressed(
            isSuppressed,
            fileName: store.snapshotVisibilityKey(for: account.provider)
        )
    }

    func publishSelectedSnapshot(
        _ snapshot: UsageSnapshot?,
        for account: ProviderAccount
    ) throws {
        let projectionKey = account.provider.snapshotFileName
        // Hide the prior selected account before an overwrite/delete attempt.
        // A disk failure therefore shows no widget data, never a sibling's.
        visibilityStore.setSnapshotSuppressed(true, fileName: projectionKey)
        do {
            if let snapshot {
                guard snapshot.provider == account.provider else {
                    throw AccountUsageSnapshotRepositoryError.providerMismatch
                }
                try projectionStore.saveSnapshot(snapshot)
            } else {
                try projectionStore.deleteSnapshot(for: account.provider)
            }
            visibilityStore.setSnapshotSuppressed(false, fileName: projectionKey)
        } catch {
            throw error
        }
    }

    private func legacyMigrationKey(for account: ProviderAccount) -> String {
        "usage_snapshot_account_migration_v1."
            + account.provider.rawValue
            + "."
            + account.snapshotNamespace
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.fileReadNoSuchFile.rawValue
    }
}
