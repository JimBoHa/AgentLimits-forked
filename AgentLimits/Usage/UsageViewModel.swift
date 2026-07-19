// MARK: - UsageViewModel.swift
// Account-isolated usage fetching, persistence, and selected-account display.

import Combine
import Foundation
import OSLog
import WebKit
import WidgetKit

@MainActor
protocol UsageSnapshotFetching {
    func hasValidSession(
        for provider: UsageProvider,
        using webView: WKWebView
    ) async -> Bool
    func fetchSnapshot(
        for provider: UsageProvider,
        using webView: WKWebView
    ) async throws -> UsageSnapshot
}

@MainActor
final class DefaultUsageSnapshotFetcher: UsageSnapshotFetching {
    private let codexFetcher: CodexUsageFetcher
    private let claudeFetcher: ClaudeUsageFetcher
    private let copilotFetcher: CopilotUsageFetcher

    init(
        codexFetcher: CodexUsageFetcher? = nil,
        claudeFetcher: ClaudeUsageFetcher? = nil,
        copilotFetcher: CopilotUsageFetcher? = nil
    ) {
        self.codexFetcher = codexFetcher ?? CodexUsageFetcher()
        self.claudeFetcher = claudeFetcher ?? ClaudeUsageFetcher()
        self.copilotFetcher = copilotFetcher ?? CopilotUsageFetcher()
    }

    func hasValidSession(
        for provider: UsageProvider,
        using webView: WKWebView
    ) async -> Bool {
        switch provider {
        case .chatgptCodex:
            return await codexFetcher.hasValidSession(using: webView)
        case .claudeCode:
            return await claudeFetcher.hasValidSession(using: webView)
        case .githubCopilot:
            return await copilotFetcher.hasValidSession(using: webView)
        }
    }

    func fetchSnapshot(
        for provider: UsageProvider,
        using webView: WKWebView
    ) async throws -> UsageSnapshot {
        switch provider {
        case .chatgptCodex:
            return try await codexFetcher.fetchUsageSnapshot(using: webView)
        case .claudeCode:
            return try await claudeFetcher.fetchUsageSnapshot(using: webView)
        case .githubCopilot:
            return try await copilotFetcher.fetchUsageSnapshot(using: webView)
        }
    }
}

@MainActor
protocol CopilotBillingFetching {
    func fetchBillingSnapshot(
        using webView: WKWebView
    ) async throws -> TokenUsageSnapshot
}

extension CopilotBillingFetcher: CopilotBillingFetching {}

struct ClearDataDeletionFailure: Hashable {
    let target: String
    let reason: String
    fileprivate let identifier: String

    static func == (
        lhs: ClearDataDeletionFailure,
        rhs: ClearDataDeletionFailure
    ) -> Bool {
        lhs.identifier == rhs.identifier
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(identifier)
    }
}

enum ClearDataError: LocalizedError {
    case websiteData(String)
    case activityData(String)
    case snapshotDeletion([ClearDataDeletionFailure])

    var errorDescription: String? {
        switch self {
        case .websiteData(let reason):
            return reason
        case .activityData(let reason):
            return reason
        case .snapshotDeletion(let failures):
            return failures
                .map { "\($0.target): \($0.reason)" }
                .joined(separator: "; ")
        }
    }
}

private typealias AccountUsageOperationGate = UsageOperationGate<UUID>

/// Main usage model. Account UUID is the identity for all mutable state and
/// persistence. Provider selection controls only the displayed projection.
@MainActor
final class UsageViewModel: ObservableObject {
    private struct RecoveryState: Equatable {
        let context: AccountUsageOperationGate.Context
    }

    private struct RetirementRuntimeState {
        let isAutoRefreshEnabled: Bool?
    }

    @Published var snapshot: UsageSnapshot?
    @Published var statusMessage: String
    @Published var isFetching: Bool
    @Published var selectedProvider: UsageProvider {
        didSet {
            updateSelectedProviderState()
        }
    }
    @Published private(set) var accountCatalogRevision: UInt64 = 0

    private let accountStore: ProviderAccountStore
    private let snapshotRepository: any AccountUsageSnapshotRepository
    private let usageFetcher: any UsageSnapshotFetching
    private let copilotBillingFetcher: any CopilotBillingFetching
    private let tokenUsageViewModel: TokenUsageViewModel
    private let sessionActivityDataClearer:
        (any SessionActivityDataClearing)?
    private let webViewPool: UsageWebViewPool
    private let displayModeStore: UsageDisplayModeStore
    private let stateManager: ProviderStateManager
    private var autoRefreshCoordinator: AutoRefreshCoordinator?
    private var displayMode: UsageDisplayMode
    private var manualRefreshAccountIDs: Set<UUID> = []
    private var autoRecoveryInFlight: [UUID: RecoveryState] = [:]
    private var lastLoginRedirectAt: [UUID: Date] = [:]
    private var operationGate = AccountUsageOperationGate()
    private var retirementRuntimeStatesByAccountID:
        [UUID: RetirementRuntimeState] = [:]
    private var lifecycleCancellables: Set<AnyCancellable> = []

    init(
        webViewPool: UsageWebViewPool,
        snapshotRepository: (any AccountUsageSnapshotRepository)? = nil,
        usageFetcher: (any UsageSnapshotFetching)? = nil,
        copilotBillingFetcher: (any CopilotBillingFetching)? = nil,
        tokenUsageViewModel: TokenUsageViewModel? = nil,
        sessionActivityDataClearer:
            (any SessionActivityDataClearing)? = nil,
        displayModeStore: UsageDisplayModeStore? = nil,
        stateManager: ProviderStateManager? = nil,
        selectedProvider: UsageProvider = .chatgptCodex
    ) {
        let resolvedRepository = snapshotRepository
            ?? DefaultAccountUsageSnapshotRepository()
        let resolvedDisplayModeStore = displayModeStore
            ?? UsageDisplayModeStore()
        let accounts = webViewPool.accountStore.loadAccounts()
        let resolvedStateManager = stateManager
            ?? ProviderStateManager(accounts: accounts)
        resolvedStateManager.loadCachedSnapshots(
            for: accounts,
            from: resolvedRepository
        )
        let selectedAccount = webViewPool.accountStore.selectedAccount(
            for: selectedProvider
        )
        let selectedState = resolvedStateManager.getState(
            for: selectedAccount.id
        )

        self.accountStore = webViewPool.accountStore
        self.snapshotRepository = resolvedRepository
        self.usageFetcher = usageFetcher ?? DefaultUsageSnapshotFetcher()
        self.copilotBillingFetcher = copilotBillingFetcher
            ?? CopilotBillingFetcher()
        self.tokenUsageViewModel = tokenUsageViewModel
            ?? TokenUsageViewModel(accountStore: webViewPool.accountStore)
        self.sessionActivityDataClearer = sessionActivityDataClearer
        self.webViewPool = webViewPool
        self.displayModeStore = resolvedDisplayModeStore
        self.stateManager = resolvedStateManager
        self.displayMode = resolvedDisplayModeStore
            .loadCachedDisplayMode() ?? .used
        self.selectedProvider = selectedProvider
        self.snapshot = selectedState.snapshot
        self.statusMessage = selectedState.statusMessage
        self.isFetching = selectedState.isFetching

        resolvedStateManager.onStateChange = { [weak self] accountID in
            guard let self else { return }
            self.objectWillChange.send()
            if self.selectedAccount(for: self.selectedProvider).id == accountID {
                self.updateSelectedProviderState()
            }
        }
        webViewPool.webViewStoreRetirementDidBegin
            .sink { [weak self] accountID in
                self?.handleAccountRetirementDidBegin(accountID)
            }
            .store(in: &lifecycleCancellables)
        webViewPool.webViewStoreRetirementDidRestore
            .sink { [weak self] accountID in
                self?.handleAccountRetirementDidRestore(accountID)
            }
            .store(in: &lifecycleCancellables)
        webViewPool.webViewStoreWillRetire
            .sink { [weak self] _ in
                self?.reloadAccounts()
            }
            .store(in: &lifecycleCancellables)

        for provider in UsageProvider.allCases {
            publishSelectedProjection(for: provider)
        }
    }

    // MARK: - Public Accessors

    var snapshots: [UsageProvider: UsageSnapshot] {
        stateManager.selectedSnapshots(
            for: selectedAccountsByProvider
        )
    }

    var snapshotsByAccountID: [UUID: UsageSnapshot] {
        stateManager.snapshotsByAccountID
    }

    var fetchStatuses: [UsageProvider: ProviderFetchStatus] {
        stateManager.selectedFetchStatuses(
            for: selectedAccountsByProvider
        )
    }

    var backgroundActiveAccounts: [ProviderAccount] {
        stateManager.backgroundActiveAccounts
    }

    var accounts: [ProviderAccount] {
        stateManager.accounts
    }

    var webSessionsCanBeManaged: Bool {
        accountStore.supportsPersistentWebSessions
    }

    func accounts(for provider: UsageProvider) -> [ProviderAccount] {
        stateManager.accounts.filter { $0.provider == provider }
    }

    /// Compatibility for provider-only callers. Runtime activation uses the
    /// exact accounts above and never collapses same-provider siblings.
    var backgroundActiveProviders: [UsageProvider] {
        Array(Set(backgroundActiveAccounts.map(\.provider))).sorted {
            $0.rawValue < $1.rawValue
        }
    }

    func hasLoginHistory(for provider: UsageProvider) -> Bool {
        stateManager.hasLoginHistory(
            for: selectedAccount(for: provider).id
        )
    }

    func snapshot(for accountID: UUID) -> UsageSnapshot? {
        stateManager.getState(for: accountID).snapshot
    }

    @discardableResult
    func selectAccount(id: UUID) throws -> ProviderAccount {
        guard let requestedAccount = accountStore.account(id: id) else {
            throw ProviderAccountStoreError.accountNotFound
        }
        let priorAccount = selectedAccount(for: requestedAccount.provider)
        if priorAccount.id != requestedAccount.id {
            // Remove the provider-only compatibility projection before the
            // durable selection changes. A crash can show no widget data, but
            // never the prior account under the new selection.
            try prepareSelectedUsageProjectionRemoval(for: priorAccount)
            do {
                try tokenUsageViewModel.prepareSelectedProjectionRemoval(
                    for: priorAccount
                )
            } catch {
                try? restoreSelectedUsageProjection(for: priorAccount)
                try? tokenUsageViewModel.restoreSelectedProjection(
                    for: priorAccount
                )
                throw error
            }
        }

        let account: ProviderAccount
        do {
            account = try accountStore.selectAccount(id: id)
        } catch {
            if priorAccount.id != requestedAccount.id {
                try? restoreSelectedUsageProjection(for: priorAccount)
                try? tokenUsageViewModel.restoreSelectedProjection(
                    for: priorAccount
                )
            }
            throw error
        }
        synchronizeAccountCatalog()
        completeAccountSelection(account)
        return account
    }

    /// Creates an isolated account and selects it immediately so the login UI
    /// never opens the prior account while presenting the new profile.
    @discardableResult
    func addAndSelectAccount(
        id: UUID = UUID(),
        provider: UsageProvider,
        label: String,
        cliDataRoot: String? = nil
    ) throws -> ProviderAccount {
        let priorAccount = selectedAccount(for: provider)
        if let existing = accountStore.account(id: id) {
            guard existing.provider == provider,
                  existing.webKitStorage == .isolated else {
                throw ProviderAccountStoreError.persistenceFailed
            }
            let proposed = existing.updating(
                label: label,
                isEnabled: true,
                cliDataRoot: cliDataRoot
            )
            try tokenUsageViewModel.prepareCLIDataRootChange(
                from: existing,
                to: proposed
            )
        }
        // Fail before account creation if the old compatibility projection
        // cannot be hidden. Retrying Save can therefore never create a duplicate.
        try prepareSelectedUsageProjectionRemoval(for: priorAccount)
        do {
            try tokenUsageViewModel.prepareSelectedProjectionRemoval(
                for: priorAccount
            )
        } catch {
            try? restoreSelectedUsageProjection(for: priorAccount)
            try? tokenUsageViewModel.restoreSelectedProjection(
                for: priorAccount
            )
            throw error
        }
        do {
            let account = try accountStore.addAndSelectAccount(
                id: id,
                provider: provider,
                label: label,
                cliDataRoot: cliDataRoot
            )
            synchronizeAccountCatalog()
            completeAccountSelection(account)
            return account
        } catch {
            try? restoreSelectedUsageProjection(for: priorAccount)
            try? tokenUsageViewModel.restoreSelectedProjection(
                for: priorAccount
            )
            // An unacknowledged registry write may still contain the exact
            // stable creation UUID. Surface it instead of hiding committed data.
            reloadAccounts()
            throw error
        }
    }

    /// Updates user-editable metadata without allowing the UI to replace an
    /// account's provider, UUID, creation time, or WebKit storage boundary.
    @discardableResult
    func updateAccount(
        id: UUID,
        label: String,
        isEnabled: Bool
    ) throws -> ProviderAccount {
        guard let current = accountStore.account(id: id) else {
            throw ProviderAccountStoreError.accountNotFound
        }
        return try updateAccount(
            id: id,
            label: label,
            isEnabled: isEnabled,
            cliDataRoot: current.cliDataRoot
        )
    }

    /// Updates account metadata including the local CLI data directory. The
    /// path is configuration only; AgentLimits never deletes that directory.
    @discardableResult
    func updateAccount(
        id: UUID,
        label: String,
        isEnabled: Bool,
        cliDataRoot: String?
    ) throws -> ProviderAccount {
        guard let current = accountStore.account(id: id) else {
            throw ProviderAccountStoreError.accountNotFound
        }
        let proposed = current.updating(
            label: label,
            isEnabled: isEnabled,
            cliDataRoot: cliDataRoot
        )
        try tokenUsageViewModel.prepareCLIDataRootChange(
            from: current,
            to: proposed
        )
        try accountStore.updateAccount(proposed)
        reloadAccounts()
        guard let updated = stateManager.account(id: id) else {
            throw ProviderAccountStoreError.accountNotFound
        }
        return updated
    }

    /// Refreshes account metadata and loads state only for newly added IDs.
    func reloadAccounts() {
        let oldAccounts = Dictionary(
            uniqueKeysWithValues: stateManager.accounts.map { ($0.id, $0) }
        )
        synchronizeAccountCatalog()
        let newIDs = stateManager.accountIDs
        for removedID in Set(oldAccounts.keys).subtracting(newIDs) {
            operationGate.invalidate(scope: removedID)
            manualRefreshAccountIDs.remove(removedID)
            autoRecoveryInFlight.removeValue(forKey: removedID)
            lastLoginRedirectAt.removeValue(forKey: removedID)
        }
        let affectedProviders = Set(
            oldAccounts.values
                .filter { !newIDs.contains($0.id) }
                .map(\.provider)
        )
        for provider in affectedProviders {
            publishSelectedProjection(for: provider)
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
        }
        accountCatalogRevision &+= 1
        updateSelectedProviderState()
    }

    /// Used by popup auto-close. The result remains valid only while the same
    /// exact account is selected.
    func checkLoginStatus(for provider: UsageProvider) async -> Bool {
        await checkLoginStatus(
            using: webViewPool.getWebViewStore(for: provider)
        )
    }

    func checkLoginStatus(using webViewStore: WebViewStore) async -> Bool {
        let account = webViewStore.account
        guard let context = operationGate.captureContext(for: account.id),
              isCurrentSelectedStore(webViewStore) else { return false }
        let isLoggedIn = await usageFetcher.hasValidSession(
            for: account.provider,
            using: webViewStore.webView
        )
        guard operationGate.isCurrent(context),
              isCurrentSelectedStore(webViewStore) else { return false }
        return isLoggedIn
    }

    // MARK: - Refresh Lifecycle

    func startAutoRefresh() {
        guard autoRefreshCoordinator == nil else { return }
        autoRefreshCoordinator = AutoRefreshCoordinator(
            intervalProvider: { UsageRefreshConfig.refreshIntervalDuration },
            refreshHandler: { [weak self] in
                await self?.refreshAutoEligibleAccounts()
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

    func refreshNow(for provider: UsageProvider) async {
        let account = selectedAccount(for: provider)
        await refreshSnapshot(
            for: account,
            using: webViewPool.getWebViewStore(for: account)
        )
    }

    func fetchNow() {
        let account = selectedAccount(for: selectedProvider)
        let webViewStore = webViewPool.getWebViewStore(for: account)
        guard let context = operationGate.captureContext(for: account.id),
              isCurrentSelectedStore(webViewStore) else { return }
        manualRefreshAccountIDs.insert(account.id)
        if isUsageURL(webViewStore.webView.url, provider: account.provider),
           webViewStore.isPageReady {
            _ = consumeManualRefreshRequest(for: webViewStore)
            Task {
                await handleLoginAndFetch(
                    using: webViewStore,
                    context: context
                )
            }
        } else {
            webViewPool.reloadFromOrigin(account)
        }
    }

    // MARK: - Selected Projection

    func updateSelectedProviderState() {
        let state = stateManager.getState(
            for: selectedAccount(for: selectedProvider).id
        )
        snapshot = state.snapshot
        statusMessage = state.statusMessage
        isFetching = state.isFetching
    }

    func updateDisplayMode(_ displayMode: UsageDisplayMode) {
        let normalizedMode = displayMode.normalizedSelectableMode
        self.displayMode = normalizedMode

        for account in stateManager.accounts {
            guard let currentSnapshot = stateManager
                .getState(for: account.id).snapshot else { continue }
            let convertedSnapshot = currentSnapshot.makeSnapshot(
                for: normalizedMode
            )
            do {
                try snapshotRepository.saveSnapshot(
                    convertedSnapshot,
                    for: account
                )
                stateManager.setSnapshot(
                    convertedSnapshot,
                    for: account.id
                )
            } catch {
                Logger.usage.error(
                    "Could not persist account display mode: \(String(describing: error))"
                )
            }
        }
        displayModeStore.saveCachedDisplayMode(normalizedMode)
        for provider in UsageProvider.allCases {
            publishSelectedProjection(for: provider)
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
        }
        updateSelectedProviderState()
    }

    // MARK: - Clear Data

    func clearData() async throws {
        guard let clearToken = operationGate.beginClear() else { return }
        // beginClear invalidates every fetch immediately. Clear its UI state
        // even when another subsystem's exclusive clear cannot be acquired.
        for account in stateManager.accounts {
            stateManager.setFetching(false, for: account.id)
        }
        guard let webViewClearToken = webViewPool.beginDataClear() else {
            _ = operationGate.finishClear(clearToken)
            throw ClearDataError.websiteData(
                "Another website-data clear is already active."
            )
        }
        guard let tokenDataClearToken = tokenUsageViewModel.beginDataClear() else {
            _ = webViewPool.cancelDataClear(webViewClearToken)
            _ = operationGate.finishClear(clearToken)
            throw ClearDataError.websiteData(
                "Another token-data clear is already active."
            )
        }
        let activityDataClearToken: SessionActivityDataClearToken?
        if let sessionActivityDataClearer {
            guard let token = sessionActivityDataClearer
                .beginActivityDataClear() else {
                _ = tokenUsageViewModel.finishDataClear(tokenDataClearToken)
                _ = webViewPool.cancelDataClear(webViewClearToken)
                _ = operationGate.finishClear(clearToken)
                throw ClearDataError.activityData(
                    "Another session-activity clear is already active."
                )
            }
            activityDataClearToken = token
        } else {
            activityDataClearToken = nil
        }
        var didFinishWebsiteDataClear = false
        defer {
            if !didFinishWebsiteDataClear {
                _ = webViewPool.cancelDataClear(webViewClearToken)
            }
            if let activityDataClearToken {
                _ = sessionActivityDataClearer?.finishActivityDataClear(
                    activityDataClearToken
                )
            }
            _ = tokenUsageViewModel.finishDataClear(tokenDataClearToken)
            _ = operationGate.finishClear(clearToken)
        }

        manualRefreshAccountIDs.removeAll()
        autoRecoveryInFlight.removeAll()
        lastLoginRedirectAt.removeAll()

        var deletionFailuresByIdentifier:
            [String: ClearDataDeletionFailure] = [:]
        var processedAccountIDs: Set<UUID> = []
        var didClearActivityData = activityDataClearToken == nil

        // Repeat because account registration can occur from another window
        // during either the WebKit clear or a synchronous deletion callback.
        while true {
            do {
                try await ensureWebsiteDataClearCoverage(webViewClearToken)
            } catch {
                throw ClearDataError.websiteData(error.localizedDescription)
            }
            if !didClearActivityData,
               let activityDataClearToken,
               let sessionActivityDataClearer {
                do {
                    try sessionActivityDataClearer.clearAllActivityData(
                        during: activityDataClearToken
                    )
                    didClearActivityData = true
                } catch {
                    throw ClearDataError.activityData(
                        error.localizedDescription
                    )
                }
            }

            let accounts = accountStore.loadAccounts()
            stateManager.synchronizeAccounts(accounts)
            let pendingAccounts = accounts.filter {
                !processedAccountIDs.contains($0.id)
            }
            guard !pendingAccounts.isEmpty else { break }

            for account in pendingAccounts {
                processedAccountIDs.insert(account.id)
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
                    deletionFailuresByIdentifier.removeValue(
                        forKey: "usage-account-\(account.id.uuidString)"
                    )
                } catch {
                    let failure = ClearDataDeletionFailure(
                            target: "\(account.provider.displayName) — \(account.label)",
                            reason: error.localizedDescription,
                            identifier: "usage-account-\(account.id.uuidString)"
                    )
                    deletionFailuresByIdentifier[failure.identifier] = failure
                }
                stateManager.clearLoginHistory(for: account.id)
            }
        }

        for failure in tokenUsageViewModel.clearAllSnapshots(
            during: tokenDataClearToken
        ) {
            let deletionFailure = ClearDataDeletionFailure(
                    target: failure.targetDescription,
                    reason: failure.reason,
                    identifier: failure.isSelectedProjection
                        ? "token-projection-\(failure.provider.rawValue)"
                        : "token-account-\(failure.accountID?.uuidString ?? "unknown")"
            )
            deletionFailuresByIdentifier[deletionFailure.identifier] =
                deletionFailure
        }

        // Clear provider-only widget compatibility projections after every
        // account namespace is hidden or deleted.
        for provider in UsageProvider.allCases {
            let account = selectedAccount(for: provider)
            do {
                try snapshotRepository.publishSelectedSnapshot(
                    nil,
                    for: account
                )
                deletionFailuresByIdentifier.removeValue(
                    forKey: "usage-projection-\(provider.rawValue)"
                )
            } catch {
                let failure = ClearDataDeletionFailure(
                        target: "\(provider.displayName) widget",
                        reason: error.localizedDescription,
                        identifier: "usage-projection-\(provider.rawValue)"
                )
                deletionFailuresByIdentifier[failure.identifier] = failure
            }
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
        }

        // Token/projection hooks are synchronous, but one last pass protects
        // accounts registered by those hooks before navigation is released.
        while true {
            do {
                try await ensureWebsiteDataClearCoverage(webViewClearToken)
            } catch {
                throw ClearDataError.websiteData(error.localizedDescription)
            }
            let catalog = accountStore.loadAccounts()
            stateManager.synchronizeAccounts(catalog)
            let newAccounts = catalog.filter {
                !processedAccountIDs.contains($0.id)
            }
            for account in newAccounts {
                processedAccountIDs.insert(account.id)
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
                    deletionFailuresByIdentifier.removeValue(
                        forKey: "usage-account-\(account.id.uuidString)"
                    )
                } catch {
                    let failure = ClearDataDeletionFailure(
                            target: "\(account.provider.displayName) — \(account.label)",
                            reason: error.localizedDescription,
                            identifier: "usage-account-\(account.id.uuidString)"
                    )
                    deletionFailuresByIdentifier[failure.identifier] = failure
                }
                stateManager.clearLoginHistory(for: account.id)
            }
            for provider in TokenUsageProvider.allCases {
                deletionFailuresByIdentifier.removeValue(
                    forKey: "token-projection-\(provider.rawValue)"
                )
            }
            for account in newAccounts
                where account.provider.tokenUsageProvider != nil {
                deletionFailuresByIdentifier.removeValue(
                    forKey: "token-account-\(account.id.uuidString)"
                )
            }
            for failure in tokenUsageViewModel.clearLateRegisteredAccounts(
                newAccounts,
                during: tokenDataClearToken
            ) {
                let deletionFailure = ClearDataDeletionFailure(
                        target: failure.targetDescription,
                        reason: failure.reason,
                        identifier: failure.isSelectedProjection
                            ? "token-projection-\(failure.provider.rawValue)"
                            : "token-account-\(failure.accountID?.uuidString ?? "unknown")"
                )
                deletionFailuresByIdentifier[deletionFailure.identifier] =
                    deletionFailure
            }
            // A late add/select can republish provider facades. Clear them in
            // the same synchronous convergence pass; callbacks are detected
            // as new accounts on the next iteration.
            for provider in UsageProvider.allCases {
                let account = selectedAccount(for: provider)
                do {
                    try snapshotRepository.publishSelectedSnapshot(
                        nil,
                        for: account
                    )
                    deletionFailuresByIdentifier.removeValue(
                        forKey: "usage-projection-\(provider.rawValue)"
                    )
                } catch {
                    let failure = ClearDataDeletionFailure(
                            target: "\(provider.displayName) widget",
                            reason: error.localizedDescription,
                            identifier: "usage-projection-\(provider.rawValue)"
                    )
                    deletionFailuresByIdentifier[failure.identifier] = failure
                }
                WidgetCenter.shared.reloadTimelines(
                    ofKind: provider.widgetKind
                )
            }
            let hasUnprocessedAccounts = accountStore.loadAccounts().contains {
                !processedAccountIDs.contains($0.id)
            }
            if !hasUnprocessedAccounts,
               webViewPool.isWebsiteDataClearComplete(webViewClearToken) {
                break
            }
        }

        updateSelectedProviderState()
        webViewPool.applyBackgroundPolicy(
            activeAccounts: backgroundActiveAccounts
        )
        guard webViewPool.finishDataClear(webViewClearToken) else {
            throw ClearDataError.websiteData(
                "Website-data coverage changed before the clear could finish."
            )
        }
        didFinishWebsiteDataClear = true

        let uniqueDeletionFailures = deletionFailuresByIdentifier
            .sorted { $0.key < $1.key }
            .map(\.value)
        if !uniqueDeletionFailures.isEmpty {
            let error = ClearDataError.snapshotDeletion(
                uniqueDeletionFailures
            )
            Logger.usage.error(
                "Clear Data snapshot deletion failed: \(error.localizedDescription)"
            )
            throw error
        }
    }

    private func ensureWebsiteDataClearCoverage(
        _ token: UsageWebViewPool.DataClearToken
    ) async throws {
        while !webViewPool.isWebsiteDataClearComplete(token) {
            try await webViewPool.clearWebsiteData(token)
        }
    }

    // MARK: - WebView Events

    func handlePageReadyChange(
        for webViewStore: WebViewStore,
        isReady: Bool
    ) {
        guard isReady, webViewPool.isActive(webViewStore) else { return }
        let account = webViewStore.account
        guard let context = operationGate.captureContext(for: account.id),
              !isRecoveryInFlight(accountID: account.id) else { return }

        let isManualRefresh = consumeManualRefreshRequest(for: webViewStore)
        let state = stateManager.getState(for: account.id)
        if !isManualRefresh {
            guard state.isAutoRefreshEnabled != true else { return }
        }
        guard !state.isFetching else { return }
        Task {
            await handleLoginAndFetch(
                using: webViewStore,
                context: context
            )
        }
    }

    func handleCookieChange(for webViewStore: WebViewStore) {
        guard webViewPool.isActive(webViewStore) else { return }
        let account = webViewStore.account
        guard account.provider == .claudeCode
                || account.provider == .githubCopilot,
              let context = operationGate.captureContext(for: account.id) else {
            return
        }
        Task {
            let isLoggedIn = await usageFetcher.hasValidSession(
                for: account.provider,
                using: webViewStore.webView
            )
            guard operationGate.isCurrent(context),
                  webViewPool.isActive(webViewStore),
                  isLoggedIn,
                  !isUsageURL(
                    webViewStore.webView.url,
                    provider: account.provider
                  ),
                  canRedirectLogin(for: account.id) else { return }
            webViewPool.reloadFromOrigin(account)
        }
    }

    private func refreshAutoEligibleAccounts() async {
        synchronizeAccountCatalog()
        let selectedIDs = Set(
            UsageProvider.allCases.map { selectedAccount(for: $0).id }
        )
        let accounts = stateManager.autoRefreshEligibleAccounts(
            selectedAccountIDs: selectedIDs
        )
        for account in accounts {
            guard let context = operationGate.captureContext(for: account.id)
            else { return }
            let webViewStore = webViewPool.getWebViewStore(for: account)
            guard webViewPool.isAvailable(webViewStore),
                  !isRecoveryInFlight(accountID: account.id) else { continue }
            await refreshSnapshot(
                for: account,
                using: webViewStore,
                context: context
            )
        }
    }

    private func refreshSnapshot(
        for account: ProviderAccount,
        using webViewStore: WebViewStore,
        context: AccountUsageOperationGate.Context? = nil
    ) async {
        guard let operationContext = context
                ?? operationGate.captureContext(for: account.id),
              operationGate.isCurrent(operationContext),
              webViewStore.account.id == account.id,
              webViewStore.account.provider == account.provider,
              webViewPool.isAvailable(webViewStore) else { return }
        guard webViewStore.isPageReady else {
            stateManager.setStatusMessage(
                "status.loadingLogin".localized(),
                for: account.id
            )
            return
        }
        guard let fetchToken = operationGate.beginFetch(
            for: account.id,
            context: operationContext
        ) else { return }

        stateManager.setFetching(true, for: account.id)
        defer {
            if operationGate.finishFetch(fetchToken) {
                stateManager.setFetching(false, for: account.id)
            }
        }

        do {
            let fetchedSnapshot = try await usageFetcher.fetchSnapshot(
                for: account.provider,
                using: webViewStore.webView
            )
            guard operationGate.isCurrent(fetchToken),
                  webViewPool.isAvailable(webViewStore) else { return }
            let snapshotToSave = fetchedSnapshot.makeSnapshot(for: displayMode)
            try snapshotRepository.saveSnapshot(snapshotToSave, for: account)
            guard operationGate.isCurrent(fetchToken),
                  webViewPool.isAvailable(webViewStore) else { return }

            displayModeStore.saveCachedDisplayMode(displayMode)
            stateManager.updateAfterSuccessfulFetch(
                snapshot: snapshotToSave,
                for: account.id
            )
            clearRecovery(
                accountID: account.id,
                context: operationContext
            )
            stateManager.setStatusMessage(
                "status.updated".localized(),
                for: account.id
            )
            webViewPool.applyBackgroundPolicy(
                activeAccounts: backgroundActiveAccounts
            )

            if isCurrentSelectedStore(webViewStore) {
                do {
                    try snapshotRepository.publishSelectedSnapshot(
                        snapshotToSave,
                        for: account
                    )
                    WidgetCenter.shared.reloadTimelines(
                        ofKind: account.provider.widgetKind
                    )
                } catch {
                    WidgetCenter.shared.reloadTimelines(
                        ofKind: account.provider.widgetKind
                    )
                    Logger.usage.error(
                        "Could not publish selected account snapshot: \(String(describing: error))"
                    )
                }

                await ThresholdNotificationManager.shared
                    .checkThresholdsIfNeeded(
                        for: fetchedSnapshot,
                        isCurrent: { [weak self, weak webViewStore] in
                            guard let self, let webViewStore else { return false }
                            return self.operationGate.isCurrent(fetchToken)
                                && self.isCurrentSelectedStore(webViewStore)
                        }
                    )
            }
            guard operationGate.isCurrent(fetchToken),
                  webViewPool.isAvailable(webViewStore) else { return }

            if account.provider == .githubCopilot,
               let billingContext = operationGate.captureContext(
                for: account.id
               ),
               let tokenContext = tokenUsageViewModel
                .captureExternalSnapshotContext(for: account) {
                Task {
                    await fetchCopilotBilling(
                        using: webViewStore,
                        context: billingContext,
                        tokenUsageContext: tokenContext
                    )
                }
            }
        } catch {
            guard operationGate.isCurrent(fetchToken),
                  webViewPool.isAvailable(webViewStore) else { return }
            if shouldDisableAutoRefresh(
                for: account.provider,
                error: error
            ) {
                if isRecoveryInFlight(accountID: account.id) {
                    clearRecovery(
                        accountID: account.id,
                        context: operationContext
                    )
                    stateManager.setAutoRefreshEnabled(
                        false,
                        for: account.id
                    )
                } else {
                    let recoveryState = RecoveryState(
                        context: operationContext
                    )
                    autoRecoveryInFlight[account.id] = recoveryState
                    await clearOrgIDCookie(
                        in: webViewStore,
                        context: operationContext
                    )
                    guard operationGate.isCurrent(fetchToken),
                          webViewPool.isActive(webViewStore),
                          autoRecoveryInFlight[account.id] == recoveryState else {
                        clearRecovery(
                            accountID: account.id,
                            context: operationContext
                        )
                        return
                    }
                    webViewPool.reloadFromOrigin(account)
                    stateManager.setStatusMessage(
                        "status.loadingLogin".localized(),
                        for: account.id
                    )
                    Task { [weak self] in
                        await self?.waitForRecoveryFetch(
                            using: webViewStore,
                            context: operationContext
                        )
                    }
                    return
                }
            }
            stateManager.setFetchStatus(
                .failure(error.localizedDescription),
                for: account.id
            )
            stateManager.setStatusMessage(
                error.localizedDescription,
                for: account.id
            )
        }
    }

    private func handleLoginAndFetch(
        using webViewStore: WebViewStore,
        context: AccountUsageOperationGate.Context
    ) async {
        let account = webViewStore.account
        guard operationGate.isCurrent(context),
              webViewPool.isAvailable(webViewStore) else { return }
        let isLoggedIn = await usageFetcher.hasValidSession(
            for: account.provider,
            using: webViewStore.webView
        )
        guard operationGate.isCurrent(context),
              webViewPool.isAvailable(webViewStore) else { return }
        guard isLoggedIn else {
            stateManager.setStatusMessage(
                "status.loadingLogin".localized(),
                for: account.id
            )
            return
        }
        guard isUsageURL(
            webViewStore.webView.url,
            provider: account.provider
        ) else {
            webViewPool.reloadFromOrigin(account)
            return
        }
        await refreshSnapshot(
            for: account,
            using: webViewStore,
            context: context
        )
    }

    // MARK: - Recovery

    private func waitForRecoveryFetch(
        using webViewStore: WebViewStore,
        context: AccountUsageOperationGate.Context
    ) async {
        let account = webViewStore.account
        let recoveryState = RecoveryState(context: context)
        guard isCurrentRecovery(
            recoveryState,
            accountID: account.id,
            webViewStore: webViewStore
        ) else {
            clearRecovery(accountID: account.id, context: context)
            return
        }

        let deadline = Date().addingTimeInterval(15)
        while !webViewStore.isPageReady && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            guard isCurrentRecovery(
                recoveryState,
                accountID: account.id,
                webViewStore: webViewStore
            ) else {
                clearRecovery(accountID: account.id, context: context)
                return
            }
        }
        guard webViewStore.isPageReady else {
            clearRecovery(accountID: account.id, context: context)
            return
        }
        try? await Task.sleep(for: .seconds(3))
        guard isCurrentRecovery(
            recoveryState,
            accountID: account.id,
            webViewStore: webViewStore
        ) else {
            clearRecovery(accountID: account.id, context: context)
            return
        }
        await handleLoginAndFetch(using: webViewStore, context: context)
        clearRecovery(accountID: account.id, context: context)
    }

    private func clearOrgIDCookie(
        in webViewStore: WebViewStore,
        context: AccountUsageOperationGate.Context
    ) async {
        guard webViewStore.provider == .claudeCode,
              operationGate.isCurrent(context),
              webViewPool.isActive(webViewStore) else { return }
        let cookieStore = webViewStore.websiteDataStore.httpCookieStore
        let cookies = await cookieStore.allCookies()
        guard operationGate.isCurrent(context),
              webViewPool.isActive(webViewStore) else { return }
        for cookie in cookies where cookie.name == "lastActiveOrg" {
            await cookieStore.deleteCookie(cookie)
            guard operationGate.isCurrent(context),
                  webViewPool.isActive(webViewStore) else { return }
        }
    }

    private func isRecoveryInFlight(accountID: UUID) -> Bool {
        guard let state = autoRecoveryInFlight[accountID] else { return false }
        guard operationGate.isCurrent(state.context),
              stateManager.account(id: accountID) != nil else {
            if autoRecoveryInFlight[accountID] == state {
                autoRecoveryInFlight.removeValue(forKey: accountID)
            }
            return false
        }
        return true
    }

    private func isCurrentRecovery(
        _ state: RecoveryState,
        accountID: UUID,
        webViewStore: WebViewStore
    ) -> Bool {
        operationGate.isCurrent(state.context)
            && autoRecoveryInFlight[accountID] == state
            && webViewPool.isActive(webViewStore)
    }

    private func clearRecovery(
        accountID: UUID,
        context: AccountUsageOperationGate.Context
    ) {
        let expected = RecoveryState(context: context)
        guard autoRecoveryInFlight[accountID] == expected else { return }
        autoRecoveryInFlight.removeValue(forKey: accountID)
    }

    // MARK: - Copilot Billing

    private func fetchCopilotBilling(
        using webViewStore: WebViewStore,
        context: AccountUsageOperationGate.Context,
        tokenUsageContext: TokenUsageViewModel.ExternalSnapshotContext
    ) async {
        guard operationGate.isCurrent(context),
              webViewPool.isAvailable(webViewStore) else { return }
        do {
            let snapshot = try await copilotBillingFetcher
                .fetchBillingSnapshot(using: webViewStore.webView)
            guard operationGate.isCurrent(context),
                  webViewPool.isAvailable(webViewStore) else { return }
            try tokenUsageViewModel.saveExternallyFetchedSnapshot(
                snapshot,
                context: tokenUsageContext
            )
        } catch {
            guard operationGate.isCurrent(context),
                  webViewPool.isAvailable(webViewStore) else { return }
            Logger.usage.error(
                "Copilot billing fetch failed: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Helpers

    private var selectedAccountsByProvider: [UsageProvider: ProviderAccount] {
        Dictionary(
            uniqueKeysWithValues: UsageProvider.allCases.map {
                ($0, selectedAccount(for: $0))
            }
        )
    }

    func selectedAccount(
        for provider: UsageProvider
    ) -> ProviderAccount {
        accountStore.selectedAccount(for: provider)
    }

    private func synchronizeAccountCatalog() {
        let currentIDs = stateManager.accountIDs
        let accounts = accountStore.loadAccounts()
        let incomingIDs = Set(accounts.map(\.id))
        for removedID in currentIDs.subtracting(incomingIDs) {
            operationGate.invalidate(scope: removedID)
            retirementRuntimeStatesByAccountID.removeValue(forKey: removedID)
            manualRefreshAccountIDs.remove(removedID)
            autoRecoveryInFlight.removeValue(forKey: removedID)
            lastLoginRedirectAt.removeValue(forKey: removedID)
        }
        stateManager.synchronizeAccounts(accounts)
        for account in accounts where !currentIDs.contains(account.id) {
            stateManager.setState(
                .initial(
                    snapshot: snapshotRepository.loadSnapshot(for: account)
                ),
                for: account.id
            )
        }
        webViewPool.applyBackgroundPolicy(
            activeAccounts: stateManager.backgroundActiveAccounts
        )
        tokenUsageViewModel.reloadAccounts()
    }

    private func publishSelectedProjection(for provider: UsageProvider) {
        let account = selectedAccount(for: provider)
        let selectedSnapshot = stateManager.getState(
            for: account.id
        ).snapshot
        guard snapshotRepository.canSafelyMutateSelectedProjection(
            for: account
        ) else {
            do {
                try snapshotRepository.setSelectedProjectionSuppressed(
                    true,
                    for: account
                )
            } catch {
                Logger.usage.error(
                    "Could not quarantine selected projection: \(String(describing: error))"
                )
            }
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
            return
        }
        do {
            try snapshotRepository.publishSelectedSnapshot(
                selectedSnapshot,
                for: account
            )
        } catch {
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
            Logger.usage.error(
                "Could not update selected account projection: \(String(describing: error))"
            )
        }
    }

    private func prepareSelectedUsageProjectionRemoval(
        for account: ProviderAccount
    ) throws {
        guard snapshotRepository.canSafelyMutateSelectedProjection(
            for: account
        ) else {
            try snapshotRepository.setSelectedProjectionSuppressed(
                true,
                for: account
            )
            WidgetCenter.shared.reloadTimelines(
                ofKind: account.provider.widgetKind
            )
            throw AccountUsageSnapshotRepositoryError.indeterminateSnapshot(
                provider: account.provider,
                accountLabel: account.label
            )
        }
        try snapshotRepository.publishSelectedSnapshot(nil, for: account)
    }

    private func restoreSelectedUsageProjection(
        for account: ProviderAccount
    ) throws {
        guard selectedAccount(for: account.provider).id == account.id else {
            return
        }
        let selectedSnapshot = stateManager.getState(
            for: account.id
        ).snapshot
        guard snapshotRepository.canSafelyMutateSelectedProjection(
            for: account
        ) else {
            try snapshotRepository.setSelectedProjectionSuppressed(
                true,
                for: account
            )
            WidgetCenter.shared.reloadTimelines(
                ofKind: account.provider.widgetKind
            )
            return
        }
        try snapshotRepository.publishSelectedSnapshot(
            selectedSnapshot,
            for: account
        )
        WidgetCenter.shared.reloadTimelines(ofKind: account.provider.widgetKind)
    }

    private func completeAccountSelection(_ account: ProviderAccount) {
        publishSelectedProjection(for: account.provider)
        accountCatalogRevision &+= 1
        WidgetCenter.shared.reloadTimelines(ofKind: account.provider.widgetKind)
        if account.provider == selectedProvider {
            updateSelectedProviderState()
            webViewPool.resume(account)
        }
    }

    private func handleAccountRetirementDidBegin(_ accountID: UUID) {
        let retiringProvider = stateManager.account(id: accountID)?.provider
        if stateManager.account(id: accountID) != nil {
            retirementRuntimeStatesByAccountID[accountID] =
                RetirementRuntimeState(
                    isAutoRefreshEnabled: stateManager.getState(
                        for: accountID
                    ).isAutoRefreshEnabled
                )
        }
        operationGate.invalidate(scope: accountID)
        tokenUsageViewModel.invalidateAccount(id: accountID)
        tokenUsageViewModel.reloadAccounts()
        manualRefreshAccountIDs.remove(accountID)
        autoRecoveryInFlight.removeValue(forKey: accountID)
        lastLoginRedirectAt.removeValue(forKey: accountID)
        if stateManager.account(id: accountID) != nil {
            stateManager.clearLoginHistory(for: accountID)
        }
        if let retiringProvider {
            publishSelectedProjection(for: retiringProvider)
            WidgetCenter.shared.reloadTimelines(
                ofKind: retiringProvider.widgetKind
            )
        }
    }

    private func handleAccountRetirementDidRestore(_ accountID: UUID) {
        let retirementState = retirementRuntimeStatesByAccountID.removeValue(
            forKey: accountID
        )
        guard let account = accountStore.account(id: accountID),
              stateManager.account(id: accountID) != nil else { return }
        var restoredState = ProviderState.initial(
            snapshot: snapshotRepository.loadSnapshot(for: account)
        )
        if let retirementState {
            restoredState.isAutoRefreshEnabled =
                retirementState.isAutoRefreshEnabled
        }
        stateManager.setState(
            restoredState,
            for: accountID
        )
        tokenUsageViewModel.restoreAccountAfterRetirementCancellation(
            id: accountID
        )
        publishSelectedProjection(for: account.provider)
        WidgetCenter.shared.reloadTimelines(ofKind: account.provider.widgetKind)
        updateSelectedProviderState()
        webViewPool.applyBackgroundPolicy(
            activeAccounts: stateManager.backgroundActiveAccounts
        )
    }

    private func isUsageURL(
        _ url: URL?,
        provider: UsageProvider
    ) -> Bool {
        guard let url else { return false }
        let usageURL = provider.usageURL
        return url.scheme == usageURL.scheme
            && url.host == usageURL.host
            && url.path == usageURL.path
    }

    private func isCurrentSelectedStore(
        _ webViewStore: WebViewStore
    ) -> Bool {
        webViewPool.isAvailable(webViewStore)
            && webViewPool.isSelectedAccount(
                webViewStore.account.id,
                for: webViewStore.provider
            )
    }

    private func consumeManualRefreshRequest(
        for webViewStore: WebViewStore
    ) -> Bool {
        manualRefreshAccountIDs.remove(webViewStore.account.id) != nil
    }

    private func canRedirectLogin(for accountID: UUID) -> Bool {
        let now = Date()
        if let lastRedirectAt = lastLoginRedirectAt[accountID],
           now.timeIntervalSince(lastRedirectAt) < 5 {
            return false
        }
        lastLoginRedirectAt[accountID] = now
        return true
    }

    private func shouldDisableAutoRefresh(
        for provider: UsageProvider,
        error: Error
    ) -> Bool {
        switch provider {
        case .chatgptCodex:
            guard let error = error as? CodexUsageFetcherError else {
                return false
            }
            switch error {
            case .scriptFailed(let message):
                return isLoginRequiredMessage(message)
            case .invalidResponse, .pageNotReady:
                return false
            }
        case .claudeCode:
            guard let error = error as? ClaudeUsageFetcherError else {
                return false
            }
            switch error {
            case .missingOrganization:
                return true
            case .scriptFailed(let message):
                return isLoginRequiredMessage(message)
            case .invalidResponse:
                return false
            }
        case .githubCopilot:
            guard let error = error as? CopilotUsageFetcherError else {
                return false
            }
            switch error {
            case .scriptFailed(let message):
                return isLoginRequiredMessage(message)
            case .invalidResponse, .pageNotReady:
                return false
            }
        }
    }

    private func isLoginRequiredMessage(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("missing access token")
            || normalized.contains("missing organization")
            || normalized.contains("unauthorized")
            || normalized.contains("http 401")
            || normalized.contains("http 403")
    }
}
