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
    private(set) var backgroundAccountIDs: Set<UUID> = []
    private(set) var foregroundAccountID: UUID?
    private(set) var foregroundProvider: UsageProvider?

    var activeAccountIDs: Set<UUID> {
        var accountIDs = backgroundAccountIDs
        if let foregroundAccountID {
            accountIDs.insert(foregroundAccountID)
        }
        return accountIDs
    }

    mutating func setBackgroundAccounts(_ accountIDs: Set<UUID>) {
        backgroundAccountIDs = accountIDs
    }

    mutating func setForegroundAccountID(
        _ accountID: UUID,
        for provider: UsageProvider
    ) {
        foregroundAccountID = accountID
        foregroundProvider = provider
    }

    mutating func clearForegroundAccount() {
        foregroundAccountID = nil
        foregroundProvider = nil
    }

    @discardableResult
    mutating func replaceAccountID(
        _ removedAccountID: UUID,
        with replacementAccountID: UUID,
        for provider: UsageProvider
    ) -> Bool {
        var didReplace = false
        if backgroundAccountIDs.remove(removedAccountID) != nil {
            backgroundAccountIDs.insert(replacementAccountID)
            didReplace = true
        }
        if foregroundProvider == provider,
           foregroundAccountID == removedAccountID {
            foregroundAccountID = replacementAccountID
            didReplace = true
        }
        return didReplace
    }
}

// MARK: - WebView Pool

enum UsageWebViewNavigationPolicy {
    case enabled
    case disabled

    var allowsProviderNavigation: Bool {
        self == .enabled
    }
}

/// Manages WebViewStore instances for each provider.
/// Provides shared access and handles data clearing.
@MainActor
final class UsageWebViewPool: ObservableObject {
    struct DataClearToken: Equatable {
        fileprivate let identifier: UInt64
    }

    struct AccountRetirementToken: Equatable {
        fileprivate let identifier: UInt64
        let accountID: UUID
    }

    enum AccountRetirementError: LocalizedError {
        case globalClearInProgress
        case anotherRetirementInProgress
        case accountUnavailable
        case webViewDidNotQuiesce
        case invalidToken

        var errorDescription: String? {
            switch self {
            case .globalClearInProgress:
                return "Finish clearing website data before removing an account."
            case .anotherRetirementInProgress:
                return "Another provider account is already being removed."
            case .accountUnavailable:
                return "The provider account session is no longer available."
            case .webViewDidNotQuiesce:
                return "The provider account login page could not be stopped safely."
            case .invalidToken:
                return "The provider account removal is no longer active."
            }
        }
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

    private struct ActiveAccountRetirement {
        let token: AccountRetirementToken
        let plan: ProviderAccountRemovalPlan
        let webViewStore: WebViewStore
        let replacedActiveAccount: Bool
        let legacySharedWebViewStores: [WebViewStore]
        var isWebsiteDataRemovalInProgress: Bool
    }

    private var webViewStoreByAccountID: [UUID: WebViewStore] = [:]
    private var dataStoreByKey: [WebsiteDataStoreKey: WKWebsiteDataStore] = [:]
    private var managedProviders: Set<UsageProvider>
    private var activationPolicy = UsageWebViewActivationPolicy()
    private var activeDataClear: DataClearToken?
    private var activeDataClearPhase: DataClearPhase?
    private var nextDataClearIdentifier: UInt64 = 0
    private var activeAccountRetirement: ActiveAccountRetirement?
    private var isPreparingAccountRetirement = false
    private var nextAccountRetirementIdentifier: UInt64 = 0
    private var retiringOrRemovedAccountIDs: Set<UUID>
    let accountStore: ProviderAccountStore
    private let websiteDataClearer: any WebsiteDataClearing
    private let websiteDataStoreProvider: (ProviderAccount) -> WKWebsiteDataStore
    private let quiescenceTimeout: Duration
    private let navigationPolicy: UsageWebViewNavigationPolicy

    /// Called after a newly registered account WebViewStore is ready to observe.
    var onWebViewStoreCreated: ((WebViewStore) -> Void)?
    /// Invalidates account-bound async work before local data can be deleted.
    let webViewStoreRetirementDidBegin = PassthroughSubject<UUID, Never>()
    /// Restores any account that survives a retirement invalidation interval.
    let webViewStoreRetirementDidRestore = PassthroughSubject<UUID, Never>()
    /// Synchronous release boundary for observers and visible popup/page views.
    let webViewStoreWillRetire = PassthroughSubject<UUID, Never>()

    var webViewStores: [WebViewStore] {
        webViewStoreByAccountID.values
            .filter { !retiringOrRemovedAccountIDs.contains($0.account.id) }
            .sorted {
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
        quiescenceTimeout: Duration = .seconds(5),
        navigationPolicy: UsageWebViewNavigationPolicy = .enabled
    ) {
        self.managedProviders = Set(providers)
        self.accountStore = accountStore
        self.retiringOrRemovedAccountIDs =
            accountStore.pendingWebKitDataStoreDeletionIDs
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
        self.navigationPolicy = navigationPolicy
        registerCurrentAccounts()
    }

    /// Temporary provider-facing facade. Runtime callers receive the exact
    /// account selected for that provider at the time of lookup.
    func getWebViewStore(for provider: UsageProvider) -> WebViewStore {
        getWebViewStore(for: accountStore.selectedAccount(for: provider))
    }

    /// Returns one stable WebViewStore per immutable account UUID.
    func getWebViewStore(for account: ProviderAccount) -> WebViewStore {
        precondition(
            !retiringOrRemovedAccountIDs.contains(account.id),
            "Retired provider account sessions cannot be recreated"
        )
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
        guard !retiringOrRemovedAccountIDs.contains(accountID) else { return false }
        return accountStore.selectedAccount(for: provider).id == accountID
    }

    /// Confirms that a callback still belongs to this pool's live store and
    /// immutable registry identity. Selection is intentionally irrelevant.
    func isAvailable(_ store: WebViewStore) -> Bool {
        let account = store.account
        guard !retiringOrRemovedAccountIDs.contains(account.id),
              webViewStoreByAccountID[account.id] === store,
              let registered = accountStore.account(id: account.id) else {
            return false
        }
        return registered.provider == account.provider
    }

    func isActive(_ store: WebViewStore) -> Bool {
        isAvailable(store)
            && activationPolicy.activeAccountIDs.contains(store.account.id)
    }

    /// Makes the selected account for one provider active for the settings UI.
    /// During a clear this only updates the policy; no navigation occurs.
    func resume(_ provider: UsageProvider) {
        resume(accountStore.selectedAccount(for: provider))
    }

    func resume(_ account: ProviderAccount) {
        guard !retiringOrRemovedAccountIDs.contains(account.id) else { return }
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

    /// Keeps each selected account for provider-level login history active.
    /// During a clear this only records the latest policy.
    func applyBackgroundPolicy(activeProviders: Set<UsageProvider>) {
        let accounts = activeProviders.map { accountStore.selectedAccount(for: $0) }
        applyBackgroundPolicy(activeAccounts: accounts)
    }

    /// Keeps every supplied account active, including multiple accounts owned
    /// by the same provider.
    func applyBackgroundPolicy(activeAccounts: [ProviderAccount]) {
        var accountIDs: Set<UUID> = []
        for account in activeAccounts
            where !retiringOrRemovedAccountIDs.contains(account.id) {
            _ = getWebViewStore(for: account)
            accountIDs.insert(account.id)
        }
        activationPolicy.setBackgroundAccounts(accountIDs)
        reconcileActiveStores()
    }

    /// Reloads a desired provider from its canonical origin when navigation is allowed.
    func reloadFromOrigin(_ provider: UsageProvider) {
        reloadFromOrigin(accountStore.selectedAccount(for: provider))
    }

    func reloadFromOrigin(_ account: ProviderAccount) {
        guard activeDataClear == nil else { return }
        guard !retiringOrRemovedAccountIDs.contains(account.id) else { return }
        guard activationPolicy.activeAccountIDs.contains(account.id) else { return }
        getWebViewStore(for: account).reloadFromOrigin()
    }

    /// Blocks a target account immediately and captures its exact WebView
    /// session. Registry selection must already point at the replacement.
    func beginAccountRetirement(
        _ plan: ProviderAccountRemovalPlan
    ) throws -> AccountRetirementToken {
        guard activeDataClear == nil else {
            throw AccountRetirementError.globalClearInProgress
        }
        guard activeAccountRetirement == nil else {
            throw AccountRetirementError.anotherRetirementInProgress
        }
        guard !isPreparingAccountRetirement else {
            throw AccountRetirementError.anotherRetirementInProgress
        }
        guard !retiringOrRemovedAccountIDs.contains(plan.target.id),
              accountStore.account(id: plan.target.id) != nil else {
            throw AccountRetirementError.accountUnavailable
        }
        isPreparingAccountRetirement = true
        defer { isPreparingAccountRetirement = false }

        let store = getWebViewStore(for: plan.target)
        let legacySharedStores: [WebViewStore]
        switch plan.target.webKitStorage {
        case .isolated:
            guard store.beginRetirement() else {
                throw AccountRetirementError.accountUnavailable
            }
            legacySharedStores = []
        case .legacyDefault:
            // Every legacy account shares one default data store even when
            // this pool was initially configured for a provider subset.
            registerAllLegacyAccounts()
            legacySharedStores = webViewStoreByAccountID.values
                .filter { $0.account.webKitStorage == .legacyDefault }
                .sorted { $0.account.id.uuidString < $1.account.id.uuidString }
            guard legacySharedStores.contains(where: { $0 === store }),
                  legacySharedStores.allSatisfy({
                    !$0.isDataClearInProgress
                        && !$0.isRetirementInProgress
                        && !$0.isRetired
                  }) else {
                throw AccountRetirementError.accountUnavailable
            }
            for sharedStore in legacySharedStores {
                sharedStore.beginDataClear()
            }
        }

        nextAccountRetirementIdentifier &+= 1
        let token = AccountRetirementToken(
            identifier: nextAccountRetirementIdentifier,
            accountID: plan.target.id
        )
        retiringOrRemovedAccountIDs.insert(plan.target.id)
        let replacedActiveAccount = activationPolicy.replaceAccountID(
            plan.target.id,
            with: plan.replacement.id,
            for: plan.target.provider
        )
        activeAccountRetirement = ActiveAccountRetirement(
            token: token,
            plan: plan,
            webViewStore: store,
            replacedActiveAccount: replacedActiveAccount,
            legacySharedWebViewStores: legacySharedStores,
            isWebsiteDataRemovalInProgress: false
        )
        // Reserve exclusivity before synchronous Combine delivery. A subscriber
        // must not be able to start a global clear reentrantly.
        let invalidatedAccountIDs = legacySharedStores.isEmpty
            ? [plan.target.id]
            : legacySharedStores.map { $0.account.id }
        for accountID in invalidatedAccountIDs {
            webViewStoreRetirementDidBegin.send(accountID)
        }
        objectWillChange.send()
        reconcileActiveStores()
        return token
    }

    /// Quiesces the exact identified session, or every session when deleting a
    /// legacy account that shares WKWebsiteDataStore.default().
    func quiesceAccountForRetirement(
        _ token: AccountRetirementToken
    ) async throws {
        guard let retirement = activeAccountRetirement,
              retirement.token == token else {
            throw AccountRetirementError.invalidToken
        }

        switch retirement.plan.target.webKitStorage {
        case .isolated:
            let didQuiesce = await retirement.webViewStore.quiesceForDataClear(
                timeout: quiescenceTimeout
            )
            guard activeAccountRetirement?.token == token else {
                throw AccountRetirementError.invalidToken
            }
            guard didQuiesce else {
                throw AccountRetirementError.webViewDidNotQuiesce
            }

        case .legacyDefault:
            for sharedStore in retirement.legacySharedWebViewStores {
                let didQuiesce = await sharedStore.quiesceForDataClear(
                    timeout: quiescenceTimeout
                )
                guard activeAccountRetirement?.token == token else {
                    throw AccountRetirementError.invalidToken
                }
                guard didQuiesce else {
                    throw AccountRetirementError.webViewDidNotQuiesce
                }
            }
            guard hasCompleteLegacyCoverage(retirement) else {
                throw AccountRetirementError.accountUnavailable
            }
            var clearingRetirement = retirement
            clearingRetirement.isWebsiteDataRemovalInProgress = true
            activeAccountRetirement = clearingRetirement
            do {
                try await websiteDataClearer.clearAllWebsiteData(
                    in: retirement.webViewStore.websiteDataStore
                )
            } catch {
                if var current = activeAccountRetirement,
                   current.token == token {
                    current.isWebsiteDataRemovalInProgress = false
                    activeAccountRetirement = current
                }
                throw error
            }
            guard var current = activeAccountRetirement,
                  current.token == token else {
                throw AccountRetirementError.invalidToken
            }
            current.isWebsiteDataRemovalInProgress = false
            activeAccountRetirement = current
            guard hasCompleteLegacyCoverage(current),
                  current.webViewStore.beginRetirementDuringDataClear() else {
                throw AccountRetirementError.accountUnavailable
            }
        }
    }

    /// Drops every live reference owned by the pool after registry commit.
    /// The account ID remains blocked for this process, including while a
    /// durable identified-store cleanup tombstone is pending.
    func finalizeAccountRetirement(
        _ token: AccountRetirementToken,
        commit: ProviderAccountRemovalCommit
    ) throws {
        guard let retirement = activeAccountRetirement,
              retirement.token == token,
              !retirement.isWebsiteDataRemovalInProgress,
              retirement.plan.target.id == commit.removed.id else {
            throw AccountRetirementError.invalidToken
        }

        let accountID = commit.removed.id
        let survivingInvalidatedAccountIDs = retirement
            .legacySharedWebViewStores
            .map { $0.account.id }
            .filter { $0 != accountID }
        webViewStoreWillRetire.send(accountID)
        objectWillChange.send()
        retirement.webViewStore.finalizeRetirement()
        for sharedStore in retirement.legacySharedWebViewStores
            where sharedStore !== retirement.webViewStore {
            sharedStore.finishDataClear()
        }
        webViewStoreByAccountID.removeValue(forKey: accountID)
        if let identifier = commit.removed.isolatedWebKitDataStoreIdentifier {
            dataStoreByKey.removeValue(forKey: .isolated(identifier))
        }

        if retirement.replacedActiveAccount,
           retirement.plan.replacement.id != commit.replacement.id {
            activationPolicy.replaceAccountID(
                retirement.plan.replacement.id,
                with: commit.replacement.id,
                for: commit.removed.provider
            )
        }

        activeAccountRetirement = nil
        reconcileActiveStores()
        for survivingAccountID in survivingInvalidatedAccountIDs {
            webViewStoreRetirementDidRestore.send(survivingAccountID)
        }
    }

    /// Cancels only pre-commit retirement. Once registry commit succeeds, the
    /// durable cleanup tombstone owns completion and this must not be called.
    @discardableResult
    func cancelAccountRetirement(_ token: AccountRetirementToken) -> Bool {
        guard let retirement = activeAccountRetirement,
              retirement.token == token,
              !retirement.isWebsiteDataRemovalInProgress else { return false }
        let invalidatedAccountIDs = retirement.legacySharedWebViewStores.isEmpty
            ? [retirement.plan.target.id]
            : retirement.legacySharedWebViewStores.map { $0.account.id }
        if retirement.webViewStore.isRetirementInProgress {
            retirement.webViewStore.cancelRetirement()
        } else {
            retirement.webViewStore.finishDataClear()
        }
        for sharedStore in retirement.legacySharedWebViewStores
            where sharedStore !== retirement.webViewStore {
            sharedStore.finishDataClear()
        }
        activeAccountRetirement = nil
        retiringOrRemovedAccountIDs.remove(token.accountID)
        objectWillChange.send()
        reconcileActiveStores()
        for accountID in invalidatedAccountIDs {
            webViewStoreRetirementDidRestore.send(accountID)
        }
        return true
    }

    /// Starts an exclusive website-data clear and immediately blocks every
    /// provider navigation and popup.
    func beginDataClear() -> DataClearToken? {
        guard activeDataClear == nil,
              activeAccountRetirement == nil,
              !isPreparingAccountRetirement else { return nil }
        return startDataClear()
    }

    private func startDataClear() -> DataClearToken {
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
        let accountID = store.account.id
        store.isNavigationAllowed = { [weak self] in
            guard let self else { return false }
            return self.navigationPolicy.allowsProviderNavigation
                && self.activeDataClear == nil
                && !self.retiringOrRemovedAccountIDs.contains(accountID)
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
            where managedProviders.contains(account.provider)
                && !retiringOrRemovedAccountIDs.contains(account.id) {
            _ = getWebViewStore(for: account)
        }
    }

    private func registerAllLegacyAccounts() {
        for account in accountStore.loadAccounts()
            where account.webKitStorage == .legacyDefault
                && !retiringOrRemovedAccountIDs.contains(account.id) {
            _ = getWebViewStore(for: account)
        }
    }

    private func hasCompleteLegacyCoverage(
        _ retirement: ActiveAccountRetirement
    ) -> Bool {
        let coveredAccountIDs = Set(
            retirement.legacySharedWebViewStores.map { $0.account.id }
        )
        let currentLegacyAccountIDs = Set(
            accountStore.loadAccounts()
                .filter { $0.webKitStorage == .legacyDefault }
                .map(\.id)
        )
        return currentLegacyAccountIDs.isSubset(of: coveredAccountIDs)
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
