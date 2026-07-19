import Foundation

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

    init(
        id: UUID = UUID(),
        provider: UsageProvider,
        label: String,
        isEnabled: Bool = true,
        cliDataRoot: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.label = Self.normalizeLabel(label, fallback: provider.displayName)
        self.isEnabled = isEnabled
        self.cliDataRoot = Self.normalizeOptionalPath(cliDataRoot)
        self.createdAt = createdAt
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
            createdAt: createdAt
        )
    }

    fileprivate static func primary(
        for provider: UsageProvider,
        createdAt: Date = Date()
    ) -> ProviderAccount {
        ProviderAccount(
            provider: provider,
            label: provider.displayName,
            createdAt: createdAt
        )
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
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "The provider account no longer exists."
        case .cannotRemoveLastAccount(let provider):
            return "Keep at least one \(provider.displayName) account. Disable it instead if needed."
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

    private static let currentVersion = 1
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
        guard let data = userDefaults.data(forKey: key),
              let payload = try? decoder.decode(Payload.self, from: data) else {
            let accounts = makeDefaultAccounts()
            try? persist(accounts)
            return accounts
        }

        let accounts = sanitize(payload.accounts)
        if accounts != payload.accounts {
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
        accounts(for: provider).first ?? ProviderAccount.primary(for: provider)
    }

    @discardableResult
    func addAccount(
        provider: UsageProvider,
        label: String,
        cliDataRoot: String? = nil
    ) throws -> ProviderAccount {
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
            createdAt: accounts[index].createdAt
        )
        try persist(sanitize(accounts))
    }

    func removeAccount(id: UUID) throws {
        var accounts = loadAccounts()
        guard let account = accounts.first(where: { $0.id == id }) else {
            throw ProviderAccountStoreError.accountNotFound
        }
        guard accounts.lazy.filter({ $0.provider == account.provider }).count > 1 else {
            throw ProviderAccountStoreError.cannotRemoveLastAccount(account.provider)
        }
        accounts.removeAll { $0.id == id }
        try persist(sanitize(accounts))
    }

    private func makeDefaultAccounts() -> [ProviderAccount] {
        let now = Date()
        return UsageProvider.allCases.enumerated().map { offset, provider in
            ProviderAccount.primary(
                for: provider,
                createdAt: now.addingTimeInterval(TimeInterval(offset) / 1_000)
            )
        }
    }

    private func sanitize(_ accounts: [ProviderAccount]) -> [ProviderAccount] {
        var seenIDs: Set<UUID> = []
        var sanitized: [ProviderAccount] = []
        for account in accounts where seenIDs.insert(account.id).inserted {
            sanitized.append(ProviderAccount(
                id: account.id,
                provider: account.provider,
                label: account.label,
                isEnabled: account.isEnabled,
                cliDataRoot: account.cliDataRoot,
                createdAt: account.createdAt
            ))
        }

        let now = Date()
        for (offset, provider) in UsageProvider.allCases.enumerated()
            where !sanitized.contains(where: { $0.provider == provider }) {
            sanitized.append(ProviderAccount.primary(
                for: provider,
                createdAt: now.addingTimeInterval(TimeInterval(offset) / 1_000)
            ))
        }

        let providerOrder = Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.enumerated().map { ($1, $0) }
        )
        return sanitized.sorted {
            let leftProvider = providerOrder[$0.provider] ?? .max
            let rightProvider = providerOrder[$1.provider] ?? .max
            if leftProvider != rightProvider { return leftProvider < rightProvider }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private func persist(_ accounts: [ProviderAccount]) throws {
        let payload = Payload(version: Self.currentVersion, accounts: accounts)
        guard let data = try? encoder.encode(payload) else {
            throw ProviderAccountStoreError.persistenceFailed
        }
        userDefaults.set(data, forKey: key)
    }
}
