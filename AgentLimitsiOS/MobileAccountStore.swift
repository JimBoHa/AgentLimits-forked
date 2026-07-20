import Combine
import Foundation

enum MobileAccountStoreError: LocalizedError, Equatable {
    case accountNotFound
    case cannotRemoveLastAccount(MobileProvider)
    case tooManyAccounts(MobileProvider)
    case unsupportedVersion(Int)
    case orphanedCredentialCleanupFailed
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "The account no longer exists."
        case .cannotRemoveLastAccount(let provider):
            return "Keep at least one \(provider.displayName) account."
        case .tooManyAccounts(let provider):
            return "\(provider.displayName) already has the maximum number of accounts."
        case .unsupportedVersion(let version):
            return "These accounts were saved by a newer app version (\(version))."
        case .orphanedCredentialCleanupFailed:
            return "Saved credentials could not be cleared while account storage was repaired. Restart the app to retry."
        case .persistenceFailed:
            return "The account list could not be saved."
        }
    }
}

nonisolated struct MobileAccountRemovalPlan: Equatable, Sendable {
    let target: MobileProviderAccount
}

@MainActor
protocol MobileAccountResolving: AnyObject {
    var accounts: [MobileProviderAccount] { get }
    func account(id: UUID) -> MobileProviderAccount?
}

@MainActor
final class MobileAccountStore: ObservableObject, MobileAccountResolving {
    nonisolated static let persistenceKey = "mobile_provider_accounts_v1"

    private struct Payload: Codable {
        let version: Int
        let accounts: [MobileProviderAccount]
        let pendingCredentialDeletionIDs: [UUID]?

        init(
            version: Int,
            accounts: [MobileProviderAccount],
            pendingCredentialDeletionIDs: [UUID]
        ) {
            self.version = version
            self.accounts = accounts
            self.pendingCredentialDeletionIDs =
                pendingCredentialDeletionIDs.isEmpty
                    ? nil
                    : pendingCredentialDeletionIDs
        }
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private struct PendingCredentialDeletionSanitization {
        let ids: Set<UUID>
        let exceededMaximumCount: Bool
    }

    nonisolated private static let currentVersion = 1
    nonisolated static let maximumAccountsPerProvider = 32
    nonisolated private static let maximumPayloadBytes = 512 * 1_024
    nonisolated private static let allZeroUUID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    @Published private(set) var accounts: [MobileProviderAccount]
    @Published private(set) var didRecoverCorruptData = false
    @Published private(set) var didClearCredentialsDuringRecovery = false
    @Published private(set) var unsupportedStoredVersion: Int?
    @Published private(set) var recoveryFailure: MobileAccountStoreError?
    private(set) var pendingCredentialDeletionIDs: Set<UUID> = []

    private let defaults: UserDefaults
    private let key: String
    private let now: () -> Date
    private let purgeOrphanedCredentials: @MainActor () throws -> Void
    private let deleteCredential: @MainActor (UUID) throws -> Void
    private let persistenceWriter: (Data, String, UserDefaults) -> Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        key: String = MobileAccountStore.persistenceKey,
        now: @escaping () -> Date = Date.init,
        purgeOrphanedCredentials: @escaping @MainActor () throws -> Void = {},
        deleteCredential: @escaping @MainActor (UUID) throws -> Void = { _ in },
        persistenceWriter: ((Data, String, UserDefaults) -> Bool)? = nil
    ) {
        self.defaults = defaults
        self.key = key
        self.now = now
        self.purgeOrphanedCredentials = purgeOrphanedCredentials
        self.deleteCredential = deleteCredential
        self.persistenceWriter = persistenceWriter ?? { data, key, defaults in
            defaults.set(data, forKey: key)
            return defaults.data(forKey: key) == data
        }
        self.accounts = []
        load()
    }

    var canMutate: Bool {
        unsupportedStoredVersion == nil && recoveryFailure == nil
    }

    func accounts(for provider: MobileProvider) -> [MobileProviderAccount] {
        accounts.filter { $0.provider == provider }
    }

    func account(id: UUID) -> MobileProviderAccount? {
        accounts.first { $0.id == id }
    }

    func catalogSnapshot(for provider: MobileProvider) -> MobileAccountCatalogSnapshot {
        MobileAccountCatalogSnapshot(
            provider: provider,
            accounts: accounts(for: provider)
        )
    }

    @discardableResult
    func addAccount(
        provider: MobileProvider,
        label: String
    ) throws -> MobileProviderAccount {
        try requireMutable()
        guard accounts(for: provider).count < Self.maximumAccountsPerProvider else {
            throw MobileAccountStoreError.tooManyAccounts(provider)
        }
        var candidate: MobileProviderAccount
        repeat {
            candidate = MobileProviderAccount(
                provider: provider,
                label: label,
                createdAt: now()
            )
        } while accounts.contains { $0.id == candidate.id }

        var updated = accounts
        updated.append(candidate)
        try commit(updated)
        return candidate
    }

    @discardableResult
    func updateAccount(
        id: UUID,
        label: String,
        isEnabled: Bool
    ) throws -> MobileProviderAccount {
        try requireMutable()
        guard let index = accounts.firstIndex(where: { $0.id == id }) else {
            throw MobileAccountStoreError.accountNotFound
        }
        var updated = accounts
        updated[index] = updated[index].updating(
            label: label,
            isEnabled: isEnabled
        )
        try commit(updated)
        return updated[index]
    }

    func prepareRemoval(id: UUID) throws -> MobileAccountRemovalPlan {
        try requireMutable()
        guard let target = account(id: id) else {
            throw MobileAccountStoreError.accountNotFound
        }
        guard accounts.contains(where: {
            $0.provider == target.provider && $0.id != target.id
        }) else {
            throw MobileAccountStoreError.cannotRemoveLastAccount(
                target.provider
            )
        }
        return MobileAccountRemovalPlan(target: target)
    }

    func commitRemoval(_ plan: MobileAccountRemovalPlan) throws {
        try requireMutable()
        guard let current = account(id: plan.target.id),
              current.provider == plan.target.provider else {
            throw MobileAccountStoreError.accountNotFound
        }
        guard accounts.contains(where: {
            $0.provider == current.provider && $0.id != current.id
        }) else {
            throw MobileAccountStoreError.cannotRemoveLastAccount(
                current.provider
            )
        }
        try commit(accounts.filter { $0.id != current.id })
    }

    /// Persists the registry deletion and cleanup tombstone together. If the
    /// process exits after this boundary, the next launch retries exact
    /// credential deletion before allowing more mutations.
    @discardableResult
    func beginRemoval(
        _ plan: MobileAccountRemovalPlan
    ) throws -> MobileProviderAccount {
        try requireMutable()
        guard let current = account(id: plan.target.id),
              current.provider == plan.target.provider else {
            throw MobileAccountStoreError.accountNotFound
        }
        guard accounts.contains(where: {
            $0.provider == current.provider && $0.id != current.id
        }) else {
            throw MobileAccountStoreError.cannotRemoveLastAccount(
                current.provider
            )
        }
        var pending = pendingCredentialDeletionIDs
        pending.insert(current.id)
        try commitState(
            accounts.filter { $0.id != current.id },
            pendingCredentialDeletionIDs: pending
        )
        return current
    }

    func finishRemoval(_ plan: MobileAccountRemovalPlan) throws {
        try requireMutable()
        guard account(id: plan.target.id) == nil,
              pendingCredentialDeletionIDs.contains(plan.target.id) else {
            throw MobileAccountStoreError.accountNotFound
        }
        var pending = pendingCredentialDeletionIDs
        pending.remove(plan.target.id)
        try commitState(
            accounts,
            pendingCredentialDeletionIDs: pending
        )
    }

    func removeAccount(id: UUID) throws {
        try commitRemoval(prepareRemoval(id: id))
    }

    /// Merges the exact removed account into the current registry so rollback
    /// cannot overwrite mutations that completed during credential cleanup.
    func restoreRemoval(
        _ plan: MobileAccountRemovalPlan,
        removedAccount restored: MobileProviderAccount
    ) throws {
        try requireMutable()
        guard restored.id == plan.target.id,
              restored.provider == plan.target.provider else {
            throw MobileAccountStoreError.accountNotFound
        }
        var pending = pendingCredentialDeletionIDs
        pending.remove(plan.target.id)
        var updated = accounts
        if account(id: plan.target.id) == nil {
            updated.append(restored)
        }
        try commitState(
            updated,
            pendingCredentialDeletionIDs: pending
        )
    }

    private func load() {
        guard let storedObject = defaults.object(forKey: key) else {
            let defaults = makeDefaultAccounts()
            accounts = defaults
            do {
                // Keychain items can survive app deletion while UserDefaults
                // cannot. A missing registry therefore makes every credential
                // in this service unreachable and requires a service purge.
                try purgeOrphanedCredentials()
                try persist(
                    defaults,
                    pendingCredentialDeletionIDs: []
                )
            } catch let error as MobileAccountStoreError {
                recoveryFailure = error
            } catch {
                recoveryFailure = .orphanedCredentialCleanupFailed
            }
            return
        }
        guard let data = storedObject as? Data,
              data.count <= Self.maximumPayloadBytes else {
            recoverFromCorruption()
            return
        }
        if let header = try? decoder.decode(VersionHeader.self, from: data),
           header.version > Self.currentVersion {
            unsupportedStoredVersion = header.version
            accounts = makeDefaultAccounts()
            return
        }
        guard let payload = try? decoder.decode(Payload.self, from: data),
              payload.version == Self.currentVersion else {
            recoverFromCorruption()
            return
        }

        let sanitized = sanitize(payload.accounts)
        let pendingSanitization = sanitizePendingCredentialDeletionIDs(
            payload.pendingCredentialDeletionIDs ?? [],
            excluding: sanitized
        )
        let pending = pendingSanitization.ids
        accounts = sanitized
        pendingCredentialDeletionIDs = pending

        let accountsChanged = sanitized != payload.accounts
        let requiresCredentialPurge =
            !Self.hasSameAccountIdentity(sanitized, payload.accounts)
            || pendingSanitization.exceededMaximumCount
        if accountsChanged || pendingSanitization.exceededMaximumCount {
            didRecoverCorruptData = true
            do {
                if requiresCredentialPurge {
                    try purgeOrphanedCredentials()
                    didClearCredentialsDuringRecovery = true
                    pendingCredentialDeletionIDs.removeAll()
                    try persist(
                        sanitized,
                        pendingCredentialDeletionIDs: []
                    )
                } else {
                    // Labels and ordering are not part of the Keychain
                    // namespace. Repair them without deleting reachable
                    // credentials keyed by the unchanged account UUIDs.
                    try persist(
                        sanitized,
                        pendingCredentialDeletionIDs: pending
                    )
                }
            } catch let error as MobileAccountStoreError {
                recoveryFailure = error
                return
            } catch {
                recoveryFailure = .orphanedCredentialCleanupFailed
                return
            }
            if requiresCredentialPurge { return }
        }

        guard !pending.isEmpty else {
            if payload.pendingCredentialDeletionIDs != nil {
                try? persist(
                    sanitized,
                    pendingCredentialDeletionIDs: []
                )
            }
            return
        }
        reconcilePendingCredentialDeletions()
    }

    private func recoverFromCorruption() {
        didRecoverCorruptData = true
        let recovered = makeDefaultAccounts()
        accounts = recovered
        pendingCredentialDeletionIDs.removeAll()
        do {
            try purgeOrphanedCredentials()
            didClearCredentialsDuringRecovery = true
            try persist(
                recovered,
                pendingCredentialDeletionIDs: []
            )
        } catch let error as MobileAccountStoreError {
            recoveryFailure = error
        } catch {
            recoveryFailure = .orphanedCredentialCleanupFailed
        }
    }

    private func makeDefaultAccounts() -> [MobileProviderAccount] {
        let baseDate = now()
        return MobileProvider.allCases.enumerated().map { index, provider in
            MobileProviderAccount(
                provider: provider,
                label: provider.displayName,
                createdAt: baseDate.addingTimeInterval(
                    TimeInterval(index) / 1_000
                )
            )
        }
    }

    private func sanitize(
        _ source: [MobileProviderAccount]
    ) -> [MobileProviderAccount] {
        var seenIDs: Set<UUID> = []
        var providerCounts: [MobileProvider: Int] = [:]
        var result: [MobileProviderAccount] = []
        for account in source {
            guard providerCounts[account.provider, default: 0]
                    < Self.maximumAccountsPerProvider else {
                continue
            }
            var id = account.id
            if id == Self.allZeroUUID || seenIDs.contains(id) {
                repeat { id = UUID() } while seenIDs.contains(id)
            }
            seenIDs.insert(id)
            providerCounts[account.provider, default: 0] += 1
            result.append(MobileProviderAccount(
                id: id,
                provider: account.provider,
                label: account.label,
                isEnabled: account.isEnabled,
                createdAt: account.createdAt
            ))
        }

        let baseDate = now()
        for (index, provider) in MobileProvider.allCases.enumerated()
        where !result.contains(where: { $0.provider == provider }) {
            var account: MobileProviderAccount
            repeat {
                account = MobileProviderAccount(
                    provider: provider,
                    label: provider.displayName,
                    createdAt: baseDate.addingTimeInterval(
                        TimeInterval(index) / 1_000
                    )
                )
            } while seenIDs.contains(account.id)
            seenIDs.insert(account.id)
            result.append(account)
        }

        let providerOrder = Dictionary(
            uniqueKeysWithValues: MobileProvider.allCases.enumerated().map {
                ($1, $0)
            }
        )
        return result.sorted {
            let leftProvider = providerOrder[$0.provider] ?? .max
            let rightProvider = providerOrder[$1.provider] ?? .max
            if leftProvider != rightProvider {
                return leftProvider < rightProvider
            }
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private static func hasSameAccountIdentity(
        _ lhs: [MobileProviderAccount],
        _ rhs: [MobileProviderAccount]
    ) -> Bool {
        lhs.count == rhs.count && Set(lhs.map(\.id)) == Set(rhs.map(\.id))
    }

    private func commit(_ updated: [MobileProviderAccount]) throws {
        try commitState(
            updated,
            pendingCredentialDeletionIDs: pendingCredentialDeletionIDs
        )
    }

    private func commitState(
        _ updated: [MobileProviderAccount],
        pendingCredentialDeletionIDs pending: Set<UUID>
    ) throws {
        let sanitized = sanitize(updated)
        let sanitizedPending = sanitizePendingCredentialDeletionIDs(
            Array(pending),
            excluding: sanitized
        ).ids
        try persist(
            sanitized,
            pendingCredentialDeletionIDs: sanitizedPending
        )
        accounts = sanitized
        pendingCredentialDeletionIDs = sanitizedPending
    }

    private func persist(
        _ value: [MobileProviderAccount],
        pendingCredentialDeletionIDs: Set<UUID>
    ) throws {
        let payload = Payload(
            version: Self.currentVersion,
            accounts: value,
            pendingCredentialDeletionIDs:
                pendingCredentialDeletionIDs.sorted {
                    $0.uuidString < $1.uuidString
                }
        )
        guard let data = try? encoder.encode(payload) else {
            throw MobileAccountStoreError.persistenceFailed
        }
        guard data.count <= Self.maximumPayloadBytes else {
            throw MobileAccountStoreError.persistenceFailed
        }
        guard persistenceWriter(data, key, defaults) else {
            throw MobileAccountStoreError.persistenceFailed
        }
    }

    private func sanitizePendingCredentialDeletionIDs(
        _ source: [UUID],
        excluding accounts: [MobileProviderAccount]
    ) -> PendingCredentialDeletionSanitization {
        let activeIDs = Set(accounts.map(\.id))
        let maximumCount = MobileProvider.allCases.count
            * Self.maximumAccountsPerProvider
        var result: Set<UUID> = []
        for id in source
        where id != Self.allZeroUUID && !activeIDs.contains(id) {
            result.insert(id)
            if result.count > maximumCount {
                return PendingCredentialDeletionSanitization(
                    ids: Set(result.prefix(maximumCount)),
                    exceededMaximumCount: true
                )
            }
        }
        return PendingCredentialDeletionSanitization(
            ids: result,
            exceededMaximumCount: false
        )
    }

    private func reconcilePendingCredentialDeletions() {
        do {
            for accountID in pendingCredentialDeletionIDs.sorted(by: {
                $0.uuidString < $1.uuidString
            }) {
                try deleteCredential(accountID)
            }
            try persist(
                accounts,
                pendingCredentialDeletionIDs: []
            )
            pendingCredentialDeletionIDs.removeAll()
        } catch let error as MobileAccountStoreError {
            recoveryFailure = error
        } catch {
            recoveryFailure = .orphanedCredentialCleanupFailed
        }
    }

    private func requireMutable() throws {
        if let unsupportedStoredVersion {
            throw MobileAccountStoreError.unsupportedVersion(
                unsupportedStoredVersion
            )
        }
        if let recoveryFailure {
            throw recoveryFailure
        }
    }
}
