import Foundation
import OSLog

enum AccountTokenUsageSnapshotRepositoryError: LocalizedError, Equatable {
    case providerMismatch
    case migrationRetirementFailed
    case legacyProjectionSourceIndeterminate(TokenUsageProvider)
    case snapshotReadIndeterminate(TokenUsageProvider)

    var errorDescription: String? {
        switch self {
        case .providerMismatch:
            return "Token snapshot provider does not match the account."
        case .migrationRetirementFailed:
            return "Could not durably retire legacy token snapshot migration."
        case .legacyProjectionSourceIndeterminate(let provider):
            return "Could not safely replace the preserved \(provider.displayName) token-usage source. Try again."
        case .snapshotReadIndeterminate(let provider):
            return "Could not safely read the selected \(provider.displayName) token-usage snapshot. Try again."
        }
    }
}

/// Account UUID is mandatory for token-usage persistence. Provider-only files
/// remain a selected-account projection for existing static widgets.
@MainActor
protocol AccountTokenUsageSnapshotRepository {
    func loadSnapshot(for account: ProviderAccount) -> TokenUsageSnapshot?
    /// False means a read failed for a retryable reason. Automatic startup
    /// projection must then preserve the last known provider file.
    func canSafelyPublishMissingSnapshot(
        for account: ProviderAccount
    ) -> Bool
    func canSafelyMutateSelectedProjection(
        for account: ProviderAccount
    ) -> Bool
    func saveSnapshot(
        _ snapshot: TokenUsageSnapshot,
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
        _ snapshot: TokenUsageSnapshot?,
        for account: ProviderAccount
    ) throws
}

extension AccountTokenUsageSnapshotRepository {
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
final class DefaultAccountTokenUsageSnapshotRepository:
    AccountTokenUsageSnapshotRepository {
    private struct SnapshotIdentity: Hashable {
        let accountID: UUID
        let provider: TokenUsageProvider
    }

    private let visibilityStore: any SnapshotVisibilityControlling
    private let migrationDefaults: UserDefaults
    private let makeAccountStore:
        (ProviderAccount, Bool) -> TokenUsageSnapshotStore
    private let projectionStore: TokenUsageSnapshotStore
    private var indeterminateLoadIdentities: Set<SnapshotIdentity> = []
    private var indeterminateLegacySourceIdentities:
        Set<SnapshotIdentity> = []

    init(
        visibilityStore: (any SnapshotVisibilityControlling)? = nil,
        migrationDefaults: UserDefaults = .standard,
        makeAccountStore:
            ((ProviderAccount, Bool) -> TokenUsageSnapshotStore)? = nil,
        projectionStore: TokenUsageSnapshotStore? = nil
    ) {
        let resolvedVisibilityStore = visibilityStore
            ?? SnapshotVisibilityStore.shared
        self.visibilityStore = resolvedVisibilityStore
        self.migrationDefaults = migrationDefaults
        self.makeAccountStore = makeAccountStore ?? {
            account, migratesLegacySnapshot in
            TokenUsageSnapshotStore(
                visibilityStore: resolvedVisibilityStore,
                accountID: account.id,
                migratesLegacySnapshot: migratesLegacySnapshot
            )
        }
        self.projectionStore = projectionStore ?? .shared
    }

    func loadSnapshot(for account: ProviderAccount) -> TokenUsageSnapshot? {
        let provider = tokenProvider(for: account)
        let identity = SnapshotIdentity(
            accountID: account.id,
            provider: provider
        )
        indeterminateLoadIdentities.remove(identity)
        indeterminateLegacySourceIdentities.remove(identity)
        let migrationKey = legacyMigrationKey(for: account)
        let shouldMigrate = account.webKitStorage == .legacyDefault
            && !migrationDefaults.bool(forKey: migrationKey)
        let store = makeAccountStore(account, shouldMigrate)
        let snapshot: TokenUsageSnapshot?
        let migrationReachedDurableTerminalState: Bool
        let loadWasIndeterminate: Bool
        do {
            snapshot = try store.tryLoadSnapshot(for: provider)
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
                // A missing scoped file completes a "nothing to migrate"
                // result. Other I/O failures remain retryable.
                let isMissing = Self.isMissingFile(underlying)
                migrationReachedDurableTerminalState = isMissing
                loadWasIndeterminate = !isMissing
            case .appGroupUnavailable:
                migrationReachedDurableTerminalState = false
                loadWasIndeterminate = true
            }
        } catch {
            snapshot = nil
            // Suppression presents as a missing file after the account-scoped
            // migration marker has been persisted.
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
            // Keep this marker outside the removable account namespace. A
            // failed removal must never make another projection importable.
            if !DurableDefaultsFlags.persistTrue(
                [migrationKey],
                in: migrationDefaults
            ) {
                indeterminateLoadIdentities.insert(identity)
                indeterminateLegacySourceIdentities.insert(identity)
                Logger.ccusage.error(
                    "Could not durably finish legacy token snapshot migration"
                )
            }
        }
        guard let snapshot else { return nil }
        guard snapshot.provider == provider else {
            // Preserve corrupt/misplaced data for recovery, but never expose it
            // as another account's usage.
            visibilityStore.setSnapshotSuppressed(
                true,
                fileName: store.snapshotVisibilityKey(for: provider)
            )
            Logger.ccusage.error(
                "Rejected account token snapshot with mismatched provider"
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
                provider: tokenProvider(for: account)
            )
        )
    }

    func canSafelyMutateSelectedProjection(
        for account: ProviderAccount
    ) -> Bool {
        canSafelyPublishMissingSnapshot(for: account)
            && !hasIndeterminateLegacySource(
                for: tokenProvider(for: account)
            )
    }

    func saveSnapshot(
        _ snapshot: TokenUsageSnapshot,
        for account: ProviderAccount
    ) throws {
        let provider = tokenProvider(for: account)
        guard snapshot.provider == provider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        try makeAccountStore(account, false).saveSnapshot(snapshot)
        indeterminateLoadIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: provider
            )
        )
        indeterminateLegacySourceIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: provider
            )
        )
    }

    func deleteSnapshot(for account: ProviderAccount) throws {
        let provider = tokenProvider(for: account)
        try retireLegacyMigration(for: account)
        try makeAccountStore(account, false).deleteSnapshot(
            for: provider
        )
        indeterminateLoadIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: provider
            )
        )
        indeterminateLegacySourceIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: provider
            )
        )
    }

    func setSnapshotSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) throws {
        let provider = tokenProvider(for: account)
        let store = makeAccountStore(account, false)
        try store.setSnapshotSuppressed(isSuppressed, for: provider)
        visibilityStore.setSnapshotSuppressed(
            isSuppressed,
            fileName: store.snapshotVisibilityKey(for: provider)
        )
    }

    func setSelectedProjectionSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) throws {
        let provider = tokenProvider(for: account)
        try projectionStore.setProjectionDisplaySuppressed(
            isSuppressed,
            for: provider
        )
    }

    func publishSelectedSnapshot(
        _ snapshot: TokenUsageSnapshot?,
        for account: ProviderAccount
    ) throws {
        let provider = tokenProvider(for: account)
        let projectionKey = provider.snapshotFileName
        let exactAccountIsSafe = canSafelyPublishMissingSnapshot(
            for: account
        )
        let legacySourceIsIndeterminate =
            hasIndeterminateLegacySource(for: provider)
        guard exactAccountIsSafe, !legacySourceIsIndeterminate else {
            try projectionStore.setProjectionDisplaySuppressed(
                true,
                for: provider
            )
            if legacySourceIsIndeterminate {
                throw AccountTokenUsageSnapshotRepositoryError
                    .legacyProjectionSourceIndeterminate(provider)
            }
            throw AccountTokenUsageSnapshotRepositoryError
                .snapshotReadIndeterminate(provider)
        }
        // Hide the prior account before overwrite/delete. Failure therefore
        // yields no widget data instead of exposing a sibling's snapshot.
        try projectionStore.setProjectionDisplaySuppressed(
            true,
            for: provider
        )
        do {
            if let snapshot {
                guard snapshot.provider == provider else {
                    throw AccountTokenUsageSnapshotRepositoryError
                        .providerMismatch
                }
                try projectionStore.saveSnapshot(snapshot)
            } else {
                try projectionStore.deleteSnapshot(for: provider)
            }
            visibilityStore.setSnapshotSuppressed(
                false,
                fileName: projectionKey
            )
            try projectionStore.setProjectionDisplaySuppressed(
                false,
                for: provider
            )
        } catch {
            throw error
        }
    }

    private func tokenProvider(
        for account: ProviderAccount
    ) -> TokenUsageProvider {
        guard let provider = account.provider.tokenUsageProvider else {
            preconditionFailure("Usage provider has no token-usage mapping")
        }
        return provider
    }

    private func legacyMigrationKey(for account: ProviderAccount) -> String {
        AccountSnapshotMigrationKey.tokenUsage(for: account)
    }

    private func legacyMigrationKey(
        for identity: SnapshotIdentity
    ) -> String {
        "token_usage_snapshot_account_migration_v1."
            + identity.provider.usageProvider.rawValue
            + "."
            + identity.accountID.uuidString.lowercased()
    }

    private func hasIndeterminateLegacySource(
        for provider: TokenUsageProvider
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

    /// Explicit deletion must be terminal before the scoped file disappears;
    /// otherwise a crash could later import a sibling/provider projection.
    private func retireLegacyMigration(
        for account: ProviderAccount
    ) throws {
        guard DurableDefaultsFlags.persistTrue(
            [legacyMigrationKey(for: account)],
            in: migrationDefaults
        ) else {
            throw AccountTokenUsageSnapshotRepositoryError
                .migrationRetirementFailed
        }
        indeterminateLegacySourceIdentities.remove(
            SnapshotIdentity(
                accountID: account.id,
                provider: tokenProvider(for: account)
            )
        )
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let cocoaError = error as NSError
        return cocoaError.domain == NSCocoaErrorDomain
            && cocoaError.code == CocoaError.fileReadNoSuchFile.rawValue
    }
}
