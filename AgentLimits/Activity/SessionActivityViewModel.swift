import Combine
import Foundation

enum SessionActivityRefreshReason: Equatable {
    case manual
    case background
}

enum SessionActivityViewModelError: LocalizedError, Equatable {
    case unsupportedCredentialProvider
    case accountNotFound
    case dataClearInProgress

    var errorDescription: String? {
        switch self {
        case .unsupportedCredentialProvider:
            return "activity.errorUnsupportedProvider".localized()
        case .accountNotFound:
            return "activity.errorAccountNotFound".localized()
        case .dataClearInProgress:
            return "activity.errorClearInProgress".localized()
        }
    }
}

struct SessionActivityDataClearToken: Equatable {
    fileprivate let id: UUID
}

@MainActor
protocol SessionActivityDataClearing: AnyObject {
    func beginActivityDataClear() -> SessionActivityDataClearToken?
    func clearAllActivityData(
        during token: SessionActivityDataClearToken
    ) throws
    @discardableResult
    func finishActivityDataClear(
        _ token: SessionActivityDataClearToken
    ) -> Bool
}

private typealias SessionActivityOperationGate = UsageOperationGate<UUID>

private enum SessionActivityFreshnessConfig {
    static var currentInterval: TimeInterval {
        max(60, UsageRefreshConfig.refreshIntervalSeconds * 2)
    }

    static let maximumBackgroundConcurrency = 4
    static let maximumRateLimitBackoff: TimeInterval = 15 * 60
}

/// Owns account-scoped current-activity state. Provider-specific fetchers never
/// choose account identity; callers supply an exact immutable account UUID.
@MainActor
final class SessionActivityViewModel: ObservableObject {
    private struct RunningRefresh {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct ActiveDataClear {
        let token: SessionActivityDataClearToken
        let operationToken: SessionActivityOperationGate.ClearToken
    }

    @Published private var storedSnapshotsByAccountID:
        [UUID: SessionActivitySnapshot] = [:]
    @Published private(set) var isFetchingByAccountID: [UUID: Bool] = [:]

    var snapshotsByAccountID: [UUID: SessionActivitySnapshot] {
        storedSnapshotsByAccountID.mapValues(resolvingFreshness)
    }

    private let accountStore: ProviderAccountStore
    private let credentialStore: any SessionActivityCredentialStoring
    private let githubFetcher: any GitHubAgentTaskFetching
    private let now: () -> Date
    private let freshnessIntervalProvider: () -> TimeInterval
    private let accountResolver: (UUID) -> ProviderAccount?
    private var operationGate = SessionActivityOperationGate()
    private var freshnessTasksByAccountID: [UUID: Task<Void, Never>] = [:]
    private var refreshTasksByAccountID: [UUID: RunningRefresh] = [:]
    private var rateLimitRetryAtByAccountID: [UUID: Date] = [:]
    private var rateLimitFailureCountByAccountID: [UUID: Int] = [:]
    private var activeDataClear: ActiveDataClear?
    private var autoRefreshCoordinator: AutoRefreshCoordinator?

    init(
        accountStore: ProviderAccountStore? = nil,
        credentialStore: (any SessionActivityCredentialStoring)? = nil,
        githubFetcher: (any GitHubAgentTaskFetching)? = nil,
        now: @escaping () -> Date = Date.init,
        freshnessInterval: TimeInterval? = nil,
        accountResolver: ((UUID) -> ProviderAccount?)? = nil
    ) {
        if let freshnessInterval {
            precondition(
                freshnessInterval.isFinite && freshnessInterval > 0,
                "Session activity freshness must be positive and finite"
            )
        }
        self.accountStore = accountStore ?? .shared
        self.credentialStore = credentialStore
            ?? SessionActivityCredentialStore()
        self.githubFetcher = githubFetcher ?? GitHubAgentTaskFetcher()
        self.now = now
        self.freshnessIntervalProvider = freshnessInterval.map { interval in
            { interval }
        } ?? {
            SessionActivityFreshnessConfig.currentInterval
        }
        if let accountResolver {
            self.accountResolver = accountResolver
        } else {
            let resolvedStore = accountStore ?? .shared
            self.accountResolver = { resolvedStore.account(id: $0) }
        }
    }

    deinit {
        for task in freshnessTasksByAccountID.values {
            task.cancel()
        }
        for refresh in refreshTasksByAccountID.values {
            refresh.task.cancel()
        }
    }

    func snapshot(for accountID: UUID) -> SessionActivitySnapshot? {
        storedSnapshotsByAccountID[accountID].map(resolvingFreshness)
    }

    func isFetching(accountID: UUID) -> Bool {
        isFetchingByAccountID[accountID] ?? false
    }

    /// Resolves the same persisted account selection used by usage tracking.
    func refreshSelectedAccount(
        for provider: UsageProvider,
        reason: SessionActivityRefreshReason = .manual
    ) async {
        await refresh(
            account: accountStore.selectedAccount(for: provider),
            reason: reason
        )
    }

    /// Background refresh deliberately skips disabled accounts. Manual refresh
    /// remains available so a user can test credentials before enabling one.
    func refresh(
        account: ProviderAccount,
        reason: SessionActivityRefreshReason = .manual
    ) async {
        guard activeDataClear == nil else { return }
        guard let registeredAccount = registeredAccount(matching: account),
              reason == .manual || registeredAccount.isEnabled else {
            return
        }
        if reason == .background,
           let retryAt = rateLimitRetryAtByAccountID[registeredAccount.id],
           now() < retryAt {
            return
        }
        if let running = refreshTasksByAccountID[registeredAccount.id] {
            await running.task.value
            return
        }

        let refreshID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(account: registeredAccount)
        }
        refreshTasksByAccountID[registeredAccount.id] = RunningRefresh(
            id: refreshID,
            task: task
        )
        await task.value
        if refreshTasksByAccountID[registeredAccount.id]?.id == refreshID {
            refreshTasksByAccountID.removeValue(
                forKey: registeredAccount.id
            )
        }
    }

    private func performRefresh(account: ProviderAccount) async {
        guard let fetchToken = operationGate.beginFetch(for: account.id) else {
            return
        }
        isFetchingByAccountID[account.id] = true
        defer {
            if operationGate.finishFetch(fetchToken) {
                isFetchingByAccountID[account.id] = false
            }
        }

        switch account.provider {
        case .chatgptCodex, .claudeCode:
            guard operationGate.isCurrent(fetchToken) else { return }
            publish(.unavailable(
                account: account,
                availability: .unsupported,
                observedAt: now()
            ))

        case .githubCopilot:
            await refreshGitHubAccount(account, fetchToken: fetchToken)
        }
    }

    func refreshEnabledAccountsInBackground(
        _ accounts: [ProviderAccount]
    ) async {
        let enabledAccounts = accounts.filter(\.isEnabled)
        var startIndex = 0
        while startIndex < enabledAccounts.count {
            let endIndex = min(
                startIndex
                    + SessionActivityFreshnessConfig
                        .maximumBackgroundConcurrency,
                enabledAccounts.count
            )
            await withTaskGroup(of: Void.self) { group in
                for account in enabledAccounts[startIndex..<endIndex] {
                    group.addTask { [weak self] in
                        await self?.refresh(
                            account: account,
                            reason: .background
                        )
                    }
                }
            }
            startIndex = endIndex
        }
    }

    func hasCredential(for account: ProviderAccount) throws -> Bool {
        guard let registeredAccount = registeredAccount(matching: account) else {
            throw SessionActivityViewModelError.accountNotFound
        }
        guard registeredAccount.provider == .githubCopilot else { return false }
        return try credentialStore.credential(for: registeredAccount.id) != nil
    }

    /// Replacing a credential invalidates work and removes counts that may have
    /// belonged to a different GitHub identity.
    func saveCredential(
        _ credential: String,
        for account: ProviderAccount
    ) throws {
        guard activeDataClear == nil else {
            throw SessionActivityViewModelError.dataClearInProgress
        }
        guard let registeredAccount = registeredAccount(matching: account) else {
            throw SessionActivityViewModelError.accountNotFound
        }
        guard registeredAccount.provider == .githubCopilot else {
            throw SessionActivityViewModelError
                .unsupportedCredentialProvider
        }
        try credentialStore.saveCredential(
            credential,
            for: registeredAccount.id
        )
        cancelRefresh(for: registeredAccount.id)
        clearRateLimitState(for: registeredAccount.id)
        removeSnapshot(for: registeredAccount.id)
    }

    /// Deletion is idempotent in the credential store. Publish an explicit
    /// authentication-required state and discard all prior counts.
    func deleteCredential(for account: ProviderAccount) throws {
        guard activeDataClear == nil else {
            throw SessionActivityViewModelError.dataClearInProgress
        }
        guard let registeredAccount = registeredAccount(matching: account) else {
            throw SessionActivityViewModelError.accountNotFound
        }
        guard registeredAccount.provider == .githubCopilot else {
            throw SessionActivityViewModelError
                .unsupportedCredentialProvider
        }
        try credentialStore.deleteCredential(for: registeredAccount.id)
        cancelRefresh(for: registeredAccount.id)
        clearRateLimitState(for: registeredAccount.id)
        publish(.unavailable(
            account: registeredAccount,
            availability: .authenticationRequired,
            observedAt: now()
        ))
    }

    /// Account-removal integration must use this hook before releasing account
    /// state so a Copilot PAT cannot become an orphaned Keychain item. On a
    /// Keychain failure nothing is retired, allowing the caller to retry.
    func retireAccount(_ account: ProviderAccount) throws {
        if account.provider == .githubCopilot {
            try credentialStore.deleteCredential(for: account.id)
        }
        cancelRefresh(for: account.id)
        clearRateLimitState(for: account.id)
        removeSnapshot(for: account.id)
    }

    /// Clear Data integration uses this service-scoped transaction. A Keychain
    /// error leaves credentials and snapshots unchanged. Beginning
    /// the transaction has already invalidated suspended completions.
    func clearAllActivityData() throws {
        guard let token = beginActivityDataClear() else {
            throw SessionActivityViewModelError.dataClearInProgress
        }
        defer { _ = finishActivityDataClear(token) }
        try clearAllActivityData(during: token)
    }

    func beginActivityDataClear() -> SessionActivityDataClearToken? {
        guard activeDataClear == nil,
              let operationToken = operationGate.beginClear() else {
            return nil
        }
        let token = SessionActivityDataClearToken(id: UUID())
        refreshTasksByAccountID.values.forEach { $0.task.cancel() }
        refreshTasksByAccountID.removeAll()
        isFetchingByAccountID.removeAll()
        activeDataClear = ActiveDataClear(
            token: token,
            operationToken: operationToken
        )
        return token
    }

    func clearAllActivityData(
        during token: SessionActivityDataClearToken
    ) throws {
        guard activeDataClear?.token == token else {
            throw SessionActivityViewModelError.dataClearInProgress
        }
        try credentialStore.deleteAllCredentials()
        freshnessTasksByAccountID.values.forEach { $0.cancel() }
        freshnessTasksByAccountID.removeAll()
        rateLimitRetryAtByAccountID.removeAll()
        rateLimitFailureCountByAccountID.removeAll()
        storedSnapshotsByAccountID.removeAll()
        isFetchingByAccountID.removeAll()
    }

    @discardableResult
    func finishActivityDataClear(
        _ token: SessionActivityDataClearToken
    ) -> Bool {
        guard let activeDataClear,
              activeDataClear.token == token else {
            return false
        }
        self.activeDataClear = nil
        return operationGate.finishClear(activeDataClear.operationToken)
    }

    func startAutoRefresh() {
        if autoRefreshCoordinator == nil {
            autoRefreshCoordinator = AutoRefreshCoordinator(
                intervalProvider: {
                    UsageRefreshConfig.refreshIntervalDuration
                },
                refreshHandler: { [weak self] in
                    guard let self else { return }
                    await self.refreshEnabledAccountsInBackground(
                        self.accountStore.loadAccounts()
                    )
                }
            )
        }
        autoRefreshCoordinator?.start()
    }

    func restartAutoRefresh() {
        autoRefreshCoordinator?.restart()
    }

    private func refreshGitHubAccount(
        _ account: ProviderAccount,
        fetchToken: SessionActivityOperationGate.FetchToken
    ) async {
        let credential: String
        do {
            guard let storedCredential = try credentialStore.credential(
                for: account.id
            ) else {
                guard operationGate.isCurrent(fetchToken) else { return }
                publish(.unavailable(
                    account: account,
                    availability: .authenticationRequired,
                    observedAt: now()
                ))
                return
            }
            credential = storedCredential
        } catch SessionActivityCredentialStoreError
            .invalidStoredCredential {
            guard operationGate.isCurrent(fetchToken) else { return }
            publish(.unavailable(
                account: account,
                availability: .authenticationRequired,
                observedAt: now()
            ))
            return
        } catch {
            guard operationGate.isCurrent(fetchToken) else { return }
            publishFailure(for: account)
            return
        }

        do {
            let counts = try await githubFetcher.fetchCurrentActivity(
                credential: credential
            )
            guard operationGate.isCurrent(fetchToken),
                  registeredAccount(matching: account) != nil,
                  credentialStillMatches(
                    credential,
                    accountID: account.id
                  ) else {
                return
            }
            clearRateLimitState(for: account.id)
            publish(.available(
                account: account,
                counts: counts,
                observedAt: now()
            ))
        } catch is CancellationError {
            return
        } catch let error as GitHubAgentTaskFetcherError {
            guard operationGate.isCurrent(fetchToken),
                  registeredAccount(matching: account) != nil,
                  credentialStillMatches(
                    credential,
                    accountID: account.id
                  ) else {
                return
            }
            switch error {
            case .authenticationRequired, .insufficientPermissions:
                clearRateLimitState(for: account.id)
                publish(.unavailable(
                    account: account,
                    availability: .authenticationRequired,
                    observedAt: now()
                ))
            case .rateLimited(let serverRetryAt):
                recordRateLimit(
                    for: account.id,
                    serverRetryAt: serverRetryAt
                )
                publishFailure(for: account)
            default:
                clearRateLimitState(for: account.id)
                publishFailure(for: account)
            }
        } catch {
            guard operationGate.isCurrent(fetchToken),
                  registeredAccount(matching: account) != nil,
                  credentialStillMatches(
                    credential,
                    accountID: account.id
                  ) else {
                return
            }
            clearRateLimitState(for: account.id)
            publishFailure(for: account)
        }
    }

    private func credentialStillMatches(
        _ expectedCredential: String,
        accountID: UUID
    ) -> Bool {
        do {
            return try credentialStore.credential(for: accountID)
                == expectedCredential
        } catch {
            return false
        }
    }

    private func publishFailure(for account: ProviderAccount) {
        if let previous = storedSnapshotsByAccountID[account.id],
           previous.working != nil,
           previous.waiting != nil,
           previous.open != nil {
            publish(previous.markingStale())
        } else {
            publish(.unavailable(
                account: account,
                availability: .error,
                observedAt: now()
            ))
        }
    }

    private func publish(_ snapshot: SessionActivitySnapshot) {
        freshnessTasksByAccountID.removeValue(
            forKey: snapshot.accountID
        )?.cancel()
        storedSnapshotsByAccountID[snapshot.accountID] = snapshot

        guard snapshot.availability == .available else { return }
        let delay = max(
            0,
            snapshot.observedAt.addingTimeInterval(freshnessInterval())
                .timeIntervalSince(now())
        )
        freshnessTasksByAccountID[snapshot.accountID] = Task {
            @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.expireSnapshot(
                accountID: snapshot.accountID,
                observedAt: snapshot.observedAt
            )
        }
    }

    private func removeSnapshot(for accountID: UUID) {
        freshnessTasksByAccountID.removeValue(
            forKey: accountID
        )?.cancel()
        storedSnapshotsByAccountID.removeValue(forKey: accountID)
    }

    private func expireSnapshot(accountID: UUID, observedAt: Date) {
        freshnessTasksByAccountID.removeValue(forKey: accountID)
        guard let snapshot = storedSnapshotsByAccountID[accountID],
              snapshot.availability == .available,
              snapshot.observedAt == observedAt else {
            return
        }
        storedSnapshotsByAccountID[accountID] = snapshot.markingStale()
    }

    private func resolvingFreshness(
        _ snapshot: SessionActivitySnapshot
    ) -> SessionActivitySnapshot {
        guard snapshot.availability == .available,
              now().timeIntervalSince(snapshot.observedAt)
                >= freshnessInterval() else {
            return snapshot
        }
        return snapshot.markingStale()
    }

    private func registeredAccount(
        matching account: ProviderAccount
    ) -> ProviderAccount? {
        guard let registered = accountResolver(account.id),
              registered.provider == account.provider else {
            return nil
        }
        return registered
    }

    private func cancelRefresh(for accountID: UUID) {
        operationGate.invalidate(scope: accountID)
        refreshTasksByAccountID.removeValue(forKey: accountID)?.task.cancel()
        isFetchingByAccountID.removeValue(forKey: accountID)
    }

    private func recordRateLimit(
        for accountID: UUID,
        serverRetryAt: Date
    ) {
        let failureCount = min(
            (rateLimitFailureCountByAccountID[accountID] ?? 0) + 1,
            8
        )
        rateLimitFailureCountByAccountID[accountID] = failureCount
        let exponentialDelay = min(
            pow(2, Double(failureCount - 1)) * 60,
            SessionActivityFreshnessConfig.maximumRateLimitBackoff
        )
        let localRetryAt = now().addingTimeInterval(exponentialDelay)
        rateLimitRetryAtByAccountID[accountID] = max(
            serverRetryAt,
            localRetryAt
        )
    }

    private func clearRateLimitState(for accountID: UUID) {
        rateLimitRetryAtByAccountID.removeValue(forKey: accountID)
        rateLimitFailureCountByAccountID.removeValue(forKey: accountID)
    }

    private func freshnessInterval() -> TimeInterval {
        let interval = freshnessIntervalProvider()
        guard interval.isFinite, interval > 0 else {
            return SessionActivityFreshnessConfig.currentInterval
        }
        return interval
    }
}

extension SessionActivityViewModel: SessionActivityDataClearing {}
