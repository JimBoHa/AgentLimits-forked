// MARK: - TokenUsageViewModel.swift
// Account-isolated ccusage state with selected-account compatibility facades.

import Combine
import Foundation
import WidgetKit

/// Legacy provider-only storage boundary retained for source compatibility in
/// tests and extensions. Production persistence uses the account repository.
protocol TokenUsageSnapshotStoring {
    func loadSnapshot(for provider: TokenUsageProvider) -> TokenUsageSnapshot?
    func saveSnapshot(_ snapshot: TokenUsageSnapshot) throws
    func deleteSnapshot(for provider: TokenUsageProvider) throws
}

extension AppGroupSnapshotStore: TokenUsageSnapshotStoring
    where Provider == TokenUsageProvider, Snapshot == TokenUsageSnapshot {}

protocol CCUsageFetching {
    func fetchSnapshot(
        for provider: TokenUsageProvider
    ) async throws -> TokenUsageSnapshot
    func fetchSnapshot(
        for account: ProviderAccount
    ) async throws -> TokenUsageSnapshot
}

/// Old fakes remain valid while production CCUsageFetcher supplies its exact
/// account overload and consumes ProviderAccount.cliDataRoot.
extension CCUsageFetching {
    func fetchSnapshot(
        for account: ProviderAccount
    ) async throws -> TokenUsageSnapshot {
        guard let provider = account.provider.tokenUsageProvider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        return try await fetchSnapshot(for: provider)
    }
}

extension CCUsageFetcher: CCUsageFetching {}

/// Compatibility adapter used only when an older caller injects a provider
/// store. New production callers must use AccountTokenUsageSnapshotRepository.
@MainActor
private final class ProviderTokenUsageSnapshotRepositoryAdapter:
    AccountTokenUsageSnapshotRepository {
    private let store: any TokenUsageSnapshotStoring
    private let visibilityStore: any SnapshotVisibilityControlling

    init(
        store: any TokenUsageSnapshotStoring,
        visibilityStore: any SnapshotVisibilityControlling
    ) {
        self.store = store
        self.visibilityStore = visibilityStore
    }

    func loadSnapshot(for account: ProviderAccount) -> TokenUsageSnapshot? {
        guard let provider = account.provider.tokenUsageProvider,
              !visibilityStore.isSnapshotSuppressed(
                fileName: provider.snapshotFileName
              ),
              let snapshot = store.loadSnapshot(for: provider),
              snapshot.provider == provider else {
            return nil
        }
        return snapshot
    }

    func saveSnapshot(
        _ snapshot: TokenUsageSnapshot,
        for account: ProviderAccount
    ) throws {
        guard account.provider.tokenUsageProvider == snapshot.provider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        try store.saveSnapshot(snapshot)
        visibilityStore.setSnapshotSuppressed(
            false,
            fileName: snapshot.provider.snapshotFileName
        )
    }

    func deleteSnapshot(for account: ProviderAccount) throws {
        guard let provider = account.provider.tokenUsageProvider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        try store.deleteSnapshot(for: provider)
    }

    func setSnapshotSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) {
        guard let provider = account.provider.tokenUsageProvider else { return }
        visibilityStore.setSnapshotSuppressed(
            isSuppressed,
            fileName: provider.snapshotFileName
        )
    }

    func setSelectedProjectionSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) {
        guard let provider = account.provider.tokenUsageProvider else { return }
        visibilityStore.setSnapshotSuppressed(
            isSuppressed,
            fileName: provider.snapshotFileName
        )
    }

    func publishSelectedSnapshot(
        _ snapshot: TokenUsageSnapshot?,
        for account: ProviderAccount
    ) throws {
        guard let provider = account.provider.tokenUsageProvider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        let fileName = provider.snapshotFileName
        visibilityStore.setSnapshotSuppressed(true, fileName: fileName)
        do {
            if let snapshot {
                guard snapshot.provider == provider else {
                    throw AccountTokenUsageSnapshotRepositoryError
                        .providerMismatch
                }
                try store.saveSnapshot(snapshot)
            } else {
                try store.deleteSnapshot(for: provider)
            }
            visibilityStore.setSnapshotSuppressed(false, fileName: fileName)
        } catch {
            throw error
        }
    }
}

private typealias TokenUsageOperationGate = UsageOperationGate<UUID>

struct TokenUsageSnapshotClearFailure {
    let provider: TokenUsageProvider
    let accountID: UUID?
    let accountLabel: String?
    let isSelectedProjection: Bool
    let reason: String

    var targetDescription: String {
        if isSelectedProjection {
            return "\(provider.displayName) widget"
        }
        if let accountLabel {
            return "\(provider.displayName) — \(accountLabel)"
        }
        return "\(provider.displayName) token usage"
    }
}

enum TokenUsageSnapshotClearError: LocalizedError {
    case clearAlreadyInProgress
    case invalidClearOperation
    case deletion(TokenUsageSnapshotClearFailure)

    var errorDescription: String? {
        switch self {
        case .clearAlreadyInProgress:
            return "Another token-usage clear is already active."
        case .invalidClearOperation:
            return "The token-usage clear operation is no longer active."
        case .deletion(let failure):
            return "\(failure.targetDescription): \(failure.reason)"
        }
    }
}

enum AccountTokenUsageConfigurationError: LocalizedError, Equatable {
    case unsupportedAccountRegistry
    case missingDataRoot(provider: TokenUsageProvider, accountLabel: String)
    case invalidDataRoot(
        provider: TokenUsageProvider,
        accountLabel: String,
        reason: String
    )
    case duplicateDataRoot(
        provider: TokenUsageProvider,
        accountLabel: String,
        conflictingAccountLabel: String
    )
    case defaultDataRootConflict(
        provider: TokenUsageProvider,
        accountLabel: String
    )
    case indeterminateSnapshot(
        provider: TokenUsageProvider,
        accountLabel: String
    )

    var errorDescription: String? {
        switch self {
        case .unsupportedAccountRegistry:
            return "Account data was saved by a newer AgentLimits version. Update the app before fetching account token usage."
        case .missingDataRoot(let provider, let accountLabel):
            return "\(accountLabel) needs a unique \(provider.displayName) CLI data root because another account uses the default profile."
        case .invalidDataRoot(let provider, let accountLabel, let reason):
            return "\(accountLabel) has an invalid \(provider.displayName) CLI data root: \(reason)"
        case .duplicateDataRoot(
            let provider,
            let accountLabel,
            let conflictingAccountLabel
        ):
            return "\(accountLabel) and \(conflictingAccountLabel) use the same \(provider.displayName) CLI data root."
        case .defaultDataRootConflict(let provider, let accountLabel):
            return "\(accountLabel) uses \(provider.displayName)'s default CLI data root, which is already owned by the primary account."
        case .indeterminateSnapshot(let provider, let accountLabel):
            return "Could not safely read \(accountLabel)'s \(provider.displayName) token usage. Try again before changing accounts."
        }
    }
}

/// Account UUID owns every mutable token-usage state. Provider-keyed published
/// dictionaries remain selected-account projections for existing UI/widgets.
@MainActor
final class TokenUsageViewModel: ObservableObject {
    struct ExternalSnapshotContext: Equatable {
        fileprivate let value: TokenUsageOperationGate.Context
        fileprivate let accountID: UUID
        fileprivate let provider: TokenUsageProvider
        fileprivate let settingsRevision: UInt64
        fileprivate let requestIdentifier: UInt64
    }

    struct DataClearToken: Equatable {
        fileprivate let value: TokenUsageOperationGate.ClearToken
    }

    // MARK: - Published compatibility projection

    @Published private(set) var snapshots:
        [TokenUsageProvider: TokenUsageSnapshot] = [:]
    @Published private(set) var statusMessages:
        [TokenUsageProvider: String] = [:]
    @Published private(set) var isFetching:
        [TokenUsageProvider: Bool] = [:]
    @Published private(set) var accountCatalogRevision: UInt64 = 0
    @Published var settings: [TokenUsageProvider: CCUsageSettings] = [:]
    @Published var isAutoRefreshEnabled: Bool = true

    // MARK: - Exact-account state

    private(set) var snapshotsByAccountID:
        [UUID: TokenUsageSnapshot] = [:]
    private(set) var statusMessagesByAccountID: [UUID: String] = [:]
    private(set) var isFetchingByAccountID: [UUID: Bool] = [:]

    private let fetcher: any CCUsageFetching
    private let snapshotRepository: any AccountTokenUsageSnapshotRepository
    private let accountStore: ProviderAccountStore
    private let settingsStore: CCUsageSettingsStore
    private var accountsByID: [UUID: ProviderAccount] = [:]
    private var selectedAccountIDsByProvider:
        [TokenUsageProvider: UUID] = [:]
    private var autoRefreshCoordinator: AutoRefreshCoordinator?
    private var operationGate = TokenUsageOperationGate()
    private var settingsRevisions: [TokenUsageProvider: UInt64] = [:]
    private var latestExternalRequestIdentifiers: [UUID: UInt64] = [:]
    private var nextExternalRequestIdentifier: UInt64 = 0

    // MARK: - Initialization

    init(
        fetcher: (any CCUsageFetching)? = nil,
        snapshotRepository:
            (any AccountTokenUsageSnapshotRepository)? = nil,
        accountStore: ProviderAccountStore? = nil,
        settingsStore: CCUsageSettingsStore? = nil
    ) {
        let resolvedAccountStore = accountStore ?? .shared
        self.fetcher = fetcher ?? CCUsageFetcher()
        self.snapshotRepository = snapshotRepository
            ?? DefaultAccountTokenUsageSnapshotRepository()
        self.accountStore = resolvedAccountStore
        self.settingsStore = settingsStore ?? .shared
        settings = self.settingsStore.loadSettings()

        for provider in TokenUsageProvider.allCases {
            settingsRevisions[provider] = 0
        }
        initializeAccountState(from: resolvedAccountStore.loadAccounts())
        if resolvedAccountStore.supportsPersistentWebSessions {
            for provider in TokenUsageProvider.allCases {
                publishSelectedProjection(for: provider)
            }
        }
    }

    /// Compatibility initializer for older provider-store test fixtures.
    convenience init(
        fetcher: (any CCUsageFetching)? = nil,
        snapshotStore: any TokenUsageSnapshotStoring,
        settingsStore: CCUsageSettingsStore? = nil,
        snapshotVisibilityStore:
            (any SnapshotVisibilityControlling)? = nil
    ) {
        let suiteName =
            "TokenUsageViewModel.Compatibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let compatibilityAccountStore = ProviderAccountStore(
            userDefaults: defaults,
            key: "provider_accounts"
        )
        let visibilityStore = snapshotVisibilityStore
            ?? SnapshotVisibilityStore.shared
        self.init(
            fetcher: fetcher,
            snapshotRepository: ProviderTokenUsageSnapshotRepositoryAdapter(
                store: snapshotStore,
                visibilityStore: visibilityStore
            ),
            accountStore: compatibilityAccountStore,
            settingsStore: settingsStore
        )
    }

    // MARK: - Account access

    func accounts(for provider: TokenUsageProvider) -> [ProviderAccount] {
        accountsByID.values
            .filter { $0.provider == provider.usageProvider }
            .sorted(by: Self.accountSort)
    }

    func selectedAccount(
        for provider: TokenUsageProvider
    ) -> ProviderAccount {
        accountStore.selectedAccount(for: provider.usageProvider)
    }

    func snapshot(for accountID: UUID) -> TokenUsageSnapshot? {
        snapshotsByAccountID[accountID]
    }

    func statusMessage(for accountID: UUID) -> String {
        statusMessagesByAccountID[accountID]
            ?? "tokenUsage.notFetched".localized()
    }

    func isFetching(for accountID: UUID) -> Bool {
        isFetchingByAccountID[accountID] ?? false
    }

    /// Removes the provider-only compatibility projection before shared
    /// account selection changes. Failure aborts selection instead of leaving
    /// the prior account visible under a new selection.
    func prepareSelectedProjectionRemoval(
        for account: ProviderAccount
    ) throws {
        guard accountStore.supportsPersistentWebSessions else {
            throw AccountTokenUsageConfigurationError
                .unsupportedAccountRegistry
        }
        guard accountStore.selectedAccount(for: account.provider).id
                == account.id else {
            return
        }
        guard snapshotRepository.canSafelyMutateSelectedProjection(
            for: account
        ) else {
            guard let provider = account.provider.tokenUsageProvider else {
                throw AccountTokenUsageSnapshotRepositoryError
                    .providerMismatch
            }
            try snapshotRepository.setSelectedProjectionSuppressed(
                true,
                for: account
            )
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
            throw AccountTokenUsageConfigurationError.indeterminateSnapshot(
                provider: provider,
                accountLabel: account.label
            )
        }
        try snapshotRepository.publishSelectedSnapshot(nil, for: account)
    }

    /// Restores the prior projection only if shared selection still points to
    /// that account after a failed registry mutation.
    func restoreSelectedProjection(for account: ProviderAccount) throws {
        guard accountStore.supportsPersistentWebSessions else {
            throw AccountTokenUsageConfigurationError
                .unsupportedAccountRegistry
        }
        guard accountStore.selectedAccount(for: account.provider).id
                == account.id else {
            return
        }
        if !snapshotRepository.canSafelyMutateSelectedProjection(
            for: account
        ) {
            try snapshotRepository.setSelectedProjectionSuppressed(
                true,
                for: account
            )
            if let provider = account.provider.tokenUsageProvider {
                WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
                updateSelectedFacade(for: provider)
            }
            return
        }
        try snapshotRepository.publishSelectedSnapshot(
            snapshotsByAccountID[account.id],
            for: account
        )
        if let provider = account.provider.tokenUsageProvider {
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
        }
    }

    /// Quarantines old-root state before the registry can durably point the
    /// same UUID at a different CLI profile. Failure aborts the registry write.
    func prepareCLIDataRootChange(
        from current: ProviderAccount,
        to proposed: ProviderAccount
    ) throws {
        guard current.id == proposed.id,
              current.provider == proposed.provider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        guard current.cliDataRoot != proposed.cliDataRoot else { return }
        guard accountStore.supportsPersistentWebSessions else {
            throw AccountTokenUsageConfigurationError
                .unsupportedAccountRegistry
        }
        guard accountsByID[current.id]?.provider == current.provider else {
            throw ProviderAccountStoreError.accountNotFound
        }

        operationGate.invalidate(scope: current.id)
        latestExternalRequestIdentifiers.removeValue(forKey: current.id)
        isFetchingByAccountID[current.id] = false
        let deletionError = retirePersistedSnapshot(for: current)
        let projectionError: Error?
        if let provider = current.provider.tokenUsageProvider,
           selectedAccountIDsByProvider[provider] == current.id
            || accountStore.selectedAccount(for: current.provider).id
                == current.id {
            projectionError = clearCompatibilityProjection(for: current)
        } else {
            projectionError = nil
        }
        snapshotsByAccountID.removeValue(forKey: current.id)
        let error = deletionError ?? projectionError
        statusMessagesByAccountID[current.id] = error?
            .localizedDescription ?? "tokenUsage.notFetched".localized()
        if let provider = current.provider.tokenUsageProvider {
            updateSelectedFacade(for: provider)
        }
        if let error { throw error }
    }

    /// Synchronizes account metadata and shared selection. Any metadata change
    /// invalidates suspended work so an old CLI root cannot commit afterward.
    func reloadAccounts() {
        synchronizeAccountCatalog(
            accountStore.loadAccounts(),
            publishesSelectedProjections: true
        )
    }

    /// Invalidates exact-account work and removes its in-memory snapshot before
    /// local data can be deleted, without disturbing same-provider siblings.
    func invalidateAccount(id accountID: UUID) {
        guard let account = accountsByID[accountID] else { return }
        operationGate.invalidate(scope: accountID)
        latestExternalRequestIdentifiers.removeValue(forKey: accountID)
        isFetchingByAccountID[accountID] = false
        snapshotsByAccountID.removeValue(forKey: accountID)
        statusMessagesByAccountID[accountID] =
            "tokenUsage.notFetched".localized()
        if let provider = account.provider.tokenUsageProvider,
           selectedAccountIDsByProvider[provider] == accountID {
            updateSelectedFacade(for: provider)
        }
    }

    /// Reloads only data that survived a pre-commit retirement rollback. If
    /// local deletion already succeeded, the account intentionally stays blank.
    func restoreAccountAfterRetirementCancellation(id accountID: UUID) {
        guard let account = accountStore.account(id: accountID),
              let provider = account.provider.tokenUsageProvider else { return }
        let snapshot = snapshotRepository.loadSnapshot(for: account)
        if let snapshot {
            snapshotsByAccountID[accountID] = snapshot
            statusMessagesByAccountID[accountID] = formatLastUpdated(
                snapshot.fetchedAt
            )
        } else {
            snapshotsByAccountID.removeValue(forKey: accountID)
            statusMessagesByAccountID[accountID] =
                "tokenUsage.notFetched".localized()
        }
        isFetchingByAccountID[accountID] = false
        if selectedAccountIDsByProvider[provider] == accountID {
            publishSelectedProjection(for: provider)
        }
    }

    // MARK: - Settings

    func updateSettings(_ newSettings: CCUsageSettings) {
        let oldSettings = settings[newSettings.provider]
        if oldSettings != newSettings {
            settingsRevisions[newSettings.provider, default: 0] &+= 1
            for account in accounts(for: newSettings.provider) {
                operationGate.invalidate(scope: account.id)
                latestExternalRequestIdentifiers.removeValue(
                    forKey: account.id
                )
                isFetchingByAccountID[account.id] = false
            }
        }
        settings[newSettings.provider] = newSettings
        settingsStore.updateSettings(newSettings)
        updateSelectedFacade(for: newSettings.provider)
    }

    // MARK: - Auto refresh

    func startAutoRefresh() {
        guard autoRefreshCoordinator == nil else { return }
        autoRefreshCoordinator = AutoRefreshCoordinator(
            intervalProvider: {
                TokenUsageRefreshConfig.refreshIntervalDuration
            },
            refreshHandler: { [weak self] in
                guard let self, self.isAutoRefreshEnabled else { return }
                await self.refreshEnabledProviders()
            }
        )
        autoRefreshCoordinator?.start()
    }

    func stopAutoRefresh() {
        autoRefreshCoordinator?.stop()
        autoRefreshCoordinator = nil
    }

    func restartAutoRefresh() {
        stopAutoRefresh()
        startAutoRefresh()
    }

    // MARK: - Refresh

    /// Provider callers share selection with usage-limit UI.
    func refreshNow(for provider: TokenUsageProvider) async {
        reloadAccounts()
        await refresh(for: selectedAccount(for: provider))
    }

    func refreshNow(for account: ProviderAccount) async {
        reloadAccounts()
        guard let current = accountsByID[account.id],
              current.provider == account.provider else {
            return
        }
        await refresh(for: current)
    }

    /// Provider master setting and account setting are both required for
    /// background refresh. Every eligible sibling refreshes independently.
    func refreshEnabledProviders() async {
        reloadAccounts()
        let accountIDs = accountsByID.values
            .filter { account in
                guard let provider = account.provider.tokenUsageProvider else {
                    return false
                }
                return account.isEnabled
                    && settings[provider]?.isEnabled == true
            }
            .sorted(by: Self.accountSort)
            .map(\.id)

        await withTaskGroup(of: Void.self) { group in
            for accountID in accountIDs {
                group.addTask { [weak self] in
                    await self?.refresh(accountID: accountID)
                }
            }
        }
    }

    // MARK: - External Copilot snapshots

    func captureExternalSnapshotContext(
        for provider: TokenUsageProvider
    ) -> ExternalSnapshotContext? {
        reloadAccounts()
        return captureExternalSnapshotContext(
            for: selectedAccount(for: provider)
        )
    }

    func captureExternalSnapshotContext(
        for account: ProviderAccount
    ) -> ExternalSnapshotContext? {
        guard accountStore.supportsPersistentWebSessions,
              let current = accountsByID[account.id],
              current.provider == account.provider,
              let provider = current.provider.tokenUsageProvider,
              settings[provider]?.isEnabled == true,
              let value = operationGate.captureContext(for: current.id) else {
            return nil
        }
        nextExternalRequestIdentifier &+= 1
        let requestIdentifier = nextExternalRequestIdentifier
        latestExternalRequestIdentifiers[current.id] = requestIdentifier
        return ExternalSnapshotContext(
            value: value,
            accountID: current.id,
            provider: provider,
            settingsRevision: settingsRevisions[provider, default: 0],
            requestIdentifier: requestIdentifier
        )
    }

    /// Saves to exact account namespace. Provider facade, widget projection,
    /// and widget reload update only while that account remains selected.
    @discardableResult
    func saveExternallyFetchedSnapshot(
        _ snapshot: TokenUsageSnapshot,
        context: ExternalSnapshotContext
    ) throws -> Bool {
        guard let account = accountsByID[context.accountID],
              account.provider.tokenUsageProvider == snapshot.provider,
              context.provider == snapshot.provider,
              settings[snapshot.provider]?.isEnabled == true,
              settingsRevisions[snapshot.provider, default: 0]
                == context.settingsRevision,
              latestExternalRequestIdentifiers[account.id]
                == context.requestIdentifier,
              operationGate.isCurrent(context.value) else {
            return false
        }

        do {
            try snapshotRepository.saveSnapshot(snapshot, for: account)
            guard operationGate.isCurrent(context.value) else { return false }
            snapshotsByAccountID[account.id] = snapshot
            statusMessagesByAccountID[account.id] = formatLastUpdated(
                snapshot.fetchedAt
            )
            if isSelected(account) {
                try snapshotRepository.publishSelectedSnapshot(
                    snapshot,
                    for: account
                )
                updateSelectedFacade(for: snapshot.provider)
                WidgetCenter.shared.reloadTimelines(
                    ofKind: snapshot.provider.widgetKind
                )
            }
            return true
        } catch {
            guard operationGate.isCurrent(context.value) else { return false }
            statusMessagesByAccountID[account.id] = error.localizedDescription
            if isSelected(account) {
                updateSelectedFacade(for: snapshot.provider)
                WidgetCenter.shared.reloadTimelines(
                    ofKind: snapshot.provider.widgetKind
                )
            }
            throw error
        }
    }

    // MARK: - Clear

    func beginDataClear() -> DataClearToken? {
        guard let token = operationGate.beginClear() else { return nil }
        for accountID in accountsByID.keys {
            isFetchingByAccountID[accountID] = false
        }
        for provider in TokenUsageProvider.allCases {
            updateSelectedFacade(for: provider)
        }
        return DataClearToken(value: token)
    }

    @discardableResult
    func finishDataClear(_ token: DataClearToken) -> Bool {
        operationGate.finishClear(token.value)
    }

    func clearAllSnapshots(
        during token: DataClearToken
    ) -> [TokenUsageSnapshotClearFailure] {
        guard operationGate.isCurrent(token.value) else {
            return TokenUsageProvider.allCases.map {
                TokenUsageSnapshotClearFailure(
                    provider: $0,
                    accountID: nil,
                    accountLabel: nil,
                    isSelectedProjection: true,
                    reason: TokenUsageSnapshotClearError
                        .invalidClearOperation.localizedDescription
                )
            }
        }
        var failures: [TokenUsageSnapshotClearFailure] = []
        var processedAccountIDs: Set<UUID> = []
        if accountStore.supportsPersistentWebSessions {
            while true {
                synchronizeAccountCatalog(
                    accountStore.loadAccounts(),
                    publishesSelectedProjections: false
                )
                let pendingAccounts = accountsByID.values
                    .filter { !processedAccountIDs.contains($0.id) }
                    .sorted(by: Self.accountSort)
                guard !pendingAccounts.isEmpty else { break }
                processedAccountIDs.formUnion(pendingAccounts.map(\.id))
                failures.append(contentsOf: clearSnapshots(
                    for: pendingAccounts,
                    projectionProviders: []
                ))
            }
        } else {
            synchronizeAccountCatalog(
                accountStore.loadAccounts(),
                publishesSelectedProjections: false
            )
        }
        failures.append(contentsOf: clearSnapshots(
            for: [],
            projectionProviders: TokenUsageProvider.allCases
        ))
        if accountStore.supportsPersistentWebSessions {
            while true {
                synchronizeAccountCatalog(
                    accountStore.loadAccounts(),
                    publishesSelectedProjections: false
                )
                let pendingAccounts = accountsByID.values
                    .filter { !processedAccountIDs.contains($0.id) }
                    .sorted(by: Self.accountSort)
                guard !pendingAccounts.isEmpty else { break }
                processedAccountIDs.formUnion(pendingAccounts.map(\.id))
                failures.append(contentsOf: clearSnapshots(
                    for: pendingAccounts,
                    projectionProviders: []
                ))
            }
        }
        return failures
    }

    /// Clears accounts discovered after the first global token sweep and
    /// re-clears every compatibility projection. Callers repeat until their
    /// shared account catalog is stable without an intervening suspension.
    func clearLateRegisteredAccounts(
        _ accounts: [ProviderAccount],
        during token: DataClearToken
    ) -> [TokenUsageSnapshotClearFailure] {
        guard operationGate.isCurrent(token.value) else {
            return TokenUsageProvider.allCases.map {
                TokenUsageSnapshotClearFailure(
                    provider: $0,
                    accountID: nil,
                    accountLabel: nil,
                    isSelectedProjection: true,
                    reason: TokenUsageSnapshotClearError
                        .invalidClearOperation.localizedDescription
                )
            }
        }
        synchronizeAccountCatalog(
            accountStore.loadAccounts(),
            publishesSelectedProjections: false
        )
        let currentAccounts: [ProviderAccount] = accounts.compactMap {
            candidate -> ProviderAccount? in
            guard let current = accountsByID[candidate.id],
                  current.provider == candidate.provider else {
                return nil
            }
            return current
        }
        return clearSnapshots(
            for: currentAccounts,
            projectionProviders: TokenUsageProvider.allCases
        )
    }

    func clearSnapshot(for provider: TokenUsageProvider) throws {
        guard let clearToken = beginDataClear() else {
            throw TokenUsageSnapshotClearError.clearAlreadyInProgress
        }
        defer { _ = finishDataClear(clearToken) }
        let failures = clearSnapshots(
            for: accountStore.supportsPersistentWebSessions
                ? accounts(for: provider)
                : [],
            projectionProviders: [provider]
        )
        guard let failure = failures.first else { return }
        throw TokenUsageSnapshotClearError.deletion(failure)
    }

    func clearSnapshot(for account: ProviderAccount) throws {
        guard let clearToken = beginDataClear() else {
            throw TokenUsageSnapshotClearError.clearAlreadyInProgress
        }
        defer { _ = finishDataClear(clearToken) }
        guard accountStore.supportsPersistentWebSessions else { return }
        guard let current = accountsByID[account.id],
              current.provider == account.provider,
              let provider = current.provider.tokenUsageProvider else {
            return
        }
        let failures = clearSnapshots(
            for: [current],
            projectionProviders: isSelected(current) ? [provider] : []
        )
        guard let failure = failures.first else { return }
        throw TokenUsageSnapshotClearError.deletion(failure)
    }

    // MARK: - Private refresh helpers

    private func refresh(accountID: UUID) async {
        guard let account = accountsByID[accountID] else { return }
        await refresh(for: account)
    }

    private func refresh(for account: ProviderAccount) async {
        guard accountStore.supportsPersistentWebSessions else {
            statusMessagesByAccountID[account.id] =
                AccountTokenUsageConfigurationError
                .unsupportedAccountRegistry.localizedDescription
            if let provider = account.provider.tokenUsageProvider,
               selectedAccountIDsByProvider[provider] == account.id {
                updateSelectedFacade(for: provider)
            }
            return
        }
        guard let provider = account.provider.tokenUsageProvider,
              let fetchToken = operationGate.beginFetch(
                for: account.id
              ) else {
            return
        }
        isFetchingByAccountID[account.id] = true
        if isSelected(account) {
            updateSelectedFacade(for: provider)
        }
        defer {
            if operationGate.finishFetch(fetchToken) {
                isFetchingByAccountID[account.id] = false
                if isSelected(account) {
                    updateSelectedFacade(for: provider)
                }
            }
        }

        // Copilot billing arrives from the exact WebView account. A direct
        // refresh only reloads that account's cached namespace.
        guard provider.isCLIBased else {
            guard operationGate.isCurrent(fetchToken) else { return }
            let cached = snapshotRepository.loadSnapshot(for: account)
            guard operationGate.isCurrent(fetchToken) else { return }
            snapshotsByAccountID[account.id] = cached
            statusMessagesByAccountID[account.id] = cached.map {
                formatLastUpdated($0.fetchedAt)
            } ?? "tokenUsage.notFetched".localized()
            if isSelected(account) {
                publishSelectedProjection(for: provider)
            }
            return
        }

        do {
            try validateCLIDataRoots(for: provider)
            let snapshot = try await fetcher.fetchSnapshot(for: account)
            guard operationGate.isCurrent(fetchToken),
                  snapshot.provider == provider else {
                return
            }
            try snapshotRepository.saveSnapshot(snapshot, for: account)
            guard operationGate.isCurrent(fetchToken) else { return }
            snapshotsByAccountID[account.id] = snapshot
            statusMessagesByAccountID[account.id] = formatLastUpdated(
                snapshot.fetchedAt
            )
            if isSelected(account) {
                try snapshotRepository.publishSelectedSnapshot(
                    snapshot,
                    for: account
                )
                updateSelectedFacade(for: provider)
                WidgetCenter.shared.reloadTimelines(
                    ofKind: provider.widgetKind
                )
            }
        } catch {
            guard operationGate.isCurrent(fetchToken) else { return }
            statusMessagesByAccountID[account.id] = error.localizedDescription
            if isSelected(account) {
                updateSelectedFacade(for: provider)
                WidgetCenter.shared.reloadTimelines(
                    ofKind: provider.widgetKind
                )
            }
        }
    }

    // MARK: - Private account/projection helpers

    private func initializeAccountState(from accounts: [ProviderAccount]) {
        let supportsAccountPersistence =
            accountStore.supportsPersistentWebSessions
        accountsByID = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )
        for account in accounts {
            let snapshot = supportsAccountPersistence
                ? snapshotRepository.loadSnapshot(for: account)
                : nil
            if let snapshot {
                snapshotsByAccountID[account.id] = snapshot
            }
            statusMessagesByAccountID[account.id] =
                supportsAccountPersistence
                ? snapshot.map {
                    formatLastUpdated($0.fetchedAt)
                } ?? "tokenUsage.notFetched".localized()
                : AccountTokenUsageConfigurationError
                    .unsupportedAccountRegistry.localizedDescription
            isFetchingByAccountID[account.id] = false
        }
        selectedAccountIDsByProvider = selectedAccountIDs()
        for provider in TokenUsageProvider.allCases {
            updateSelectedFacade(for: provider)
        }
    }

    /// Multiple accounts must never resolve to the same CLI profile. Oldest
    /// account owns an implicit default; every sibling needs a distinct root.
    private func validateCLIDataRoots(
        for provider: TokenUsageProvider
    ) throws {
        guard provider.isCLIBased else { return }
        let providerAccounts = accounts(for: provider)
        guard providerAccounts.count > 1 else { return }
        let primaryAccount = providerAccounts.first {
            $0.webKitStorage == .legacyDefault
        } ?? providerAccounts[0]
        let orderedAccounts = [primaryAccount] + providerAccounts.filter {
            $0.id != primaryAccount.id
        }

        struct ResolvedRoot {
            let account: ProviderAccount
            let value: String?
        }

        var resolvedRoots: [ResolvedRoot] = []
        for account in orderedAccounts {
            do {
                let environment = try provider.resolveCLIDataRootEnvironment(
                    account.cliDataRoot
                )
                resolvedRoots.append(
                    ResolvedRoot(
                        account: account,
                        value: environment?.value.map(
                            Self.cliRootComparisonKey
                        )
                    )
                )
            } catch {
                throw AccountTokenUsageConfigurationError.invalidDataRoot(
                    provider: provider,
                    accountLabel: account.label,
                    reason: error.localizedDescription
                )
            }
        }

        let primaryUsesDefault = resolvedRoots[0].value == nil
        for resolved in resolvedRoots.dropFirst() where resolved.value == nil {
            throw AccountTokenUsageConfigurationError.missingDataRoot(
                provider: provider,
                accountLabel: resolved.account.label
            )
        }

        var ownersByRoot: [String: ProviderAccount] = [:]
        for resolved in resolvedRoots {
            guard let root = resolved.value else { continue }
            if let owner = ownersByRoot[root] {
                throw AccountTokenUsageConfigurationError.duplicateDataRoot(
                    provider: provider,
                    accountLabel: resolved.account.label,
                    conflictingAccountLabel: owner.label
                )
            }
            ownersByRoot[root] = resolved.account
        }

        guard primaryUsesDefault else { return }
        let defaultRoots = Self.defaultCLIDataRoots(for: provider)
        for resolved in resolvedRoots.dropFirst() {
            guard let root = resolved.value,
                  defaultRoots.contains(root) else { continue }
            throw AccountTokenUsageConfigurationError
                .defaultDataRootConflict(
                    provider: provider,
                    accountLabel: resolved.account.label
                )
        }
    }

    private static func defaultCLIDataRoots(
        for provider: TokenUsageProvider
    ) -> Set<String> {
        let paths: [String]
        switch provider {
        case .codex:
            paths = ["~/.codex"]
        case .claude:
            paths = ["~/.claude", "~/.config/claude"]
        case .copilot:
            paths = []
        }
        var roots: Set<String> = []
        for path in paths {
            do {
                if let value = try provider
                    .resolveCLIDataRootEnvironment(path)?.value {
                    roots.insert(cliRootComparisonKey(value))
                }
            } catch {
                continue
            }
        }
        return roots
    }

    /// Conservatively treats symlink aliases and case-only spellings as the
    /// same profile on typical macOS filesystems.
    private static func cliRootComparisonKey(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL.path.lowercased()
    }

    private func synchronizeAccountCatalog(
        _ accounts: [ProviderAccount],
        publishesSelectedProjections: Bool
    ) {
        let oldAccounts = accountsByID
        let oldSelectedIDs = selectedAccountIDsByProvider
        let incoming = Dictionary(
            uniqueKeysWithValues: accounts.map { ($0.id, $0) }
        )

        guard accountStore.supportsPersistentWebSessions else {
            for accountID in oldAccounts.keys {
                operationGate.invalidate(scope: accountID)
            }
            accountsByID = incoming
            snapshotsByAccountID.removeAll()
            latestExternalRequestIdentifiers.removeAll()
            isFetchingByAccountID = Dictionary(
                uniqueKeysWithValues: accounts.map { ($0.id, false) }
            )
            statusMessagesByAccountID = Dictionary(
                uniqueKeysWithValues: accounts.map {
                    (
                        $0.id,
                        AccountTokenUsageConfigurationError
                            .unsupportedAccountRegistry.localizedDescription
                    )
                }
            )
            selectedAccountIDsByProvider = selectedAccountIDs()
            if oldAccounts != incoming
                || oldSelectedIDs != selectedAccountIDsByProvider {
                accountCatalogRevision &+= 1
            }
            for provider in TokenUsageProvider.allCases {
                updateSelectedFacade(for: provider)
            }
            return
        }

        for (accountID, oldAccount) in oldAccounts {
            guard let newAccount = incoming[accountID] else {
                operationGate.invalidate(scope: accountID)
                latestExternalRequestIdentifiers.removeValue(
                    forKey: accountID
                )
                snapshotsByAccountID.removeValue(forKey: accountID)
                statusMessagesByAccountID.removeValue(forKey: accountID)
                isFetchingByAccountID.removeValue(forKey: accountID)
                continue
            }
            if newAccount != oldAccount {
                operationGate.invalidate(scope: accountID)
                latestExternalRequestIdentifiers.removeValue(
                    forKey: accountID
                )
                isFetchingByAccountID[accountID] = false
                if newAccount.provider != oldAccount.provider {
                    retireSnapshotAfterProviderChange(
                        from: oldAccount,
                        to: newAccount
                    )
                } else if newAccount.cliDataRoot != oldAccount.cliDataRoot {
                    retireSnapshotAfterDataRootChange(for: newAccount)
                }
            }
        }

        accountsByID = incoming
        for account in accounts where oldAccounts[account.id] == nil {
            let snapshot = snapshotRepository.loadSnapshot(for: account)
            if let snapshot {
                snapshotsByAccountID[account.id] = snapshot
            }
            statusMessagesByAccountID[account.id] = snapshot.map {
                formatLastUpdated($0.fetchedAt)
            } ?? "tokenUsage.notFetched".localized()
            isFetchingByAccountID[account.id] = false
        }
        selectedAccountIDsByProvider = selectedAccountIDs()

        if oldAccounts != incoming
            || oldSelectedIDs != selectedAccountIDsByProvider {
            accountCatalogRevision &+= 1
        }
        for provider in TokenUsageProvider.allCases {
            if publishesSelectedProjections {
                publishSelectedProjection(for: provider)
            } else {
                updateSelectedFacade(for: provider)
            }
        }
    }

    /// A snapshot fetched from the prior CLI root must never be displayed
    /// under new profile metadata. Deletion failure stays suppressed.
    private func retireSnapshotAfterDataRootChange(
        for account: ProviderAccount
    ) {
        let deletionError = retirePersistedSnapshot(for: account)
        let projectionError: Error?
        if let provider = account.provider.tokenUsageProvider,
           selectedAccountIDsByProvider[provider] == account.id
            || accountStore.selectedAccount(for: account.provider).id
                == account.id {
            projectionError = clearCompatibilityProjection(for: account)
        } else {
            projectionError = nil
        }
        snapshotsByAccountID.removeValue(forKey: account.id)
        statusMessagesByAccountID[account.id] = (deletionError
            ?? projectionError)?
            .localizedDescription ?? "tokenUsage.notFetched".localized()
    }

    /// Provider is immutable in supported writes. If a current-schema payload
    /// is corrupt, treat a same-UUID provider swap as an identity replacement
    /// and retire the prior provider file before exposing the new catalog.
    private func retireSnapshotAfterProviderChange(
        from oldAccount: ProviderAccount,
        to newAccount: ProviderAccount
    ) {
        let oldDeletionError = retirePersistedSnapshot(for: oldAccount)
        let newDeletionError = retirePersistedSnapshot(for: newAccount)
        let oldProjectionError: Error?
        if let oldProvider = oldAccount.provider.tokenUsageProvider,
           selectedAccountIDsByProvider[oldProvider] == oldAccount.id {
            oldProjectionError = clearCompatibilityProjection(
                for: oldAccount
            )
        } else {
            oldProjectionError = nil
        }
        let newProjectionError: Error?
        if accountStore.selectedAccount(for: newAccount.provider).id
            == newAccount.id {
            newProjectionError = clearCompatibilityProjection(
                for: newAccount
            )
        } else {
            newProjectionError = nil
        }
        snapshotsByAccountID.removeValue(forKey: oldAccount.id)
        statusMessagesByAccountID[newAccount.id] = (oldDeletionError
            ?? newDeletionError
            ?? oldProjectionError
            ?? newProjectionError)?
            .localizedDescription ?? "tokenUsage.notFetched".localized()
    }

    /// Suppression is removed only after both migration retirement and file
    /// deletion succeed. A failed quarantine remains invisible and retryable.
    private func retirePersistedSnapshot(
        for account: ProviderAccount
    ) -> Error? {
        do {
            try snapshotRepository.setSnapshotSuppressed(
                true,
                for: account
            )
            try snapshotRepository.deleteSnapshot(for: account)
            try snapshotRepository.setSnapshotSuppressed(
                false,
                for: account
            )
            return nil
        } catch {
            return error
        }
    }

    /// Deliberate metadata invalidation bypasses the transient-read gate. The
    /// old provider facade must fail closed even if scoped deletion failed.
    private func clearCompatibilityProjection(
        for account: ProviderAccount
    ) -> Error? {
        guard let provider = account.provider.tokenUsageProvider else {
            return nil
        }
        do {
            try snapshotRepository.publishSelectedSnapshot(nil, for: account)
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
            return nil
        } catch {
            return error
        }
    }

    private func selectedAccountIDs() -> [TokenUsageProvider: UUID] {
        Dictionary(
            uniqueKeysWithValues: TokenUsageProvider.allCases.map {
                ($0, accountStore.selectedAccount(for: $0.usageProvider).id)
            }
        )
    }

    private func isSelected(_ account: ProviderAccount) -> Bool {
        guard let provider = account.provider.tokenUsageProvider else {
            return false
        }
        return accountStore.selectedAccount(for: account.provider).id
            == account.id
            && selectedAccountIDsByProvider[provider] == account.id
    }

    private func publishSelectedProjection(
        for provider: TokenUsageProvider
    ) {
        let selected = accountStore.selectedAccount(
            for: provider.usageProvider
        )
        guard let account = accountsByID[selected.id] else {
            snapshots.removeValue(forKey: provider)
            statusMessages[provider] = "tokenUsage.notFetched".localized()
            isFetching[provider] = false
            return
        }
        let selectedSnapshot = snapshotsByAccountID[account.id]
        guard snapshotRepository.canSafelyMutateSelectedProjection(
            for: account
        ) else {
            do {
                try snapshotRepository.setSelectedProjectionSuppressed(
                    true,
                    for: account
                )
            } catch {
                statusMessagesByAccountID[account.id] =
                    error.localizedDescription
            }
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
            updateSelectedFacade(for: provider)
            return
        }
        do {
            try snapshotRepository.publishSelectedSnapshot(
                selectedSnapshot,
                for: account
            )
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
        } catch {
            statusMessagesByAccountID[account.id] = error.localizedDescription
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
        }
        updateSelectedFacade(for: provider)
    }

    private func updateSelectedFacade(for provider: TokenUsageProvider) {
        let selectedID = selectedAccountIDsByProvider[provider]
            ?? accountStore.selectedAccount(for: provider.usageProvider).id
        if let snapshot = snapshotsByAccountID[selectedID],
           snapshot.provider == provider {
            snapshots[provider] = snapshot
        } else {
            snapshots.removeValue(forKey: provider)
        }
        statusMessages[provider] = statusMessagesByAccountID[selectedID]
            ?? "tokenUsage.notFetched".localized()
        isFetching[provider] = isFetchingByAccountID[selectedID] ?? false
    }

    private func clearSnapshots(
        for accounts: [ProviderAccount],
        projectionProviders: [TokenUsageProvider]
    ) -> [TokenUsageSnapshotClearFailure] {
        var failures: [TokenUsageSnapshotClearFailure] = []

        for account in accounts {
            guard let provider = account.provider.tokenUsageProvider else {
                continue
            }
            let deletionError: Error?
            do {
                try snapshotRepository.setSnapshotSuppressed(
                    true,
                    for: account
                )
                try snapshotRepository.deleteSnapshot(for: account)
                try snapshotRepository.setSnapshotSuppressed(
                    false,
                    for: account
                )
                deletionError = nil
            } catch {
                deletionError = error
            }

            snapshotsByAccountID.removeValue(forKey: account.id)
            isFetchingByAccountID[account.id] = false
            statusMessagesByAccountID[account.id] = deletionError?
                .localizedDescription ?? "tokenUsage.notFetched".localized()
            if let deletionError {
                failures.append(
                    TokenUsageSnapshotClearFailure(
                        provider: provider,
                        accountID: account.id,
                        accountLabel: account.label,
                        isSelectedProjection: false,
                        reason: deletionError.localizedDescription
                    )
                )
            }
        }

        for provider in projectionProviders {
            let account = accountStore.selectedAccount(
                for: provider.usageProvider
            )
            do {
                try snapshotRepository.publishSelectedSnapshot(
                    nil,
                    for: account
                )
                WidgetCenter.shared.reloadTimelines(
                    ofKind: provider.widgetKind
                )
            } catch {
                failures.append(
                    TokenUsageSnapshotClearFailure(
                        provider: provider,
                        accountID: account.id,
                        accountLabel: account.label,
                        isSelectedProjection: true,
                        reason: error.localizedDescription
                    )
                )
                statusMessagesByAccountID[account.id] =
                    error.localizedDescription
                WidgetCenter.shared.reloadTimelines(
                    ofKind: provider.widgetKind
                )
            }
        }

        for provider in TokenUsageProvider.allCases {
            updateSelectedFacade(for: provider)
        }
        return failures
    }

    private func formatLastUpdated(_ date: Date) -> String {
        "tokenUsage.updated".localized()
            + Self.timeFormatter.string(from: date)
    }

    private static func accountSort(
        _ left: ProviderAccount,
        _ right: ProviderAccount
    ) -> Bool {
        if left.provider != right.provider {
            return left.provider.rawValue < right.provider.rawValue
        }
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id.uuidString < right.id.uuidString
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
