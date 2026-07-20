import Foundation
import OSLog

enum AccountUsageSnapshotRepositoryError: LocalizedError, Equatable {
    case providerMismatch
    case migrationRetirementFailed
    case indeterminateSnapshot(provider: UsageProvider, accountLabel: String)
    case legacyProjectionSourceIndeterminate(UsageProvider)

    var errorDescription: String? {
        switch self {
        case .providerMismatch:
            return "Usage snapshot provider does not match the account."
        case .migrationRetirementFailed:
            return "Could not durably retire legacy usage snapshot migration."
        case .indeterminateSnapshot(let provider, let accountLabel):
            return "Could not safely read \(accountLabel)'s \(provider.displayName) usage. Try again before changing accounts."
        case .legacyProjectionSourceIndeterminate(let provider):
            return "Could not safely replace the preserved \(provider.displayName) usage source. Try again."
        }
    }
}

/// Account identity is mandatory at the production persistence boundary.
/// Provider-only files remain only as a selected-account projection for the
/// existing widgets while their account-aware timeline migration is pending.
@MainActor
protocol AccountUsageSnapshotRepository {
    func loadSnapshot(for account: ProviderAccount) -> UsageSnapshot?
    func canSafelyPublishMissingSnapshot(
        for account: ProviderAccount
    ) -> Bool
    func canSafelyMutateSelectedProjection(
        for account: ProviderAccount
    ) -> Bool
    func saveSnapshot(
        _ snapshot: UsageSnapshot,
        for account: ProviderAccount
    ) throws
    func deleteSnapshot(for account: ProviderAccount) throws
    func setSnapshotSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) throws
    func setSelectedProjectionSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) throws
    func publishSelectedSnapshot(
        _ snapshot: UsageSnapshot?,
        for account: ProviderAccount
    ) throws
}

extension AccountUsageSnapshotRepository {
    func canSafelyPublishMissingSnapshot(
        for account: ProviderAccount
    ) -> Bool {
        true
    }

    func canSafelyMutateSelectedProjection(
        for account: ProviderAccount
    ) -> Bool {
        canSafelyPublishMissingSnapshot(for: account)
    }

    func setSelectedProjectionSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) throws {}
}

@MainActor
final class DefaultAccountUsageSnapshotRepository:
    AccountUsageSnapshotRepository {
    private struct SnapshotIdentity: Hashable {
        let accountID: UUID
        let provider: UsageProvider
    }

    private let visibilityStore: any SnapshotVisibilityControlling
    private let migrationDefaults: UserDefaults
    private let makeAccountStore: (ProviderAccount, Bool) -> UsageSnapshotStore
    private let projectionStore: UsageSnapshotStore
    private var indeterminateLoadIdentities: Set<SnapshotIdentity> = []
    private var indeterminateLegacySourceIdentities:
        Set<SnapshotIdentity> = []

    init(
        visibilityStore: (any SnapshotVisibilityControlling)? = nil,
        migrationDefaults: UserDefaults = AppDefaults.shared,
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
        let identity = SnapshotIdentity(
            accountID: account.id,
            provider: account.provider
        )
        indeterminateLoadIdentities.remove(identity)
        indeterminateLegacySourceIdentities.remove(identity)
        let migrationKey = legacyMigrationKey(for: account)
        let shouldMigrate = account.webKitStorage == .legacyDefault
            && !migrationDefaults.bool(forKey: migrationKey)
        let store = makeAccountStore(account, shouldMigrate)
        let snapshot: UsageSnapshot?
        let migrationReachedDurableTerminalState: Bool
        let loadWasIndeterminate: Bool
        do {
            snapshot = try store.tryLoadSnapshot(for: account.provider)
            migrationReachedDurableTerminalState = true
            loadWasIndeterminate = false
        } catch let error as UsageSnapshotStoreError {
            snapshot = nil
            switch error {
            case .decodeFailed:
                // Migration already wrote its namespace marker before decode.
                migrationReachedDurableTerminalState = true
                loadWasIndeterminate = false
            case .readFailed(let underlying):
                // A missing scoped file is a completed "nothing to migrate"
                // result. Other I/O failures must remain retryable.
                let isMissing = Self.isMissingFile(underlying)
                migrationReachedDurableTerminalState = isMissing
                loadWasIndeterminate = !isMissing
            case .appGroupUnavailable:
                migrationReachedDurableTerminalState = false
                loadWasIndeterminate = true
            }
        } catch {
            snapshot = nil
            // Suppression deliberately presents as a missing file after its
            // account-scoped marker has been persisted.
            let isMissing = Self.isMissingFile(error)
            migrationReachedDurableTerminalState = isMissing
            loadWasIndeterminate = !isMissing
        }

        if loadWasIndeterminate {
            indeterminateLoadIdentities.insert(identity)
            if shouldMigrate {
                indeterminateLegacySourceIdentities.insert(identity)
            }
        }

        if shouldMigrate, migrationReachedDurableTerminalState {
            // This marker deliberately lives outside the account namespace.
            // A failed account-removal commit may delete that namespace; it
            // must never make a sibling projection eligible for re-import.
            if !DurableDefaultsFlags.persistTrue(
                [migrationKey],
                in: migrationDefaults
            ) {
                indeterminateLoadIdentities.insert(identity)
                indeterminateLegacySourceIdentities.insert(identity)
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

    func canSafelyPublishMissingSnapshot(
        for account: ProviderAccount
    ) -> Bool {
        !indeterminateLoadIdentities.contains(
            SnapshotIdentity(
                accountID: account.id,
                provider: account.provider
            )
        )
    }

    func canSafelyMutateSelectedProjection(
        for account: ProviderAccount
    ) -> Bool {
        canSafelyPublishMissingSnapshot(for: account)
            && !hasIndeterminateLegacySource(for: account.provider)
    }

    func saveSnapshot(
        _ snapshot: UsageSnapshot,
        for account: ProviderAccount
    ) throws {
        guard snapshot.provider == account.provider else {
            throw AccountUsageSnapshotRepositoryError.providerMismatch
        }
        try makeAccountStore(account, false).saveSnapshot(snapshot)
        indeterminateLoadIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: account.provider
            )
        )
        indeterminateLegacySourceIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: account.provider
            )
        )
    }

    func deleteSnapshot(for account: ProviderAccount) throws {
        try retireLegacyMigration(for: account)
        try makeAccountStore(account, false).deleteSnapshot(
            for: account.provider
        )
        indeterminateLoadIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: account.provider
            )
        )
        indeterminateLegacySourceIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: account.provider
            )
        )
    }

    func setSnapshotSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) throws {
        let store = makeAccountStore(account, false)
        try store.setSnapshotSuppressed(
            isSuppressed,
            for: account.provider
        )
        visibilityStore.setSnapshotSuppressed(
            isSuppressed,
            fileName: store.snapshotVisibilityKey(for: account.provider)
        )
    }

    func setSelectedProjectionSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) throws {
        try projectionStore.setProjectionDisplaySuppressed(
            isSuppressed,
            for: account.provider
        )
    }

    func publishSelectedSnapshot(
        _ snapshot: UsageSnapshot?,
        for account: ProviderAccount
    ) throws {
        let projectionKey = account.provider.snapshotFileName
        let exactAccountIsSafe = canSafelyPublishMissingSnapshot(
            for: account
        )
        let legacySourceIsIndeterminate =
            hasIndeterminateLegacySource(for: account.provider)
        guard exactAccountIsSafe, !legacySourceIsIndeterminate else {
            try projectionStore.setProjectionDisplaySuppressed(
                true,
                for: account.provider
            )
            if legacySourceIsIndeterminate {
                throw AccountUsageSnapshotRepositoryError
                    .legacyProjectionSourceIndeterminate(account.provider)
            }
            throw AccountUsageSnapshotRepositoryError.indeterminateSnapshot(
                provider: account.provider,
                accountLabel: account.label
            )
        }
        // Hide the prior selected account before an overwrite/delete attempt.
        // A disk failure therefore shows no widget data, never a sibling's.
        try projectionStore.setProjectionDisplaySuppressed(
            true,
            for: account.provider
        )
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
            try projectionStore.setProjectionDisplaySuppressed(
                false,
                for: account.provider
            )
        } catch {
            throw error
        }
    }

    private func legacyMigrationKey(for account: ProviderAccount) -> String {
        AccountSnapshotMigrationKey.usage(for: account)
    }

    private func legacyMigrationKey(
        for identity: SnapshotIdentity
    ) -> String {
        "usage_snapshot_account_migration_v1."
            + identity.provider.rawValue
            + "."
            + identity.accountID.uuidString.lowercased()
    }

    private func hasIndeterminateLegacySource(
        for provider: UsageProvider
    ) -> Bool {
        indeterminateLegacySourceIdentities = Set(
            indeterminateLegacySourceIdentities.filter {
                !migrationDefaults.bool(
                    forKey: legacyMigrationKey(for: $0)
                )
            }
        )
        return indeterminateLegacySourceIdentities.contains {
            $0.provider == provider
        }
    }

    private func retireLegacyMigration(
        for account: ProviderAccount
    ) throws {
        guard DurableDefaultsFlags.persistTrue(
            [legacyMigrationKey(for: account)],
            in: migrationDefaults
        ) else {
            throw AccountUsageSnapshotRepositoryError
                .migrationRetirementFailed
        }
        indeterminateLegacySourceIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: account.provider
            )
        )
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.fileReadNoSuchFile.rawValue
    }
}
