import Foundation

/// Selects the persistent WebKit data store used by a provider account.
///
/// The original account for an existing install keeps the shared default store
/// so an upgrade does not sign the user out. Every subsequently created account
/// receives an identified store keyed by its immutable UUID.
enum ProviderAccountWebKitStorage: String, Codable, Equatable, Hashable {
    case legacyDefault
    case isolated
}

/// A separately tracked login/profile for one usage provider.
///
/// The stable UUID is also suitable for an isolated WebKit data store and an
/// account-scoped snapshot namespace. A nil CLI data root means the provider's
/// normal default profile directory.
struct ProviderAccount: Codable, Equatable, Hashable, Identifiable {
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

/// Persists the account registry independently from cookies and usage data.
/// Existing installs automatically receive one stable account per provider.
struct ProviderAccountStore {
    static let shared = ProviderAccountStore()

    private struct Payload: Codable {
        let version: Int
        let accounts: [ProviderAccount]
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    private static let currentVersion = 2
    private static let webKitStorageVersion = 2
    private let userDefaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        userDefaults: UserDefaults? = nil,
        key: String = "provider_accounts_v1"
    ) {
        self.userDefaults = userDefaults ?? AppGroupDefaults.shared ?? .standard
        self.key = key
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
            return recoverCorruptAccounts()
        }

        let accounts = sanitize(
            payload.accounts,
            migratesLegacyWebKitStorage: payload.version < Self.webKitStorageVersion
        )
        // Do not rewrite data produced by a newer app version: it may contain
        // fields this version cannot preserve.
        if payload.version <= Self.currentVersion,
           payload.version != Self.currentVersion
            || accounts != payload.accounts
            || payload.accounts.contains(where: \.needsWebKitStorageRepair) {
            try? persist(accounts)
        }
        return accounts
    }

    func accounts(for provider: UsageProvider) -> [ProviderAccount] {
        loadAccounts().filter { $0.provider == provider }
    }

    func account(id: UUID) -> ProviderAccount? {
        loadAccounts().first { $0.id == id }
    }

    func primaryAccount(for provider: UsageProvider) -> ProviderAccount {
        selectedAccount(for: provider)
    }

    /// Returns the persisted account selection for one provider. Invalid,
    /// missing, and cross-provider selections repair to a deterministic local
    /// account without displacing a valid disabled selection.
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

    @discardableResult
    func addAccount(
        provider: UsageProvider,
        label: String,
        cliDataRoot: String? = nil
    ) throws -> ProviderAccount {
        try requireSupportedMutationVersion()
        var accounts = loadAccounts()
        let account = ProviderAccount(
            provider: provider,
            label: label,
            cliDataRoot: cliDataRoot
        )
        accounts.append(account)
        try persist(sanitize(accounts))
        return account
    }

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

    func removeAccount(id: UUID) throws {
        try requireSupportedMutationVersion()
        var accounts = loadAccounts()
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw ProviderAccountStoreError.accountNotFound
        }
        guard accounts.lazy.filter({ $0.provider == account.provider }).count > 1 else {
            throw ProviderAccountStoreError.cannotRemoveLastAccount(account.provider)
        }
        let selectionKey = selectedAccountKey(for: account.provider)
        let removedWasSelected = userDefaults.string(forKey: selectionKey)
            .flatMap(UUID.init(uuidString:)) == id
        accounts.removeAll { $0.id == id }
        let sanitized = sanitize(accounts)
        try persist(sanitized)

        if removedWasSelected {
            let replacement = sanitized.first {
                $0.provider == account.provider && $0.isEnabled
            } ?? sanitized.first { $0.provider == account.provider }
            if let replacement {
                userDefaults.set(
                    replacement.id.uuidString.lowercased(),
                    forKey: selectionKey
                )
            }
        }
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

    private func recoverCorruptAccounts() -> [ProviderAccount] {
        // Existing but unreadable state must not be reconnected to shared
        // cookies under a newly generated identity.
        let accounts = makeDefaultAccounts(webKitStorage: .isolated)
        try? persist(accounts)
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

    private func selectedAccountKey(for provider: UsageProvider) -> String {
        "\(key).selected.\(provider.rawValue)"
    }

    private func persist(_ accounts: [ProviderAccount]) throws {
        let payload = Payload(version: Self.currentVersion, accounts: accounts)
        guard let data = try? encoder.encode(payload) else {
            throw ProviderAccountStoreError.persistenceFailed
        }
        userDefaults.set(data, forKey: key)
    }
}
