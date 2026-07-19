import Foundation

/// Selects the persistent WebKit data store used by a provider account.
///
/// The original account for an existing install keeps the shared default store
/// so an upgrade does not sign the user out. Every subsequently created account
/// receives an identified store keyed by its immutable UUID.
enum ProviderAccountWebKitStorage:
    String,
    Codable,
    Equatable,
    Hashable,
    Sendable {
    case legacyDefault
    case isolated
}

/// A separately tracked login/profile for one usage provider.
///
/// The stable UUID is also suitable for an isolated WebKit data store and an
/// account-scoped snapshot namespace. A nil CLI data root means the provider's
/// normal default profile directory.
struct ProviderAccount:
    Codable,
    Equatable,
    Hashable,
    Identifiable,
    Sendable {
    let id: UUID
    let provider: UsageProvider
    var label: String
    var isEnabled: Bool
    var cliDataRoot: String?
    let createdAt: Date
    let webKitStorage: ProviderAccountWebKitStorage
    fileprivate let needsWebKitStorageRepair: Bool

    private static let allZeroUUIDString = "00000000-0000-0000-0000-000000000000"

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case label
        case isEnabled
        case cliDataRoot
        case createdAt
        case webKitStorage
    }

    init(
        id: UUID = UUID(),
        provider: UsageProvider,
        label: String,
        isEnabled: Bool = true,
        cliDataRoot: String? = nil,
        createdAt: Date = Date(),
        webKitStorage: ProviderAccountWebKitStorage = .isolated
    ) {
        let hasUsableIdentifier = Self.isUsableWebKitIdentifier(id)
        self.id = hasUsableIdentifier ? id : UUID()
        self.provider = provider
        self.label = Self.normalizeLabel(label, fallback: provider.displayName)
        self.isEnabled = isEnabled
        self.cliDataRoot = Self.normalizeOptionalPath(cliDataRoot)
        self.createdAt = createdAt
        // Rekeying creates a new identity, which may never inherit the shared
        // cookie store even when a caller supplied an unsafe designation.
        self.webKitStorage = hasUsableIdentifier ? webKitStorage : .isolated
        self.needsWebKitStorageRepair = false
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Preserve invalid IDs until the store sanitizes and durably replaces
        // them. WKWebsiteDataStore raises an Objective-C exception for zero.
        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decode(UsageProvider.self, forKey: .provider)
        label = try container.decode(String.self, forKey: .label)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        cliDataRoot = try container.decodeIfPresent(String.self, forKey: .cliDataRoot)
        createdAt = try container.decode(Date.self, forKey: .createdAt)

        let storageRawValue = try? container.decode(String.self, forKey: .webKitStorage)
        if let storage = storageRawValue.flatMap(ProviderAccountWebKitStorage.init(rawValue:)) {
            webKitStorage = storage
            needsWebKitStorageRepair = false
        } else {
            webKitStorage = .isolated
            needsWebKitStorageRepair = true
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(provider, forKey: .provider)
        try container.encode(label, forKey: .label)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encodeIfPresent(cliDataRoot, forKey: .cliDataRoot)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(webKitStorage.rawValue, forKey: .webKitStorage)
    }

    static func == (lhs: ProviderAccount, rhs: ProviderAccount) -> Bool {
        lhs.id == rhs.id
            && lhs.provider == rhs.provider
            && lhs.label == rhs.label
            && lhs.isEnabled == rhs.isEnabled
            && lhs.cliDataRoot == rhs.cliDataRoot
            && lhs.createdAt == rhs.createdAt
            && lhs.webKitStorage == rhs.webKitStorage
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(provider)
        hasher.combine(label)
        hasher.combine(isEnabled)
        hasher.combine(cliDataRoot)
        hasher.combine(createdAt)
        hasher.combine(webKitStorage)
    }

    var snapshotNamespace: String {
        id.uuidString.lowercased()
    }

    /// Identifier for an account's persistent WebKit store. Legacy accounts
    /// deliberately return nil because they use WKWebsiteDataStore.default().
    var isolatedWebKitDataStoreIdentifier: UUID? {
        guard webKitStorage == .isolated,
              Self.isUsableWebKitIdentifier(id) else {
            return nil
        }
        return id
    }

    func updating(
        label: String,
        isEnabled: Bool,
        cliDataRoot: String?
    ) -> ProviderAccount {
        ProviderAccount(
            id: id,
            provider: provider,
            label: label,
            isEnabled: isEnabled,
            cliDataRoot: cliDataRoot,
            createdAt: createdAt,
            webKitStorage: webKitStorage
        )
    }

    fileprivate static func isUsableWebKitIdentifier(_ id: UUID) -> Bool {
        id.uuidString != allZeroUUIDString
    }

    fileprivate static func normalizeLabel(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? fallback : trimmed
        return String(resolved.prefix(80))
    }

    fileprivate static func normalizeOptionalPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum ProviderAccountStoreError: LocalizedError, Equatable {
    case accountNotFound
    case cannotRemoveLastAccount(UsageProvider)
    case unsupportedVersion(Int)
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "The provider account no longer exists."
        case .cannotRemoveLastAccount(let provider):
            return "Keep at least one \(provider.displayName) account. Disable it instead if needed."
        case .unsupportedVersion(let version):
            return "These provider accounts were saved by a newer app version (\(version)). Update AgentLimits before changing them."
        case .persistenceFailed:
            return "The provider account list could not be saved."
        }
    }
}

struct ProviderAccountRemovalPlan: Equatable {
    let target: ProviderAccount
    let replacement: ProviderAccount
    let targetWasSelected: Bool
}

struct ProviderAccountRemovalCommit: Equatable {
    let removed: ProviderAccount
    let replacement: ProviderAccount
    let queuedWebKitDataStoreIdentifier: UUID?
}

/// Persists the account registry independently from cookies and usage data.
/// Existing installs automatically receive one stable account per provider.
@MainActor
struct ProviderAccountStore {
    static let shared = ProviderAccountStore()

    private struct Payload: Codable {
        let version: Int
        let accounts: [ProviderAccount]
        let pendingWebKitDataStoreDeletionIDs: [UUID]

        private enum CodingKeys: String, CodingKey {
            case version
            case accounts
            case pendingWebKitDataStoreDeletionIDs
        }

        init(
            version: Int,
            accounts: [ProviderAccount],
            pendingWebKitDataStoreDeletionIDs: Set<UUID>
        ) {
            self.version = version
            self.accounts = accounts
            self.pendingWebKitDataStoreDeletionIDs =
                pendingWebKitDataStoreDeletionIDs.sorted {
                    $0.uuidString < $1.uuidString
                }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decode(Int.self, forKey: .version)
            accounts = try container.decode(
                [ProviderAccount].self,
                forKey: .accounts
            )
            let decodedIDs: [UUID]
            if version >= ProviderAccountStore.currentVersion {
                decodedIDs = try container.decode(
                    [UUID].self,
                    forKey: .pendingWebKitDataStoreDeletionIDs
                )
            } else {
                decodedIDs = try container.decodeIfPresent(
                    [UUID].self,
                    forKey: .pendingWebKitDataStoreDeletionIDs
                ) ?? []
            }
            pendingWebKitDataStoreDeletionIDs = Array(Set(decodedIDs.filter {
                ProviderAccount.isUsableWebKitIdentifier($0)
            })).sorted {
                $0.uuidString < $1.uuidString
            }
        }
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private struct PendingDeletionSalvage: Decodable {
        let pendingWebKitDataStoreDeletionIDs: [UUID]?
    }

    nonisolated private static let currentVersion = 3
    nonisolated private static let webKitStorageVersion = 2
    private let userDefaults: UserDefaults
    private let key: String
    private let synchronizeDefaults: (UserDefaults) -> Bool
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults? = nil,
        key: String = "provider_accounts_v1",
        synchronizeDefaults: @escaping (UserDefaults) -> Bool = {
            $0.synchronize()
        }
    ) {
        self.userDefaults = userDefaults ?? AppGroupDefaults.shared ?? .standard
        self.key = key
        self.synchronizeDefaults = synchronizeDefaults
    }

    /// Persistent web sessions are safe only when this app understands the
    /// stored registry identities. Downgrades use ephemeral WebKit sessions so
    /// placeholder IDs cannot strand credentials after a compatible relaunch.
    var supportsPersistentWebSessions: Bool {
        unsupportedStoredVersion() == nil
    }

    /// Identified WebKit stores whose accounts are already gone but whose
    /// static WebKit deletion has not yet been confirmed.
    var pendingWebKitDataStoreDeletionIDs: Set<UUID> {
        guard unsupportedStoredVersion() == nil,
              let payload = storedPayload() else {
            return []
        }
        return sanitizePendingDeletionIDs(
            Set(payload.pendingWebKitDataStoreDeletionIDs),
            activeAccountIDs: Set(payload.accounts.map(\.id))
        )
    }

    func loadAccounts() -> [ProviderAccount] {
        guard let storedValue = userDefaults.object(forKey: key) else {
            let accounts = makeDefaultAccounts(webKitStorage: .legacyDefault)
            try? persist(accounts)
            return accounts
        }

        guard let data = storedValue as? Data else {
            return recoverCorruptAccounts()
        }

        if let header = try? decoder.decode(VersionHeader.self, from: data),
           header.version > Self.currentVersion {
            // Never reinterpret or overwrite a registry created by a newer
            // schema. Stable isolated placeholders keep this downgrade safe.
            return makeUnsupportedVersionAccounts()
        }

        guard let payload = try? decoder.decode(Payload.self, from: data) else {
            return recoverCorruptAccounts(
                pendingDeletionIDs: salvagePendingDeletionIDs(from: data)
            )
        }

        let accounts = sanitize(
            payload.accounts,
            migratesLegacyWebKitStorage: payload.version < Self.webKitStorageVersion
        )
        let pendingDeletionIDs = sanitizePendingDeletionIDs(
            Set(payload.pendingWebKitDataStoreDeletionIDs),
            activeAccountIDs: Set(accounts.map(\.id))
        )
        // Do not rewrite data produced by a newer app version: it may contain
        // fields this version cannot preserve.
        if payload.version <= Self.currentVersion,
           payload.version != Self.currentVersion
            || accounts != payload.accounts
            || payload.accounts.contains(where: \.needsWebKitStorageRepair)
            || pendingDeletionIDs
                != Set(payload.pendingWebKitDataStoreDeletionIDs) {
            try? persist(
                accounts,
                pendingDeletionIDs: pendingDeletionIDs
            )
        }
        return accounts
    }

    func accounts(for provider: UsageProvider) -> [ProviderAccount] {
        loadAccounts().filter { $0.provider == provider }
    }

    func account(id: UUID) -> ProviderAccount? {
        loadAccounts().first { $0.id == id }
    }

    @MainActor
    func primaryAccount(for provider: UsageProvider) -> ProviderAccount {
        selectedAccount(for: provider)
    }

    /// Returns the persisted account selection for one provider. Invalid,
    /// missing, and cross-provider selections repair to a deterministic local
    /// account without displacing a valid disabled selection.
    @MainActor
    func selectedAccount(for provider: UsageProvider) -> ProviderAccount {
        let providerAccounts = accounts(for: provider)
        let selectionKey = selectedAccountKey(for: provider)
        if let rawID = userDefaults.string(forKey: selectionKey),
           let selectedID = UUID(uuidString: rawID),
           let selected = providerAccounts.first(where: { $0.id == selectedID }) {
            return selected
        }

        let fallback = providerAccounts.first(where: \.isEnabled)
            ?? providerAccounts.first
            ?? ProviderAccount(
                provider: provider,
                label: provider.displayName,
                webKitStorage: .isolated
            )
        if unsupportedStoredVersion() == nil {
            userDefaults.set(fallback.id.uuidString.lowercased(), forKey: selectionKey)
        }
        return fallback
    }

    @MainActor
    @discardableResult
    func selectAccount(id: UUID) throws -> ProviderAccount {
        try requireSupportedMutationVersion()
        guard let account = account(id: id) else {
            throw ProviderAccountStoreError.accountNotFound
        }
        userDefaults.set(
            account.id.uuidString.lowercased(),
            forKey: selectedAccountKey(for: account.provider)
        )
        return account
    }

    @MainActor
    @discardableResult
    func addAccount(
        provider: UsageProvider,
        label: String,
        cliDataRoot: String? = nil
    ) throws -> ProviderAccount {
        try requireSupportedMutationVersion()
        var accounts = loadAccounts()
        let blockedIDs = pendingWebKitDataStoreDeletionIDs
        var account: ProviderAccount
        repeat {
            account = ProviderAccount(
                provider: provider,
                label: label,
                cliDataRoot: cliDataRoot
            )
        } while blockedIDs.contains(account.id)
        accounts.append(account)
        try persist(sanitize(accounts))
        return account
    }

    /// Adds and selects one stable creation UUID. If UserDefaults reports an
    /// ambiguous registry write, the exact UUID is reconciled before selection;
    /// retrying with that UUID can therefore never create a duplicate account.
    @MainActor
    @discardableResult
    func addAndSelectAccount(
        id: UUID = UUID(),
        provider: UsageProvider,
        label: String,
        cliDataRoot: String? = nil
    ) throws -> ProviderAccount {
        try requireSupportedMutationVersion()
        let candidate = ProviderAccount(
            id: id,
            provider: provider,
            label: label,
            cliDataRoot: cliDataRoot
        )
        guard candidate.id == id,
              !pendingWebKitDataStoreDeletionIDs.contains(id) else {
            throw ProviderAccountStoreError.persistenceFailed
        }

        let account: ProviderAccount
        if let existing = self.account(id: id) {
            guard existing.provider == provider,
                  existing.webKitStorage == .isolated else {
                throw ProviderAccountStoreError.persistenceFailed
            }
            let requested = existing.updating(
                label: candidate.label,
                isEnabled: candidate.isEnabled,
                cliDataRoot: candidate.cliDataRoot
            )
            if requested != existing {
                do {
                    try updateAccount(requested)
                    account = requested
                } catch {
                    guard self.account(id: id) == requested else {
                        throw error
                    }
                    account = requested
                }
            } else {
                account = existing
            }
        } else {
            var accounts = loadAccounts()
            accounts.append(candidate)
            do {
                try persist(sanitize(accounts))
                account = candidate
            } catch {
                // set() may have updated the domain even when synchronize()
                // reports failure. Accept only the exact requested identity.
                guard let reconciled = self.account(id: id),
                      reconciled.provider == provider,
                      reconciled.webKitStorage == .isolated else {
                    throw error
                }
                account = reconciled
            }
        }

        let selectedID = account.id.uuidString.lowercased()
        userDefaults.set(
            selectedID,
            forKey: selectedAccountKey(for: provider)
        )
        _ = synchronizeDefaults(userDefaults)
        guard userDefaults.string(
            forKey: selectedAccountKey(for: provider)
        ) == selectedID else {
            throw ProviderAccountStoreError.persistenceFailed
        }
        return account
    }

    @MainActor
    func updateAccount(_ account: ProviderAccount) throws {
        try requireSupportedMutationVersion()
        var accounts = loadAccounts()
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else {
            throw ProviderAccountStoreError.accountNotFound
        }
        // Provider and creation identity are immutable even if a caller builds
        // an inconsistent replacement value.
        accounts[index] = ProviderAccount(
            id: accounts[index].id,
            provider: accounts[index].provider,
            label: account.label,
            isEnabled: account.isEnabled,
            cliDataRoot: account.cliDataRoot,
            createdAt: accounts[index].createdAt,
            webKitStorage: accounts[index].webKitStorage
        )
        try persist(sanitize(accounts))
    }

    /// Validates a removal and switches selection away from the target before
    /// any awaited cleanup. This invalidates account-bound async work.
    @MainActor
    func prepareRemoval(id: UUID) throws -> ProviderAccountRemovalPlan {
        try requireSupportedMutationVersion()
        let accounts = loadAccounts()
        guard let target = accounts.first(where: { $0.id == id }) else {
            throw ProviderAccountStoreError.accountNotFound
        }
        let siblings = accounts.filter {
            $0.provider == target.provider && $0.id != target.id
        }
        guard let replacement = siblings.first(where: \.isEnabled)
            ?? siblings.first else {
            throw ProviderAccountStoreError.cannotRemoveLastAccount(target.provider)
        }
        let targetWasSelected = selectedAccount(for: target.provider).id == target.id
        if targetWasSelected {
            userDefaults.set(
                replacement.id.uuidString.lowercased(),
                forKey: selectedAccountKey(for: target.provider)
            )
        }
        return ProviderAccountRemovalPlan(
            target: target,
            replacement: replacement,
            targetWasSelected: targetWasSelected
        )
    }

    /// Atomically removes the registry entry and queues its identified WebKit
    /// store for deletion. Call only after the target session is quiesced and
    /// account-scoped local data is gone.
    @MainActor
    func commitRemoval(
        _ plan: ProviderAccountRemovalPlan
    ) throws -> ProviderAccountRemovalCommit {
        try requireSupportedMutationVersion()
        var accounts = loadAccounts()
        guard let currentTarget = accounts.first(where: { $0.id == plan.target.id }),
              currentTarget.provider == plan.target.provider,
              currentTarget.webKitStorage == plan.target.webKitStorage else {
            throw ProviderAccountStoreError.accountNotFound
        }
        guard accounts.contains(where: {
            $0.provider == currentTarget.provider && $0.id != currentTarget.id
        }) else {
            throw ProviderAccountStoreError.cannotRemoveLastAccount(
                currentTarget.provider
            )
        }

        accounts.removeAll { $0.id == currentTarget.id }
        let sanitized = sanitize(accounts)
        var pendingIDs = pendingWebKitDataStoreDeletionIDs
        let queuedIdentifier = currentTarget.isolatedWebKitDataStoreIdentifier
        if let queuedIdentifier {
            pendingIDs.insert(queuedIdentifier)
        }
        try persist(sanitized, pendingDeletionIDs: pendingIDs)
        let replacement = repairSelection(
            for: currentTarget.provider,
            among: sanitized
        )
        return ProviderAccountRemovalCommit(
            removed: currentTarget,
            replacement: replacement,
            queuedWebKitDataStoreIdentifier: queuedIdentifier
        )
    }

    /// Removes one durable cleanup tombstone only after WebKit confirms the
    /// identified store no longer exists. Missing tombstones are idempotent.
    @MainActor
    func markWebKitDataStoreDeletionComplete(id: UUID) throws {
        try requireSupportedMutationVersion()
        var pendingIDs = pendingWebKitDataStoreDeletionIDs
        guard pendingIDs.remove(id) != nil else { return }
        try persist(loadAccounts(), pendingDeletionIDs: pendingIDs)
    }

    private func makeDefaultAccounts(
        webKitStorage: ProviderAccountWebKitStorage
    ) -> [ProviderAccount] {
        let now = Date()
        return UsageProvider.allCases.enumerated().map { offset, provider in
            ProviderAccount(
                provider: provider,
                label: provider.displayName,
                createdAt: now.addingTimeInterval(TimeInterval(offset) / 1_000),
                webKitStorage: webKitStorage
            )
        }
    }

    private func sanitize(
        _ accounts: [ProviderAccount],
        migratesLegacyWebKitStorage: Bool = false
    ) -> [ProviderAccount] {
        let providerOrder = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.enumerated().map { ($1, $0) }
        )
        // Resolve invalid and duplicate IDs in a canonical order so serialized
        // array order cannot decide which identity retains its credentials.
        let identityOrdered = accounts.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            let leftProvider = providerOrder[$0.provider] ?? .max
            let rightProvider = providerOrder[$1.provider] ?? .max
            if leftProvider != rightProvider { return leftProvider < rightProvider }
            if $0.id != $1.id { return $0.id.uuidString < $1.id.uuidString }
            if $0.label != $1.label { return $0.label < $1.label }
            let leftRoot = ProviderAccount.normalizeOptionalPath($0.cliDataRoot)
            let rightRoot = ProviderAccount.normalizeOptionalPath($1.cliDataRoot)
            switch (leftRoot, rightRoot) {
            case (nil, .some):
                return true
            case (.some, nil):
                return false
            case let (.some(left), .some(right)) where left != right:
                return left < right
            default:
                break
            }
            if $0.isEnabled != $1.isEnabled { return !$0.isEnabled }
            return $0.webKitStorage.rawValue < $1.webKitStorage.rawValue
        }

        var seenIDs: Set<UUID> = []
        var normalized: [(account: ProviderAccount, identityWasRepaired: Bool)] = []
        for account in identityOrdered {
            var id = account.id
            let identityWasRepaired = !ProviderAccount.isUsableWebKitIdentifier(id)
                || seenIDs.contains(id)
            if identityWasRepaired {
                repeat { id = UUID() } while !seenIDs.insert(id).inserted
            } else {
                seenIDs.insert(id)
            }
            normalized.append((ProviderAccount(
                id: id,
                provider: account.provider,
                label: account.label,
                isEnabled: account.isEnabled,
                cliDataRoot: account.cliDataRoot,
                createdAt: account.createdAt,
                webKitStorage: identityWasRepaired || migratesLegacyWebKitStorage
                    ? .isolated
                    : account.webKitStorage
            ), identityWasRepaired))
        }

        if migratesLegacyWebKitStorage {
            let legacyIDs = Set(UsageProvider.allCases.compactMap { provider in
                normalized
                    .filter {
                        $0.account.provider == provider && !$0.identityWasRepaired
                    }
                    .map { $0.account }
                    .min {
                        if $0.createdAt != $1.createdAt {
                            return $0.createdAt < $1.createdAt
                        }
                        return $0.id.uuidString < $1.id.uuidString
                    }?.id
            })
            normalized = normalized.map { item in
                guard legacyIDs.contains(item.account.id) else { return item }
                return (ProviderAccount(
                    id: item.account.id,
                    provider: item.account.provider,
                    label: item.account.label,
                    isEnabled: item.account.isEnabled,
                    cliDataRoot: item.account.cliDataRoot,
                    createdAt: item.account.createdAt,
                    webKitStorage: .legacyDefault
                ), false)
            }
        }

        var sanitized = normalized.map { $0.account }
        let now = Date()
        for (offset, provider) in UsageProvider.allCases.enumerated()
            where !sanitized.contains(where: { $0.provider == provider }) {
            sanitized.append(ProviderAccount(
                provider: provider,
                label: provider.displayName,
                createdAt: now.addingTimeInterval(TimeInterval(offset) / 1_000),
                webKitStorage: .isolated
            ))
        }

        let sorted = sanitized.sorted {
            let leftProvider = providerOrder[$0.provider] ?? .max
            let rightProvider = providerOrder[$1.provider] ?? .max
            if leftProvider != rightProvider { return leftProvider < rightProvider }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        var providersWithLegacyStorage: Set<UsageProvider> = []
        return sorted.map { account in
            guard account.webKitStorage == .legacyDefault else { return account }
            guard providersWithLegacyStorage.insert(account.provider).inserted else {
                return ProviderAccount(
                    id: account.id,
                    provider: account.provider,
                    label: account.label,
                    isEnabled: account.isEnabled,
                    cliDataRoot: account.cliDataRoot,
                    createdAt: account.createdAt,
                    webKitStorage: .isolated
                )
            }
            return account
        }
    }

    private func recoverCorruptAccounts(
        pendingDeletionIDs: Set<UUID> = []
    ) -> [ProviderAccount] {
        // Existing but unreadable state must not be reconnected to shared
        // cookies under a newly generated identity.
        let accounts = makeDefaultAccounts(webKitStorage: .isolated)
        try? persist(accounts, pendingDeletionIDs: pendingDeletionIDs)
        return accounts
    }

    private func makeUnsupportedVersionAccounts() -> [ProviderAccount] {
        let createdAt = Date(timeIntervalSinceReferenceDate: 0)
        return UsageProvider.allCases.enumerated().map { offset, provider in
            ProviderAccount(
                id: unsupportedVersionIdentifier(for: provider),
                provider: provider,
                label: provider.displayName,
                createdAt: createdAt.addingTimeInterval(TimeInterval(offset)),
                webKitStorage: .isolated
            )
        }
    }

    private func unsupportedVersionIdentifier(for provider: UsageProvider) -> UUID {
        let value: String
        switch provider {
        case .chatgptCodex:
            value = "A6E17000-0001-4A11-8000-000000000001"
        case .claudeCode:
            value = "A6E17000-0002-4A11-8000-000000000002"
        case .githubCopilot:
            value = "A6E17000-0003-4A11-8000-000000000003"
        }
        guard let identifier = UUID(uuidString: value) else {
            preconditionFailure("Invalid static unsupported-version account identifier")
        }
        return identifier
    }

    private func requireSupportedMutationVersion() throws {
        if let version = unsupportedStoredVersion() {
            throw ProviderAccountStoreError.unsupportedVersion(version)
        }
    }

    private func unsupportedStoredVersion() -> Int? {
        guard let data = userDefaults.object(forKey: key) as? Data,
              let header = try? decoder.decode(VersionHeader.self, from: data),
              header.version > Self.currentVersion else {
            return nil
        }
        return header.version
    }

    private func storedPayload() -> Payload? {
        guard let data = userDefaults.object(forKey: key) as? Data else {
            return nil
        }
        return try? decoder.decode(Payload.self, from: data)
    }

    private func salvagePendingDeletionIDs(from data: Data) -> Set<UUID> {
        guard let salvage = try? decoder.decode(
            PendingDeletionSalvage.self,
            from: data
        ) else {
            return []
        }
        return sanitizePendingDeletionIDs(
            Set(salvage.pendingWebKitDataStoreDeletionIDs ?? []),
            activeAccountIDs: []
        )
    }

    private func sanitizePendingDeletionIDs(
        _ identifiers: Set<UUID>,
        activeAccountIDs: Set<UUID>
    ) -> Set<UUID> {
        identifiers.filter {
            ProviderAccount.isUsableWebKitIdentifier($0)
                && !activeAccountIDs.contains($0)
        }
    }

    private func selectedAccountKey(for provider: UsageProvider) -> String {
        "\(key).selected.\(provider.rawValue)"
    }

    @MainActor
    private func repairSelection(
        for provider: UsageProvider,
        among accounts: [ProviderAccount]
    ) -> ProviderAccount {
        let providerAccounts = accounts.filter { $0.provider == provider }
        let selectionKey = selectedAccountKey(for: provider)
        if let rawID = userDefaults.string(forKey: selectionKey),
           let selectedID = UUID(uuidString: rawID),
           let selected = providerAccounts.first(where: { $0.id == selectedID }) {
            return selected
        }
        guard let fallback = providerAccounts.first(where: \.isEnabled)
            ?? providerAccounts.first else {
            preconditionFailure("Removal must preserve one account per provider")
        }
        userDefaults.set(
            fallback.id.uuidString.lowercased(),
            forKey: selectionKey
        )
        return fallback
    }

    private func persist(
        _ accounts: [ProviderAccount],
        pendingDeletionIDs: Set<UUID>? = nil
    ) throws {
        let requestedPendingIDs = pendingDeletionIDs
            ?? Set(storedPayload()?.pendingWebKitDataStoreDeletionIDs ?? [])
        let pendingIDs = sanitizePendingDeletionIDs(
            requestedPendingIDs,
            activeAccountIDs: Set(accounts.map(\.id))
        )
        let payload = Payload(
            version: Self.currentVersion,
            accounts: accounts,
            pendingWebKitDataStoreDeletionIDs: pendingIDs
        )
        guard let data = try? encoder.encode(payload) else {
            throw ProviderAccountStoreError.persistenceFailed
        }
        userDefaults.set(data, forKey: key)
        // Account removal relies on this blob as its crash journal. Do not let
        // the caller release or delete WebKit credentials until cfprefsd has
        // acknowledged the complete registry+tombstone transaction.
        guard synchronizeDefaults(userDefaults),
              userDefaults.data(forKey: key) == data else {
            throw ProviderAccountStoreError.persistenceFailed
        }
    }
}
