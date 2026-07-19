// MARK: - UsageWebViewPool.swift
// Manages a pool of WebViewStore instances for each provider.
// Handles data clearing and WebView lifecycle management.

import Combine
import WebKit

@MainActor
protocol WebsiteDataClearing {
    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws
}

/// Production WebKit data remover. Explicit cookie deletion is awaited after
/// the broad website-data removal callback completes.
@MainActor
final class DefaultWebsiteDataClearer: WebsiteDataClearing {
    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) {
                continuation.resume()
            }
        }

        let cookies = await dataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }
}

// MARK: - Activation Policy

/// Tracks background login-history needs separately from the provider that is
/// currently needed by the settings UI.
struct UsageWebViewActivationPolicy {
    private(set) var backgroundAccountIDByProvider: [UsageProvider: UUID] = [:]
    private(set) var foregroundAccountID: UUID?
    private(set) var foregroundProvider: UsageProvider?

    var activeAccountIDs: Set<UUID> {
        var accountIDs = Set(backgroundAccountIDByProvider.values)
        if let foregroundProvider,
           let backgroundAccountID = backgroundAccountIDByProvider[foregroundProvider] {
            accountIDs.remove(backgroundAccountID)
        }
        if let foregroundAccountID {
            accountIDs.insert(foregroundAccountID)
        }
        return accountIDs
    }

    mutating func setBackgroundAccounts(_ accounts: [UsageProvider: UUID]) {
        backgroundAccountIDByProvider = accounts
    }

    mutating func setForegroundAccountID(
        _ accountID: UUID,
        for provider: UsageProvider
    ) {
        if backgroundAccountIDByProvider[provider] != nil {
            backgroundAccountIDByProvider[provider] = accountID
        }
        foregroundAccountID = accountID
        foregroundProvider = provider
    }

    mutating func clearForegroundAccount() {
        foregroundAccountID = nil
        foregroundProvider = nil
    }
}

// MARK: - WebView Pool

/// Manages WebViewStore instances for each provider.
/// Provides shared access and handles data clearing.
@MainActor
final class UsageWebViewPool: ObservableObject {
    struct DataClearToken: Equatable {
        fileprivate let identifier: UInt64
    }

    enum DataClearError: LocalizedError {
        case invalidToken
        case clearAlreadyInProgress
        case webViewsDidNotQuiesce

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                return "The website-data clear is no longer active."
            case .clearAlreadyInProgress:
                return "The website-data clear is already running."
            case .webViewsDidNotQuiesce:
                return "Login pages could not be stopped safely before clearing data."
            }
        }
    }

    private enum WebsiteDataStoreKey: Hashable {
        case legacyDefault
        case isolated(UUID)

        var sortKey: String {
            switch self {
            case .legacyDefault:
                return "0-default"
            case .isolated(let identifier):
                return "1-\(identifier.uuidString)"
            }
        }
    }

    private struct DataClearCoverage {
        let accountIDs: Set<UUID>
        let dataStoreKeys: Set<WebsiteDataStoreKey>
    }

    private enum DataClearPhase {
        case ready
        case clearing
        case succeeded(DataClearCoverage)
        case failed
        case coverageInvalidated
    }

    private var webViewStoreByAccountID: [UUID: WebViewStore] = [:]
    private var dataStoreByKey: [WebsiteDataStoreKey: WKWebsiteDataStore] = [:]
    private var managedProviders: Set<UsageProvider>
    private var activationPolicy = UsageWebViewActivationPolicy()
    private var activeDataClear: DataClearToken?
    private var activeDataClearPhase: DataClearPhase?
    private var nextDataClearIdentifier: UInt64 = 0
    private let accountStore: ProviderAccountStore
    private let websiteDataClearer: any WebsiteDataClearing
    private let websiteDataStoreProvider: (ProviderAccount) -> WKWebsiteDataStore
    private let quiescenceTimeout: Duration

    /// Called after a newly registered account WebViewStore is ready to observe.
    var onWebViewStoreCreated: ((WebViewStore) -> Void)?

    var webViewStores: [WebViewStore] {
        webViewStoreByAccountID.values.sorted {
            if $0.account.provider != $1.account.provider {
                return $0.account.provider.rawValue < $1.account.provider.rawValue
            }
            if $0.account.createdAt != $1.account.createdAt {
                return $0.account.createdAt < $1.account.createdAt
            }
            return $0.account.id.uuidString < $1.account.id.uuidString
        }
    }

    init(
        providers: [UsageProvider] = UsageProvider.allCases,
        accountStore: ProviderAccountStore,
        websiteDataClearer: (any WebsiteDataClearing)? = nil,
        websiteDataStoreProvider: ((ProviderAccount) -> WKWebsiteDataStore)? = nil,
        quiescenceTimeout: Duration = .seconds(5)
    ) {
        self.managedProviders = Set(providers)
        self.accountStore = accountStore
        self.websiteDataClearer = websiteDataClearer ?? DefaultWebsiteDataClearer()
        if accountStore.supportsPersistentWebSessions {
            self.websiteDataStoreProvider = websiteDataStoreProvider
                ?? Self.makeDefaultWebsiteDataStore(for:)
        } else {
            // Future-schema placeholder IDs are deliberately not durable.
            // Persisting cookies under them could make credentials unreachable
            // when a compatible app restores the real registry identities.
            self.websiteDataStoreProvider = { _ in .nonPersistent() }
        }
        self.quiescenceTimeout = quiescenceTimeout
        registerCurrentAccounts()
    }

    /// Temporary provider-facing facade. Runtime callers receive the exact
    /// account selected for that provider at the time of lookup.
    func getWebViewStore(for provider: UsageProvider) -> WebViewStore {
        getWebViewStore(for: accountStore.selectedAccount(for: provider))
    }

    /// Returns one stable WebViewStore per immutable account UUID.
    func getWebViewStore(for account: ProviderAccount) -> WebViewStore {
        managedProviders.insert(account.provider)
        if let existingStore = webViewStoreByAccountID[account.id] {
            return existingStore
        }
        let newStore = WebViewStore(
            account: account,
            websiteDataStore: websiteDataStore(for: account),
            loadImmediately: false
        )
        configureNavigationGuard(for: newStore)
        webViewStoreByAccountID[account.id] = newStore
        if activeDataClear != nil {
            newStore.beginDataClear()
            if case .succeeded? = activeDataClearPhase {
                activeDataClearPhase = .coverageInvalidated
            }
        }
        onWebViewStoreCreated?(newStore)
        return newStore
    }

    func isSelectedAccount(_ accountID: UUID, for provider: UsageProvider) -> Bool {
        accountStore.selectedAccount(for: provider).id == accountID
    }

    /// Makes the selected account for one provider active for the settings UI.
    /// During a clear this only updates the policy; no navigation occurs.
    func resume(_ provider: UsageProvider) {
        resume(accountStore.selectedAccount(for: provider))
    }

    func resume(_ account: ProviderAccount) {
        _ = getWebViewStore(for: account)
        activationPolicy.setForegroundAccountID(
            account.id,
            for: account.provider
        )
        reconcileActiveStores()
    }

    /// Releases the settings UI provider while retaining background providers.
    func clearForegroundProvider() {
        activationPolicy.clearForegroundAccount()
        reconcileActiveStores()
    }

    /// Updates providers that should remain active due to login history.
    /// During a clear this only records the latest policy.
    func applyBackgroundPolicy(activeProviders: Set<UsageProvider>) {
        let accounts = activeProviders.map { accountStore.selectedAccount(for: $0) }
        applyBackgroundPolicy(activeAccounts: accounts)
    }

    func applyBackgroundPolicy(activeAccounts: [ProviderAccount]) {
        var accountIDByProvider: [UsageProvider: UUID] = [:]
        for account in activeAccounts {
            _ = getWebViewStore(for: account)
            accountIDByProvider[account.provider] = account.id
        }
        activationPolicy.setBackgroundAccounts(accountIDByProvider)
        reconcileActiveStores()
    }

    /// Reloads a desired provider from its canonical origin when navigation is allowed.
    func reloadFromOrigin(_ provider: UsageProvider) {
        reloadFromOrigin(accountStore.selectedAccount(for: provider))
    }

    func reloadFromOrigin(_ account: ProviderAccount) {
        guard activeDataClear == nil else { return }
        guard activationPolicy.activeAccountIDs.contains(account.id) else { return }
        getWebViewStore(for: account).reloadFromOrigin()
    }

    /// Starts an exclusive website-data clear and immediately blocks every
    /// provider navigation and popup.
    func beginDataClear() -> DataClearToken? {
        guard activeDataClear == nil else { return nil }
        nextDataClearIdentifier &+= 1
        let token = DataClearToken(identifier: nextDataClearIdentifier)
        activeDataClear = token
        activeDataClearPhase = .ready
        registerCurrentAccounts()
        for store in webViewStoreByAccountID.values {
            store.beginDataClear()
        }
        return token
    }

    /// Quiesces every main page and popup before deleting shared WebKit data.
    /// Call only between beginDataClear and finishDataClear.
    func clearWebsiteData(_ token: DataClearToken) async throws {
        guard activeDataClear == token else { throw DataClearError.invalidToken }
        guard let phase = activeDataClearPhase else {
            throw DataClearError.invalidToken
        }
        if case .clearing = phase {
            throw DataClearError.clearAlreadyInProgress
        }
        activeDataClearPhase = .clearing

        var quiescedAccountIDs: Set<UUID> = []
        var clearedDataStores: Set<WebsiteDataStoreKey> = []

        do {
            while true {
                registerCurrentAccounts()

                if let store = webViewStoreByAccountID.values
                    .filter({ !quiescedAccountIDs.contains($0.account.id) })
                    .sorted(by: { $0.account.id.uuidString < $1.account.id.uuidString })
                    .first {
                    let didQuiesce = await store.quiesceForDataClear(
                        timeout: quiescenceTimeout
                    )
                    guard didQuiesce else {
                        throw DataClearError.webViewsDidNotQuiesce
                    }
                    quiescedAccountIDs.insert(store.account.id)
                    guard activeDataClear == token else {
                        throw DataClearError.invalidToken
                    }
                    continue
                }

                let nextDataStoreKey = dataStoreByKey.keys
                    .filter { !clearedDataStores.contains($0) }
                    .sorted { $0.sortKey < $1.sortKey }
                    .first
                guard let nextDataStoreKey,
                      let dataStore = dataStoreByKey[nextDataStoreKey] else {
                    activeDataClearPhase = .succeeded(DataClearCoverage(
                        accountIDs: Set(webViewStoreByAccountID.keys),
                        dataStoreKeys: Set(dataStoreByKey.keys)
                    ))
                    return
                }

                try await websiteDataClearer.clearAllWebsiteData(in: dataStore)
                clearedDataStores.insert(nextDataStoreKey)
                guard activeDataClear == token else { throw DataClearError.invalidToken }
            }
        } catch {
            if activeDataClear == token {
                activeDataClearPhase = .failed
            }
            throw error
        }
    }

    /// Ends a clear and restores the most recent activation policy. Policy
    /// changes received while clearing therefore win over the pre-clear state.
    @discardableResult
    func finishDataClear(_ token: DataClearToken) -> Bool {
        guard isWebsiteDataClearComplete(token) else { return false }
        return endDataClear(token)
    }

    /// Synchronously verifies that the successful clear covered every account
    /// and data store currently registered. Call again after any awaited work.
    func isWebsiteDataClearComplete(_ token: DataClearToken) -> Bool {
        guard activeDataClear == token else { return false }
        registerCurrentAccounts()
        guard case .succeeded(let coverage)? = activeDataClearPhase else {
            return false
        }
        guard Set(webViewStoreByAccountID.keys).isSubset(of: coverage.accountIDs),
              Set(dataStoreByKey.keys).isSubset(of: coverage.dataStoreKeys) else {
            activeDataClearPhase = .coverageInvalidated
            return false
        }
        return true
    }

    /// Releases a failed or abandoned clear without claiming complete website-
    /// data coverage. A running clearer cannot be cancelled mid-removal.
    @discardableResult
    func cancelDataClear(_ token: DataClearToken) -> Bool {
        guard activeDataClear == token else { return false }
        if case .clearing? = activeDataClearPhase { return false }
        return endDataClear(token)
    }

    private func configureNavigationGuard(for store: WebViewStore) {
        store.isNavigationAllowed = { [weak self] in
            guard let self else { return false }
            return self.activeDataClear == nil
        }
    }

    private func endDataClear(_ token: DataClearToken) -> Bool {
        guard activeDataClear == token else { return false }
        for store in webViewStoreByAccountID.values {
            store.finishDataClear()
        }
        activeDataClear = nil
        activeDataClearPhase = nil
        reconcileActiveStores()
        return true
    }

    private func reconcileActiveStores() {
        guard activeDataClear == nil else { return }
        let desiredAccountIDs = activationPolicy.activeAccountIDs
        for (accountID, store) in webViewStoreByAccountID {
            if desiredAccountIDs.contains(accountID) {
                store.resume()
            } else {
                store.suspend()
            }
        }
    }

    private func registerCurrentAccounts() {
        for account in accountStore.loadAccounts()
            where managedProviders.contains(account.provider) {
            _ = getWebViewStore(for: account)
        }
    }

    private func websiteDataStore(for account: ProviderAccount) -> WKWebsiteDataStore {
        let key = websiteDataStoreKey(for: account)
        if let existing = dataStoreByKey[key] {
            return existing
        }
        let dataStore = websiteDataStoreProvider(account)
        dataStoreByKey[key] = dataStore
        return dataStore
    }

    private func websiteDataStoreKey(
        for account: ProviderAccount
    ) -> WebsiteDataStoreKey {
        switch account.webKitStorage {
        case .legacyDefault:
            return .legacyDefault
        case .isolated:
            guard let identifier = account.isolatedWebKitDataStoreIdentifier else {
                preconditionFailure("Invalid isolated WebKit account identifier")
            }
            return .isolated(identifier)
        }
    }

    private static func makeDefaultWebsiteDataStore(
        for account: ProviderAccount
    ) -> WKWebsiteDataStore {
        switch account.webKitStorage {
        case .legacyDefault:
            return .default()
        case .isolated:
            guard let identifier = account.isolatedWebKitDataStoreIdentifier else {
                preconditionFailure("Invalid isolated WebKit account identifier")
            }
            return WKWebsiteDataStore(forIdentifier: identifier)
        }
    }
}
