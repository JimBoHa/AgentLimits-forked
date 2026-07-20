import Combine
import Foundation

enum MobileSessionActivityError: LocalizedError, Equatable {
    case accountNotFound
    case unsupportedCredentialProvider
    case clearInProgress
    case accountMutationInProgress

    var errorDescription: String? {
        switch self {
        case .accountNotFound:
            return "The account no longer exists."
        case .unsupportedCredentialProvider:
            return "Current-session credentials are supported only for GitHub Copilot."
        case .clearInProgress:
            return "Session data is being cleared."
        case .accountMutationInProgress:
            return "This account is already being updated."
        }
    }
}

nonisolated struct MobileSessionDataClearToken: Equatable, Sendable {
    fileprivate let id: UUID
}

nonisolated enum MobileSessionRefreshReason: Equatable, Sendable {
    case manual
    case automatic
}

nonisolated enum MobileSessionRefreshConfig {
    static let automaticInterval: Duration = .seconds(5 * 60)
    static let freshnessInterval: TimeInterval = 10 * 60
    static let maximumBackgroundConcurrency = 4
}

@MainActor
final class MobileSessionActivityController: ObservableObject {
    private struct RunningRefresh {
        let id: UUID
        let task: Task<Void, Never>
    }

    @Published private(set) var snapshotsByAccountID:
        [UUID: MobileSessionActivitySnapshot] = [:]
    @Published private(set) var fetchingAccountIDs: Set<UUID> = []

    private let accountResolver: any MobileAccountResolving
    private let credentialStore: any MobileSessionCredentialStoring
    private let fetcher: any GitHubAgentTaskFetching
    private let now: () -> Date
    private let freshnessInterval: TimeInterval
    private var generationsByAccountID: [UUID: UInt64] = [:]
    private var runningRefreshesByAccountID: [UUID: RunningRefresh] = [:]
    private var freshnessTasksByAccountID: [UUID: Task<Void, Never>] = [:]
    private var rateLimitRetryAtByAccountID: [UUID: Date] = [:]
    private var activeClearToken: MobileSessionDataClearToken?
    private var clearGeneration: UInt64 = 0
    private var mutationClearGenerationByAccountID: [UUID: UInt64] = [:]

    init(
        accountResolver: any MobileAccountResolving,
        credentialStore: (any MobileSessionCredentialStoring)? = nil,
        fetcher: any GitHubAgentTaskFetching = GitHubAgentTaskFetcher(),
        now: @escaping () -> Date = Date.init,
        freshnessInterval: TimeInterval =
            MobileSessionRefreshConfig.freshnessInterval
    ) {
        precondition(
            freshnessInterval.isFinite && freshnessInterval > 0,
            "Session activity freshness must be positive and finite"
        )
        self.accountResolver = accountResolver
        self.credentialStore = credentialStore
            ?? MobileSessionCredentialStore()
        self.fetcher = fetcher
        self.now = now
        self.freshnessInterval = freshnessInterval
    }

    deinit {
        freshnessTasksByAccountID.values.forEach { $0.cancel() }
        runningRefreshesByAccountID.values.forEach { $0.task.cancel() }
    }

    func snapshot(for account: MobileProviderAccount) -> MobileSessionActivitySnapshot {
        if let storedSnapshot = snapshotsByAccountID[account.id],
           storedSnapshot.provider == account.provider {
            return resolvingFreshness(storedSnapshot)
        }
        if account.provider.supportsCurrentSessions {
            return .notChecked(account: account)
        }
        return .unavailable(account: account, availability: .unsupported)
    }

    func providerSnapshot(
        for provider: MobileProvider
    ) -> MobileProviderActivitySnapshot {
        MobileProviderActivitySnapshot(
            provider: provider,
            accounts: accountResolver.accounts
                .filter { $0.provider == provider }
                .map(snapshot(for:))
        )
    }

    func isFetching(accountID: UUID) -> Bool {
        fetchingAccountIDs.contains(accountID)
    }

    func hasCredential(for accountID: UUID) throws -> Bool {
        let account = try registeredAccount(id: accountID)
        guard account.provider == .copilot else { return false }
        return try credentialStore.credential(for: account.id) != nil
    }

    func saveCredential(
        _ credential: String,
        for accountID: UUID
    ) async throws {
        guard activeClearToken == nil else {
            throw MobileSessionActivityError.clearInProgress
        }
        var account = try registeredAccount(id: accountID)
        guard account.provider == .copilot else {
            throw MobileSessionActivityError.unsupportedCredentialProvider
        }
        let mutationGeneration = try beginAccountMutation(accountID: account.id)
        defer { finishAccountMutation(accountID: account.id) }
        await cancelRefreshes(for: [account.id])
        try validateAccountMutation(
            accountID: account.id,
            clearGeneration: mutationGeneration
        )
        account = try registeredAccount(id: accountID)
        guard account.provider == .copilot else {
            throw MobileSessionActivityError.unsupportedCredentialProvider
        }
        try credentialStore.saveCredential(credential, for: account.id)
        rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
        publish(.notChecked(account: account))
    }

    func deleteCredential(for accountID: UUID) async throws {
        guard activeClearToken == nil else {
            throw MobileSessionActivityError.clearInProgress
        }
        var account = try registeredAccount(id: accountID)
        guard account.provider == .copilot else {
            throw MobileSessionActivityError.unsupportedCredentialProvider
        }
        let mutationGeneration = try beginAccountMutation(accountID: account.id)
        defer { finishAccountMutation(accountID: account.id) }
        await cancelRefreshes(for: [account.id])
        try validateAccountMutation(
            accountID: account.id,
            clearGeneration: mutationGeneration
        )
        account = try registeredAccount(id: accountID)
        guard account.provider == .copilot else {
            throw MobileSessionActivityError.unsupportedCredentialProvider
        }
        try credentialStore.deleteCredential(for: account.id)
        rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
        publish(.unavailable(
            account: account,
            availability: .authenticationRequired
        ))
    }

    /// Call before removing the account registry entry. A Keychain failure
    /// leaves the account reachable so cleanup can be retried.
    func prepareAccountRetirement(
        _ account: MobileProviderAccount
    ) async throws {
        let mutationGeneration = try beginAccountMutation(accountID: account.id)
        do {
            await cancelRefreshes(for: [account.id])
            try validateAccountMutation(
                accountID: account.id,
                clearGeneration: mutationGeneration
            )
            _ = try registeredAccount(id: account.id)
        } catch {
            finishAccountMutation(accountID: account.id)
            throw error
        }
    }

    func validatePreparedAccountRetirement(
        _ account: MobileProviderAccount
    ) throws {
        guard let mutationGeneration =
            mutationClearGenerationByAccountID[account.id] else {
            throw MobileSessionActivityError.accountMutationInProgress
        }
        try validateAccountMutation(
            accountID: account.id,
            clearGeneration: mutationGeneration
        )
    }

    func cancelAccountRetirement(_ account: MobileProviderAccount) {
        finishAccountMutation(accountID: account.id)
    }

    func retireAccount(_ account: MobileProviderAccount) throws {
        defer { finishAccountMutation(accountID: account.id) }
        try validatePreparedAccountRetirement(account)
        if account.provider == .copilot {
            try credentialStore.deleteCredential(for: account.id)
        }
        rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
        removeSnapshot(for: account.id)
    }

    func refresh(
        accountID: UUID,
        reason: MobileSessionRefreshReason = .manual
    ) async {
        guard activeClearToken == nil,
              mutationClearGenerationByAccountID[accountID] == nil,
              let account = accountResolver.account(id: accountID) else {
            return
        }
        guard account.provider == .copilot else {
            publish(.unavailable(
                account: account,
                availability: .unsupported
            ))
            return
        }
        if reason == .automatic,
           let retryAt = rateLimitRetryAtByAccountID[account.id],
           now() < retryAt {
            return
        }
        if let running = runningRefreshesByAccountID[account.id] {
            await running.task.value
            return
        }

        let refreshID = UUID()
        let generation = generationsByAccountID[account.id, default: 0]
        fetchingAccountIDs.insert(account.id)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performRefresh(
                account: account,
                refreshID: refreshID,
                generation: generation
            )
        }
        runningRefreshesByAccountID[account.id] = RunningRefresh(
            id: refreshID,
            task: task
        )
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if runningRefreshesByAccountID[account.id]?.id == refreshID {
            runningRefreshesByAccountID.removeValue(forKey: account.id)
            fetchingAccountIDs.remove(account.id)
        }
    }

    private func performRefresh(
        account: MobileProviderAccount,
        refreshID: UUID,
        generation: UInt64
    ) async {
        let credential: String
        do {
            guard let savedCredential = try credentialStore.credential(
                for: account.id
            ) else {
                rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
                guard isCurrent(
                    refreshID: refreshID,
                    generation: generation,
                    account: account
                ) else { return }
                publishAuthenticationRequired(for: account)
                return
            }
            credential = savedCredential
        } catch MobileSessionCredentialStoreError.invalidStoredCredential {
            rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
            guard isCurrent(
                refreshID: refreshID,
                generation: generation,
                account: account
            ) else { return }
            publishAuthenticationRequired(for: account)
            return
        } catch {
            guard isCurrent(
                refreshID: refreshID,
                generation: generation,
                account: account
            ) else { return }
            publishTransientFailure(for: account)
            return
        }

        do {
            let counts = try await fetcher.fetchCurrentActivity(
                credential: credential
            )
            guard isCurrent(
                refreshID: refreshID,
                generation: generation,
                account: account
            ), credentialStillMatches(credential, accountID: account.id) else {
                return
            }
            publish(.available(
                account: account,
                counts: counts,
                observedAt: now()
            ))
            rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
        } catch is CancellationError {
            return
        } catch let error as GitHubAgentTaskFetcherError {
            guard isCurrent(
                refreshID: refreshID,
                generation: generation,
                account: account
            ), credentialStillMatches(credential, accountID: account.id) else {
                return
            }
            switch error {
            case .authenticationRequired:
                rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
                publishAuthenticationRequired(for: account)
            case .insufficientPermissions:
                rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
                publish(.unavailable(
                    account: account,
                    availability: .insufficientPermissions
                ))
            case .rateLimited(let serverRetryAt):
                let retryAt = max(
                    serverRetryAt,
                    now().addingTimeInterval(60)
                )
                rateLimitRetryAtByAccountID[account.id] = retryAt
                publish(.rateLimited(
                    account: account,
                    previous: snapshotsByAccountID[account.id],
                    retryAt: retryAt
                ))
            default:
                rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
                publishTransientFailure(for: account)
            }
        } catch {
            guard isCurrent(
                refreshID: refreshID,
                generation: generation,
                account: account
            ), credentialStillMatches(credential, accountID: account.id) else {
                return
            }
            rateLimitRetryAtByAccountID.removeValue(forKey: account.id)
            publishTransientFailure(for: account)
        }
    }

    func refreshEnabledAccounts() async {
        let accountIDs = accountResolver.accounts
            .filter { $0.isEnabled }
            .map(\.id)
        var startIndex = 0
        while startIndex < accountIDs.count {
            let endIndex = min(
                startIndex
                    + MobileSessionRefreshConfig.maximumBackgroundConcurrency,
                accountIDs.count
            )
            await withTaskGroup(of: Void.self) { group in
                for accountID in accountIDs[startIndex..<endIndex] {
                    group.addTask { [weak self] in
                        await self?.refresh(
                            accountID: accountID,
                            reason: .automatic
                        )
                    }
                }
            }
            startIndex = endIndex
        }
    }

    func beginClear() -> MobileSessionDataClearToken? {
        guard activeClearToken == nil else { return nil }
        let token = MobileSessionDataClearToken(id: UUID())
        activeClearToken = token
        clearGeneration &+= 1
        let accountIDs = Set(accountResolver.accounts.map(\.id))
            .union(runningRefreshesByAccountID.keys)
        for accountID in accountIDs {
            generationsByAccountID[accountID, default: 0] &+= 1
            runningRefreshesByAccountID[accountID]?.task.cancel()
        }
        return token
    }

    func clearSessionData(
        during token: MobileSessionDataClearToken
    ) async throws {
        guard activeClearToken == token else {
            throw MobileSessionActivityError.clearInProgress
        }
        await cancelRefreshes(
            for: Set(accountResolver.accounts.map(\.id))
                .union(runningRefreshesByAccountID.keys)
        )
        guard activeClearToken == token else {
            throw MobileSessionActivityError.clearInProgress
        }
        try credentialStore.deleteAllCredentials()
        freshnessTasksByAccountID.values.forEach { $0.cancel() }
        freshnessTasksByAccountID.removeAll()
        rateLimitRetryAtByAccountID.removeAll()
        snapshotsByAccountID.removeAll()
        fetchingAccountIDs.removeAll()
        runningRefreshesByAccountID.removeAll()
    }

    @discardableResult
    func finishClear(_ token: MobileSessionDataClearToken) -> Bool {
        guard activeClearToken == token else { return false }
        activeClearToken = nil
        return true
    }

    func clearAllSessionData() async throws {
        guard let token = beginClear() else {
            throw MobileSessionActivityError.clearInProgress
        }
        defer { _ = finishClear(token) }
        try await clearSessionData(during: token)
    }

    private func registeredAccount(id: UUID) throws -> MobileProviderAccount {
        guard let account = accountResolver.account(id: id) else {
            throw MobileSessionActivityError.accountNotFound
        }
        return account
    }

    private func isCurrent(
        refreshID: UUID,
        generation: UInt64,
        account: MobileProviderAccount
    ) -> Bool {
        activeClearToken == nil
            && mutationClearGenerationByAccountID[account.id] == nil
            && runningRefreshesByAccountID[account.id]?.id == refreshID
            && generationsByAccountID[account.id, default: 0] == generation
            && accountResolver.account(id: account.id)?.provider
                == account.provider
    }

    private func credentialStillMatches(
        _ expectedCredential: String,
        accountID: UUID
    ) -> Bool {
        (try? credentialStore.credential(for: accountID))
            == expectedCredential
    }

    private func publishAuthenticationRequired(
        for account: MobileProviderAccount
    ) {
        publish(.unavailable(
            account: account,
            availability: .authenticationRequired
        ))
    }

    private func publishTransientFailure(for account: MobileProviderAccount) {
        if let previous = snapshotsByAccountID[account.id],
           previous.working != nil,
           previous.waiting != nil,
           previous.open != nil {
            publish(previous.markingStale())
        } else {
            publish(.unavailable(
                account: account,
                availability: .unavailable
            ))
        }
    }

    private func cancelRefreshes(for accountIDs: Set<UUID>) async {
        let refreshes: [(UUID, RunningRefresh)] = accountIDs.compactMap {
            accountID in
            generationsByAccountID[accountID, default: 0] &+= 1
            guard let running = runningRefreshesByAccountID[accountID] else {
                fetchingAccountIDs.remove(accountID)
                return nil
            }
            running.task.cancel()
            return (accountID, running)
        }

        for (accountID, running) in refreshes {
            await running.task.value
            guard runningRefreshesByAccountID[accountID]?.id == running.id else {
                continue
            }
            runningRefreshesByAccountID.removeValue(forKey: accountID)
            fetchingAccountIDs.remove(accountID)
        }
    }

    private func beginAccountMutation(accountID: UUID) throws -> UInt64 {
        guard activeClearToken == nil else {
            throw MobileSessionActivityError.clearInProgress
        }
        guard mutationClearGenerationByAccountID[accountID] == nil else {
            throw MobileSessionActivityError.accountMutationInProgress
        }
        mutationClearGenerationByAccountID[accountID] = clearGeneration
        return clearGeneration
    }

    private func validateAccountMutation(
        accountID: UUID,
        clearGeneration mutationGeneration: UInt64
    ) throws {
        guard activeClearToken == nil,
              clearGeneration == mutationGeneration,
              mutationClearGenerationByAccountID[accountID]
                == mutationGeneration else {
            throw MobileSessionActivityError.clearInProgress
        }
    }

    private func finishAccountMutation(accountID: UUID) {
        mutationClearGenerationByAccountID.removeValue(forKey: accountID)
    }

    private func publish(_ snapshot: MobileSessionActivitySnapshot) {
        freshnessTasksByAccountID.removeValue(
            forKey: snapshot.accountID
        )?.cancel()
        snapshotsByAccountID[snapshot.accountID] = snapshot

        guard snapshot.availability == .available,
              let observedAt = snapshot.observedAt else {
            return
        }
        let delay = max(
            0,
            observedAt.addingTimeInterval(freshnessInterval)
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
                observedAt: observedAt
            )
        }
    }

    private func removeSnapshot(for accountID: UUID) {
        freshnessTasksByAccountID.removeValue(
            forKey: accountID
        )?.cancel()
        snapshotsByAccountID.removeValue(forKey: accountID)
    }

    private func expireSnapshot(accountID: UUID, observedAt: Date) {
        freshnessTasksByAccountID.removeValue(forKey: accountID)
        guard let snapshot = snapshotsByAccountID[accountID],
              snapshot.availability == .available,
              snapshot.observedAt == observedAt else {
            return
        }
        snapshotsByAccountID[accountID] = snapshot.markingStale()
    }

    private func resolvingFreshness(
        _ snapshot: MobileSessionActivitySnapshot
    ) -> MobileSessionActivitySnapshot {
        guard snapshot.availability == .available,
              let observedAt = snapshot.observedAt,
              now().timeIntervalSince(observedAt) >= freshnessInterval else {
            return snapshot
        }
        return snapshot.markingStale()
    }
}
