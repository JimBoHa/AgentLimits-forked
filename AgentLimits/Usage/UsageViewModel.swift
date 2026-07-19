// MARK: - UsageViewModel.swift
// Central state management for usage data fetching and auto-refresh.
// Coordinates WebView login detection, API fetching, and widget updates.

import Combine
import Foundation
import OSLog
import WebKit
import WidgetKit

protocol UsageSnapshotStoring {
    func loadSnapshot(for provider: UsageProvider) -> UsageSnapshot?
    func saveSnapshot(_ snapshot: UsageSnapshot) throws
    func deleteSnapshot(for provider: UsageProvider) throws
}

extension AppGroupSnapshotStore: UsageSnapshotStoring
    where Provider == UsageProvider, Snapshot == UsageSnapshot {}

struct ClearDataDeletionFailure {
    let target: String
    let reason: String
}

enum ClearDataError: LocalizedError {
    case websiteData(String)
    case snapshotDeletion([ClearDataDeletionFailure])

    var errorDescription: String? {
        switch self {
        case .websiteData(let reason):
            return reason
        case .snapshotDeletion(let failures):
            return failures
                .map { "\($0.target): \($0.reason)" }
                .joined(separator: "; ")
        }
    }
}

// MARK: - Usage View Model

/// Main view model managing usage data state, auto-refresh, and provider switching.
/// Coordinates between WebViews, fetchers, and the snapshot store.
/// Uses ProviderStateManager for per-provider state management.
@MainActor
final class UsageViewModel: ObservableObject {
    private struct RecoveryState: Equatable {
        let accountID: UUID
        let context: UsageOperationGate.Context
    }

    @Published var snapshot: UsageSnapshot?
    @Published var statusMessage: String
    @Published var isFetching: Bool
    @Published var selectedProvider: UsageProvider {
        didSet {
            updateSelectedProviderState()
        }
    }

    private let store: any UsageSnapshotStoring
    private let codexFetcher: CodexUsageFetcher
    private let claudeFetcher: ClaudeUsageFetcher
    private let copilotFetcher: CopilotUsageFetcher
    private let copilotBillingFetcher: CopilotBillingFetcher
    private let tokenUsageViewModel: TokenUsageViewModel
    private let webViewPool: UsageWebViewPool
    private let displayModeStore: UsageDisplayModeStore
    private let stateManager: ProviderStateManager
    private let snapshotVisibilityStore: any SnapshotVisibilityControlling
    private var autoRefreshCoordinator: AutoRefreshCoordinator?
    private var displayMode: UsageDisplayMode = .used
    private var manualRefreshAccountIDByProvider: [UsageProvider: UUID] = [:]
    private var autoRecoveryInFlight: [UsageProvider: RecoveryState] = [:]
    private var lastLoginRedirectAt: [UUID: Date] = [:]
    private var operationGate = UsageOperationGate()

    init(
        webViewPool: UsageWebViewPool,
        store: (any UsageSnapshotStoring)? = nil,
        codexFetcher: CodexUsageFetcher? = nil,
        claudeFetcher: ClaudeUsageFetcher? = nil,
        copilotFetcher: CopilotUsageFetcher? = nil,
        tokenUsageViewModel: TokenUsageViewModel? = nil,
        displayModeStore: UsageDisplayModeStore? = nil,
        stateManager: ProviderStateManager? = nil,
        snapshotVisibilityStore: (any SnapshotVisibilityControlling)? = nil,
        selectedProvider: UsageProvider = .chatgptCodex
    ) {
        let useStore = store ?? UsageSnapshotStore.shared
        let useDisplayModeStore = displayModeStore ?? UsageDisplayModeStore()
        let useCodexFetcher = codexFetcher ?? CodexUsageFetcher()
        let useClaudeFetcher = claudeFetcher ?? ClaudeUsageFetcher()
        let useCopilotFetcher = copilotFetcher ?? CopilotUsageFetcher()
        let useStateManager = stateManager ?? ProviderStateManager()
        // Load cached snapshots into state manager
        let useSnapshotVisibilityStore = snapshotVisibilityStore ?? SnapshotVisibilityStore.shared
        useStateManager.loadCachedSnapshots(
            from: useStore,
            snapshotVisibilityStore: useSnapshotVisibilityStore
        )

        let selectedState = useStateManager.getState(for: selectedProvider)

        self.webViewPool = webViewPool
        self.store = useStore
        self.codexFetcher = useCodexFetcher
        self.claudeFetcher = useClaudeFetcher
        self.copilotFetcher = useCopilotFetcher
        self.copilotBillingFetcher = CopilotBillingFetcher()
        self.tokenUsageViewModel = tokenUsageViewModel ?? TokenUsageViewModel()
        self.displayModeStore = useDisplayModeStore
        self.stateManager = useStateManager
        self.snapshotVisibilityStore = useSnapshotVisibilityStore
        self.selectedProvider = selectedProvider
        self.snapshot = selectedState.snapshot
        self.statusMessage = selectedState.statusMessage
        self.isFetching = selectedState.isFetching

        // Set up state change callback for menu bar updates
        useStateManager.onStateChange = { [weak self] in
            self?.objectWillChange.send()
        }
    }

    // MARK: - Public Accessors

    /// Returns all provider snapshots for menu bar status display
    var snapshots: [UsageProvider: UsageSnapshot] {
        stateManager.allSnapshots
    }

    /// Returns latest fetch statuses for all providers (for summary UI)
    var fetchStatuses: [UsageProvider: ProviderFetchStatus] {
        stateManager.allFetchStatuses
    }

    /// 指定プロバイダーに過去の取得成功実績があるかを返す。
    func hasLoginHistory(for provider: UsageProvider) -> Bool {
        stateManager.hasLoginHistory(for: provider)
    }

    /// バックグラウンドでWebViewを稼働させるプロバイダー一覧。
    var backgroundActiveProviders: [UsageProvider] {
        stateManager.backgroundActiveProviders
    }

    /// Checks if user is logged in for the specified provider.
    /// Used by popup auto-close to detect OAuth completion.
    func checkLoginStatus(for provider: UsageProvider) async -> Bool {
        let webViewStore = webViewPool.getWebViewStore(for: provider)
        return await checkLoginStatus(using: webViewStore)
    }

    /// Checks login state in the exact account session that originated the
    /// request. Account switches invalidate the result before it can act.
    func checkLoginStatus(using webViewStore: WebViewStore) async -> Bool {
        guard let context = operationGate.captureContext(),
              isCurrentSelectedStore(webViewStore) else { return false }
        let isLoggedIn = await checkLoginStatus(
            for: webViewStore.provider,
            using: webViewStore.webView
        )
        guard operationGate.isCurrent(context),
              isCurrentSelectedStore(webViewStore) else { return false }
        return isLoggedIn
    }

    // MARK: - Auto Refresh

    /// Starts the auto-refresh timer for eligible providers.
    /// Uses AutoRefreshCoordinator to manage timer lifecycle.
    func startAutoRefresh() {
        guard autoRefreshCoordinator == nil else { return }
        autoRefreshCoordinator = AutoRefreshCoordinator(
            intervalProvider: { UsageRefreshConfig.refreshIntervalDuration },
            refreshHandler: { [weak self] in
                await self?.refreshAutoEligibleProviders()
            }
        )
        autoRefreshCoordinator?.start()
    }

    /// Stops the auto-refresh timer
    func stopAutoRefresh() {
        autoRefreshCoordinator?.stop()
        autoRefreshCoordinator = nil
    }

    /// Restarts the auto-refresh timer (useful when interval changes)
    func restartAutoRefresh() {
        stopAutoRefresh()
        startAutoRefresh()
    }

    // MARK: - Manual Refresh

    /// Triggers an immediate refresh for the specified provider (for widget tap)
    func refreshNow(for provider: UsageProvider) async {
        let webViewStore = webViewPool.getWebViewStore(for: provider)
        await refreshSnapshot(for: provider, using: webViewStore)
    }

    /// Triggers an immediate refresh for the current provider
    func fetchNow() {
        guard let context = operationGate.captureContext() else { return }
        let provider = selectedProvider
        let webViewStore = webViewPool.getWebViewStore(for: provider)
        guard isCurrentSelectedStore(webViewStore) else { return }
        // Record manual refresh intent to allow fetch on page-ready callback.
        manualRefreshAccountIDByProvider[provider] = webViewStore.account.id
        if isUsageURL(webViewStore.webView.url, provider: provider),
           webViewStore.isPageReady {
            // If already on the usage page, proceed directly to fetch.
            _ = consumeManualRefreshRequest(for: webViewStore)
            Task {
                await handleLoginAndFetch(using: webViewStore, context: context)
            }
        } else {
            // Otherwise reload to reach the usage page (login flow).
            webViewPool.reloadFromOrigin(webViewStore.account)
        }
    }

    // MARK: - Provider State Management

    /// Updates published properties when provider selection changes
    func updateSelectedProviderState() {
        let provider = selectedProvider
        let state = stateManager.getState(for: provider)
        snapshot = state.snapshot
        statusMessage = state.statusMessage
        isFetching = state.isFetching
    }

    /// Updates display mode and persists to all snapshots
    func updateDisplayMode(_ displayMode: UsageDisplayMode) {
        let displayMode = displayMode.normalizedSelectableMode
        // Apply new mode, persist it, and refresh UI state.
        self.displayMode = displayMode
        displayModeStore.applyDisplayMode(displayMode)
        updateSelectedProviderState()
    }

    /// Invalidates in-flight work, removes all cached login/usage data, and
    /// keeps new fetches blocked until WebKit website data is gone as well.
    func clearData() async throws {
        guard let clearToken = operationGate.beginClear() else { return }
        guard let webViewClearToken = webViewPool.beginDataClear() else {
            _ = operationGate.finishClear(clearToken)
            throw ClearDataError.websiteData("Another website-data clear is already active.")
        }
        guard let tokenDataClearToken = tokenUsageViewModel.beginDataClear() else {
            _ = webViewPool.cancelDataClear(webViewClearToken)
            _ = operationGate.finishClear(clearToken)
            throw ClearDataError.websiteData("Another token-data clear is already active.")
        }
        var didFinishWebsiteDataClear = false
        defer {
            if !didFinishWebsiteDataClear {
                _ = webViewPool.cancelDataClear(webViewClearToken)
            }
            _ = tokenUsageViewModel.finishDataClear(tokenDataClearToken)
            _ = operationGate.finishClear(clearToken)
        }

        manualRefreshAccountIDByProvider.removeAll()
        autoRecoveryInFlight.removeAll()
        lastLoginRedirectAt.removeAll()

        do {
            try await ensureWebsiteDataClearCoverage(webViewClearToken)
        } catch {
            throw ClearDataError.websiteData(error.localizedDescription)
        }

        var deletionFailures: [ClearDataDeletionFailure] = []

        for provider in UsageProvider.allCases {
            snapshotVisibilityStore.setSnapshotSuppressed(
                true,
                fileName: provider.snapshotFileName
            )
            do {
                try store.deleteSnapshot(for: provider)
                snapshotVisibilityStore.setSnapshotSuppressed(
                    false,
                    fileName: provider.snapshotFileName
                )
            } catch {
                deletionFailures.append(
                    ClearDataDeletionFailure(
                        target: provider.displayName,
                        reason: error.localizedDescription
                    )
                )
            }
            stateManager.clearLoginHistory(for: provider)
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
        }
        for failure in tokenUsageViewModel.clearAllSnapshots(
            during: tokenDataClearToken
        ) {
            let target = failure.provider == .copilot
                ? "Copilot billing"
                : "\(failure.provider.displayName) token usage"
            deletionFailures.append(
                ClearDataDeletionFailure(
                    target: target,
                    reason: failure.reason
                )
            )
        }
        updateSelectedProviderState()

        // Snapshot deletion removes background login history while the pool
        // retains any current foreground settings-window request.
        webViewPool.applyBackgroundPolicy(activeProviders: Set(backgroundActiveProviders))

        // Revalidate after all synchronous deletion hooks. If any account was
        // registered meanwhile, clear its store before releasing navigation.
        do {
            try await ensureWebsiteDataClearCoverage(webViewClearToken)
        } catch {
            throw ClearDataError.websiteData(error.localizedDescription)
        }
        guard webViewPool.finishDataClear(webViewClearToken) else {
            throw ClearDataError.websiteData(
                "Website-data coverage changed before the clear could finish."
            )
        }
        didFinishWebsiteDataClear = true

        if !deletionFailures.isEmpty {
            let error = ClearDataError.snapshotDeletion(deletionFailures)
            let message = error.localizedDescription
            Logger.usage.error("Clear Data snapshot deletion failed: \(message)")
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

    // MARK: - Page Ready Handling

    /// Called when one account WebView finishes loading; triggers fetch only
    /// while that same account remains selected.
    func handlePageReadyChange(for webViewStore: WebViewStore, isReady: Bool) {
        guard isReady, isCurrentSelectedStore(webViewStore) else { return }
        let provider = webViewStore.provider
        guard let context = operationGate.captureContext() else { return }
        // Recovery Task が SPA 初期化待機を担うため、recovery 中は page-ready 経由の fetch をスキップ。
        guard !isRecoveryInFlight(
            for: provider,
            accountID: webViewStore.account.id
        ) else { return }
        // Manual refresh has priority; otherwise honor auto-refresh eligibility.
        let isManualRefresh = consumeManualRefreshRequest(for: webViewStore)
        let state = stateManager.getState(for: provider)
        if !isManualRefresh {
            guard state.isAutoRefreshEnabled != true else { return }
        }
        guard !state.isFetching else { return }
        Task {
            await handleLoginAndFetch(using: webViewStore, context: context)
        }
    }

    /// Called when one account's cookies change; any redirect stays in that
    /// account's immutable WebKit session.
    func handleCookieChange(for webViewStore: WebViewStore) {
        guard isCurrentSelectedStore(webViewStore) else { return }
        let provider = webViewStore.provider
        guard provider == .claudeCode || provider == .githubCopilot else { return }
        guard let context = operationGate.captureContext() else { return }
        Task {
            // Only redirect when a valid session is detected and cooldown allows it.
            let isLoggedIn = await checkLoginStatus(
                for: provider,
                using: webViewStore.webView
            )
            guard operationGate.isCurrent(context),
                  isCurrentSelectedStore(webViewStore) else { return }
            guard isLoggedIn else { return }
            guard !isUsageURL(webViewStore.webView.url, provider: provider) else { return }
            guard canRedirectLogin(for: webViewStore.account.id) else { return }
            webViewPool.reloadFromOrigin(webViewStore.account)
        }
    }

    private func refreshAutoEligibleProviders() async {
        guard let context = operationGate.captureContext() else { return }
        // Refresh providers that are enabled or selected.
        let eligibleProviders = stateManager.autoRefreshEligibleProviders(selectedProvider: selectedProvider)
        for provider in eligibleProviders {
            // Never let a loop captured before Clear Data resume in its new generation.
            guard operationGate.isCurrent(context) else { return }
            let webViewStore = webViewPool.getWebViewStore(for: provider)
            guard isCurrentSelectedStore(webViewStore) else { continue }
            // Recovery Task が進行中のプロバイダは auto refresh をスキップ。
            guard !isRecoveryInFlight(
                for: provider,
                accountID: webViewStore.account.id
            ) else { continue }
            await refreshSnapshot(
                for: provider,
                using: webViewStore,
                context: context
            )
        }
    }

    private func refreshSnapshot(
        for provider: UsageProvider,
        using webViewStore: WebViewStore,
        context: UsageOperationGate.Context? = nil
    ) async {
        guard let operationContext = context ?? operationGate.captureContext() else { return }
        guard operationGate.isCurrent(operationContext),
              webViewStore.provider == provider,
              isCurrentSelectedStore(webViewStore) else { return }
        guard webViewStore.isPageReady else {
            // Update status while waiting for login page to load.
            stateManager.setStatusMessage("status.loadingLogin".localized(), for: provider)
            return
        }
        guard let fetchToken = operationGate.beginFetch(
            for: provider,
            context: operationContext
        ) else { return }

        // Track fetching state for both per-provider and selected provider UI.
        stateManager.setFetching(true, for: provider)
        if provider == selectedProvider {
            isFetching = true
        }
        defer {
            // A stale defer must not clear the state of a newer fetch.
            if operationGate.finishFetch(fetchToken) {
                stateManager.setFetching(false, for: provider)
                if provider == selectedProvider {
                    isFetching = false
                }
            }
        }

        do {
            // Fetch latest snapshot from provider and persist with display-mode marker.
            let fetchedSnapshot = try await fetchSnapshot(for: provider, using: webViewStore.webView)
            guard operationGate.isCurrent(fetchToken),
                  isCurrentSelectedStore(webViewStore) else { return }
            let snapshotToSave = fetchedSnapshot.makeSnapshot(for: displayMode)
            try store.saveSnapshot(snapshotToSave)
            snapshotVisibilityStore.setSnapshotSuppressed(
                false,
                fileName: snapshotToSave.provider.snapshotFileName
            )
            displayModeStore.saveCachedDisplayMode(displayMode)
            stateManager.updateAfterSuccessfulFetch(snapshot: snapshotToSave, for: provider)
            clearRecovery(
                for: provider,
                accountID: webViewStore.account.id,
                context: operationContext
            )
            stateManager.setStatusMessage("status.updated".localized(), for: provider)
            if provider == selectedProvider {
                self.snapshot = snapshotToSave
                statusMessage = "status.updated".localized()
            }
            // Notify widgets to refresh their timelines.
            WidgetCenter.shared.reloadTimelines(ofKind: snapshotToSave.provider.widgetKind)

            // Check thresholds and send notifications if needed
            await ThresholdNotificationManager.shared.checkThresholdsIfNeeded(
                for: fetchedSnapshot,
                isCurrent: { [weak self] in
                    guard let self else { return false }
                    return self.operationGate.isCurrent(fetchToken)
                        && self.isCurrentSelectedStore(webViewStore)
                }
            )
            guard operationGate.isCurrent(fetchToken),
                  isCurrentSelectedStore(webViewStore) else { return }

            // Fetch Copilot billing data alongside usage limits
            if provider == .githubCopilot,
               let billingContext = operationGate.captureContext(),
               let tokenUsageContext = tokenUsageViewModel.captureExternalSnapshotContext(
                   for: .copilot
               ) {
                Task {
                    await fetchCopilotBilling(
                        using: webViewStore,
                        context: billingContext,
                        tokenUsageContext: tokenUsageContext
                    )
                }
            }
        } catch {
            guard operationGate.isCurrent(fetchToken),
                  isCurrentSelectedStore(webViewStore) else { return }
            if shouldDisableAutoRefresh(for: provider, error: error) {
                if isRecoveryInFlight(
                    for: provider,
                    accountID: webViewStore.account.id
                ) {
                    // reload 後の再 fetch でも失敗 → 復旧不能と判定して auto refresh を無効化
                    clearRecovery(
                        for: provider,
                        accountID: webViewStore.account.id,
                        context: operationContext
                    )
                    stateManager.setAutoRefreshEnabled(false, for: provider)
                } else {
                    // 初回失敗: stale な lastActiveOrg Cookie を削除してからリロードし orgId を再取得する。
                    // page-ready 直後ではなく SPA が API コールを完了した後に fetch するため delayed Task を使う。
                    let recoveryState = RecoveryState(
                        accountID: webViewStore.account.id,
                        context: operationContext
                    )
                    autoRecoveryInFlight[provider] = recoveryState
                    await clearOrgIdCookie(
                        in: webViewStore,
                        context: operationContext
                    )
                    guard operationGate.isCurrent(fetchToken),
                          isCurrentSelectedStore(webViewStore),
                          autoRecoveryInFlight[provider] == recoveryState else {
                        clearRecovery(
                            for: provider,
                            accountID: webViewStore.account.id,
                            context: operationContext
                        )
                        return
                    }
                    webViewPool.reloadFromOrigin(webViewStore.account)
                    stateManager.setStatusMessage("status.loadingLogin".localized(), for: provider)
                    if provider == selectedProvider {
                        statusMessage = "status.loadingLogin".localized()
                    }
                    Task { [weak self] in
                        guard let self else { return }
                        await self.waitForRecoveryFetch(
                            for: provider,
                            using: webViewStore,
                            context: operationContext
                        )
                    }
                    return
                }
            }
            stateManager.setFetchStatus(.failure(error.localizedDescription), for: provider)
            stateManager.setStatusMessage(error.localizedDescription, for: provider)
            if provider == selectedProvider {
                statusMessage = error.localizedDescription
            }
        }
    }

    private func handleLoginAndFetch(
        using webViewStore: WebViewStore,
        context: UsageOperationGate.Context
    ) async {
        let provider = webViewStore.provider
        guard operationGate.isCurrent(context),
              isCurrentSelectedStore(webViewStore) else { return }
        // Verify login status before attempting API fetch.
        let isLoggedIn = await checkLoginStatus(
            for: provider,
            using: webViewStore.webView
        )
        guard operationGate.isCurrent(context),
              isCurrentSelectedStore(webViewStore) else { return }
        guard isLoggedIn else {
            stateManager.setStatusMessage("status.loadingLogin".localized(), for: provider)
            if provider == selectedProvider {
                statusMessage = "status.loadingLogin".localized()
            }
            return
        }

        if !isUsageURL(webViewStore.webView.url, provider: provider) {
            // Navigate to the usage page when logged in but not on target URL.
            webViewPool.reloadFromOrigin(webViewStore.account)
            return
        }

        await refreshSnapshot(
            for: provider,
            using: webViewStore,
            context: context
        )
    }

    private func checkLoginStatus(for provider: UsageProvider, using webView: WKWebView) async -> Bool {
        // Delegate to provider-specific fetchers.
        switch provider {
        case .chatgptCodex:
            return await codexFetcher.hasValidSession(using: webView)
        case .claudeCode:
            return await claudeFetcher.hasValidSession(using: webView)
        case .githubCopilot:
            return await copilotFetcher.hasValidSession(using: webView)
        }
    }

    private func isUsageURL(_ url: URL?, provider: UsageProvider) -> Bool {
        // Compare scheme/host/path to avoid false positives.
        guard let url else { return false }
        let usageURL = provider.usageURL
        return url.scheme == usageURL.scheme
            && url.host == usageURL.host
            && url.path == usageURL.path
    }

    private func isCurrentSelectedStore(_ webViewStore: WebViewStore) -> Bool {
        webViewPool.isSelectedAccount(
            webViewStore.account.id,
            for: webViewStore.provider
        )
    }

    private func consumeManualRefreshRequest(
        for webViewStore: WebViewStore
    ) -> Bool {
        let provider = webViewStore.provider
        guard let requestedAccountID = manualRefreshAccountIDByProvider[provider]
        else { return false }
        guard requestedAccountID == webViewStore.account.id else { return false }
        manualRefreshAccountIDByProvider.removeValue(forKey: provider)
        return true
    }

    private func fetchSnapshot(for provider: UsageProvider, using webView: WKWebView) async throws -> UsageSnapshot {
        // Delegate fetch to provider-specific fetchers.
        switch provider {
        case .chatgptCodex:
            return try await codexFetcher.fetchUsageSnapshot(using: webView)
        case .claudeCode:
            return try await claudeFetcher.fetchUsageSnapshot(using: webView)
        case .githubCopilot:
            return try await copilotFetcher.fetchUsageSnapshot(using: webView)
        }
    }

    private func shouldDisableAutoRefresh(for provider: UsageProvider, error: Error) -> Bool {
        // Disable auto-refresh only for authentication/organization issues.
        switch provider {
        case .chatgptCodex:
            guard let error = error as? CodexUsageFetcherError else { return false }
            switch error {
            case .scriptFailed(let message):
                return isLoginRequiredMessage(message)
            case .invalidResponse, .pageNotReady:
                return false
            }
        case .claudeCode:
            guard let error = error as? ClaudeUsageFetcherError else { return false }
            switch error {
            case .missingOrganization:
                return true
            case .scriptFailed(let message):
                return isLoginRequiredMessage(message)
            case .invalidResponse:
                return false
            }
        case .githubCopilot:
            guard let error = error as? CopilotUsageFetcherError else { return false }
            switch error {
            case .scriptFailed(let message):
                return isLoginRequiredMessage(message)
            case .invalidResponse, .pageNotReady:
                return false
            }
        }
    }

    private func isLoginRequiredMessage(_ message: String) -> Bool {
        // Normalize and check for common auth-related error markers.
        let normalized = message.lowercased()
        return normalized.contains("missing access token")
            || normalized.contains("missing organization")
            || normalized.contains("unauthorized")
            || normalized.contains("http 401")
            || normalized.contains("http 403")
    }

    /// ページ再ロード後、SPA の API コール完了を待ってから fetch を実行する。
    /// handlePageReadyChange は autoRecoveryInFlight によりスキップされるため、ここで直接呼ぶ。
    private func waitForRecoveryFetch(
        for provider: UsageProvider,
        using webViewStore: WebViewStore,
        context: UsageOperationGate.Context
    ) async {
        let recoveryState = RecoveryState(
            accountID: webViewStore.account.id,
            context: context
        )
        guard operationGate.isCurrent(context),
              isCurrentSelectedStore(webViewStore),
              autoRecoveryInFlight[provider] == recoveryState else {
            clearRecovery(
                for: provider,
                accountID: webViewStore.account.id,
                context: context
            )
            return
        }
        // ページロード完了を最大 15 秒待機
        let deadline = Date().addingTimeInterval(15)
        while !webViewStore.isPageReady && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            guard operationGate.isCurrent(context),
                  isCurrentSelectedStore(webViewStore),
                  autoRecoveryInFlight[provider] == recoveryState else {
                clearRecovery(
                    for: provider,
                    accountID: webViewStore.account.id,
                    context: context
                )
                return
            }
        }
        guard webViewStore.isPageReady else {
            // タイムアウト: recovery フラグを解除して通常の auto refresh に戻す
            clearRecovery(
                for: provider,
                accountID: webViewStore.account.id,
                context: context
            )
            return
        }
        // SPA が初期 API コールを performance.getEntriesByType("resource") に登録するまで待機
        try? await Task.sleep(for: .seconds(3))
        guard operationGate.isCurrent(context),
              isCurrentSelectedStore(webViewStore),
              autoRecoveryInFlight[provider] == recoveryState else {
            clearRecovery(
                for: provider,
                accountID: webViewStore.account.id,
                context: context
            )
            return
        }
        await handleLoginAndFetch(using: webViewStore, context: context)
        // handleLoginAndFetch → refreshSnapshot が早期リターンした場合 (ページ未準備等) にフラグが残る可能性があるため解除
        clearRecovery(
            for: provider,
            accountID: webViewStore.account.id,
            context: context
        )
    }

    /// missingOrganization エラー後の自動復旧用。stale な lastActiveOrg Cookie を削除し、
    /// リロード後の JS が resource / HTML フォールバックで最新 orgId を取得できるようにする。
    private func clearOrgIdCookie(
        in webViewStore: WebViewStore,
        context: UsageOperationGate.Context
    ) async {
        guard webViewStore.provider == .claudeCode else { return }
        guard operationGate.isCurrent(context),
              isCurrentSelectedStore(webViewStore) else { return }
        let cookieStore = webViewStore.websiteDataStore.httpCookieStore
        let cookies = await cookieStore.allCookies()
        guard operationGate.isCurrent(context),
              isCurrentSelectedStore(webViewStore) else { return }
        for cookie in cookies where cookie.name == "lastActiveOrg" {
            await cookieStore.deleteCookie(cookie)
            guard operationGate.isCurrent(context),
                  isCurrentSelectedStore(webViewStore) else { return }
        }
    }

    private func isRecoveryInFlight(
        for provider: UsageProvider,
        accountID: UUID
    ) -> Bool {
        guard let state = autoRecoveryInFlight[provider] else { return false }
        guard operationGate.isCurrent(state.context),
              webViewPool.isSelectedAccount(state.accountID, for: provider) else {
            if autoRecoveryInFlight[provider] == state {
                autoRecoveryInFlight.removeValue(forKey: provider)
            }
            return false
        }
        return state.accountID == accountID
    }

    private func clearRecovery(
        for provider: UsageProvider,
        accountID: UUID,
        context: UsageOperationGate.Context
    ) {
        let expectedState = RecoveryState(accountID: accountID, context: context)
        guard autoRecoveryInFlight[provider] == expectedState else { return }
        autoRecoveryInFlight.removeValue(forKey: provider)
    }

    private func canRedirectLogin(for accountID: UUID) -> Bool {
        // Throttle redirects to avoid excessive reloads.
        let now = Date()
        let cooldown: TimeInterval = 5
        if let lastRedirectAt = lastLoginRedirectAt[accountID],
           now.timeIntervalSince(lastRedirectAt) < cooldown {
            return false
        }
        lastLoginRedirectAt[accountID] = now
        return true
    }

    // MARK: - Copilot Billing

    /// Fetches Copilot billing data and saves to token usage snapshot store.
    /// Fire-and-forget: errors are logged but do not affect usage limits UI.
    private func fetchCopilotBilling(
        using webViewStore: WebViewStore,
        context: UsageOperationGate.Context,
        tokenUsageContext: TokenUsageViewModel.ExternalSnapshotContext
    ) async {
        guard operationGate.isCurrent(context),
              isCurrentSelectedStore(webViewStore) else { return }
        do {
            let snapshot = try await copilotBillingFetcher.fetchBillingSnapshot(
                using: webViewStore.webView
            )
            guard operationGate.isCurrent(context),
                  isCurrentSelectedStore(webViewStore) else { return }
            try tokenUsageViewModel.saveExternallyFetchedSnapshot(
                snapshot,
                context: tokenUsageContext
            )
        } catch {
            guard operationGate.isCurrent(context),
                  isCurrentSelectedStore(webViewStore) else { return }
            Logger.usage.error("Copilot billing fetch failed: \(error.localizedDescription)")
        }
    }
}
