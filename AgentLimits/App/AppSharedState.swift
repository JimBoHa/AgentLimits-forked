// MARK: - AppSharedState.swift
// Shared application state for menu bar and settings window.
// Manages WebView pool, view model, and page-ready observation.

import Combine
import Foundation
import WebKit
import WidgetKit

#if DEBUG
nonisolated enum UITestingExternalServiceError: LocalizedError, Equatable {
    case disabled

    var errorDescription: String? {
        "External services are disabled during UI testing."
    }
}

nonisolated struct UITestingCCUsageFetcher: CCUsageFetching {
    func fetchSnapshot(
        for provider: TokenUsageProvider
    ) async throws -> TokenUsageSnapshot {
        throw UITestingExternalServiceError.disabled
    }
}

struct UITestingUsageSnapshotFetcher: UsageSnapshotFetching {
    func hasValidSession(
        for provider: UsageProvider,
        using webView: WKWebView
    ) async -> Bool {
        false
    }

    func fetchSnapshot(
        for provider: UsageProvider,
        using webView: WKWebView
    ) async throws -> UsageSnapshot {
        throw UITestingExternalServiceError.disabled
    }
}

struct UITestingCopilotBillingFetcher: CopilotBillingFetching {
    func fetchBillingSnapshot(
        using webView: WKWebView
    ) async throws -> TokenUsageSnapshot {
        throw UITestingExternalServiceError.disabled
    }
}

private final class UITestingSessionActivityCredentialStore:
    SessionActivityCredentialStoring {
    private var credentials: [UUID: String] = [:]

    func credential(for accountID: UUID) throws -> String? {
        credentials[accountID]
    }

    func saveCredential(_ credential: String, for accountID: UUID) throws {
        credentials[accountID] = credential
    }

    func deleteCredential(for accountID: UUID) throws {
        credentials.removeValue(forKey: accountID)
    }

    func deleteAllCredentials() throws {
        credentials.removeAll()
    }
}

nonisolated private struct UITestingGitHubAgentTaskFetcher:
    GitHubAgentTaskFetching {
    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        throw GitHubAgentTaskFetcherError.authenticationRequired
    }
}

private struct UITestingProviderAccountLocalDataRemover:
    ProviderAccountLocalDataRemoving {
    func removeLocalData(for account: ProviderAccount) throws {}
}

private struct UITestingIdentifiedWebsiteDataStoreRemover:
    IdentifiedWebsiteDataStoreRemoving {
    func containsDataStore(for identifier: UUID) async -> Bool { false }
    func removeDataStore(for identifier: UUID) async throws {}
}
#endif

@MainActor
struct AppExternalServiceDependencies {
    let ccUsageFetcher: any CCUsageFetching
    let usageSnapshotFetcher: any UsageSnapshotFetching
    let copilotBillingFetcher: any CopilotBillingFetching

    static func make(isUITesting: Bool) -> Self {
#if DEBUG
        if isUITesting {
            return Self(
                ccUsageFetcher: UITestingCCUsageFetcher(),
                usageSnapshotFetcher: UITestingUsageSnapshotFetcher(),
                copilotBillingFetcher: UITestingCopilotBillingFetcher()
            )
        }
#endif
        return Self(
            ccUsageFetcher: CCUsageFetcher(),
            usageSnapshotFetcher: DefaultUsageSnapshotFetcher(),
            copilotBillingFetcher: CopilotBillingFetcher()
        )
    }
}

// MARK: - App Shared State

/// Shared state container for the entire application.
/// Initializes WebView pool, view model, and observes page-ready changes.
@MainActor
final class AppSharedState: ObservableObject {
    static let shared = AppSharedState()

    let webViewPool: UsageWebViewPool
    let accountRemovalManager: ProviderAccountRemovalManager
    let viewModel: UsageViewModel
    let tokenUsageViewModel: TokenUsageViewModel
    let sessionActivityViewModel: SessionActivityViewModel

    /// 設定ウィンドウクローズ時のコールバック（AppDelegate が設定する）
    var onSettingsWindowClosed: (() -> Void)?

    private var isStarted = false
    private var lifecycleCancellables: Set<AnyCancellable> = []
    private var cancellablesByAccountID: [UUID: Set<AnyCancellable>] = [:]
    private var observedAccountIDs: Set<UUID> = []
    private let allowsExternalServices: Bool

    init() {
        let accountStore = ProviderAccountStore.shared
        let externalServices = AppExternalServiceDependencies.make(
            isUITesting: AppRuntimeEnvironment.isUITesting
        )
        let pool: UsageWebViewPool
        let activityViewModel: SessionActivityViewModel
        let removalManager: ProviderAccountRemovalManager
#if DEBUG
        if AppRuntimeEnvironment.isUITesting {
            pool = UsageWebViewPool(
                accountStore: accountStore,
                websiteDataStoreProvider: { _ in .nonPersistent() },
                navigationPolicy: .disabled
            )
            activityViewModel = SessionActivityViewModel(
                accountStore: accountStore,
                credentialStore: UITestingSessionActivityCredentialStore(),
                githubFetcher: UITestingGitHubAgentTaskFetcher()
            )
            removalManager = ProviderAccountRemovalManager(
                accountStore: accountStore,
                webViewPool: pool,
                localDataRemover:
                    UITestingProviderAccountLocalDataRemover(),
                activityDataRetirer: activityViewModel,
                websiteDataStoreRemover:
                    UITestingIdentifiedWebsiteDataStoreRemover()
            )
            allowsExternalServices = false
        } else {
            pool = UsageWebViewPool(accountStore: accountStore)
            activityViewModel = SessionActivityViewModel(
                accountStore: accountStore
            )
            removalManager = ProviderAccountRemovalManager(
                accountStore: accountStore,
                webViewPool: pool,
                activityDataRetirer: activityViewModel
            )
            allowsExternalServices = true
        }
#else
        pool = UsageWebViewPool(accountStore: accountStore)
        activityViewModel = SessionActivityViewModel(
            accountStore: accountStore
        )
        removalManager = ProviderAccountRemovalManager(
            accountStore: accountStore,
            webViewPool: pool,
            activityDataRetirer: activityViewModel
        )
        allowsExternalServices = true
#endif
        let tokenViewModel = TokenUsageViewModel(
            fetcher: externalServices.ccUsageFetcher,
            accountStore: accountStore
        )
        self.webViewPool = pool
        self.accountRemovalManager = removalManager
        self.tokenUsageViewModel = tokenViewModel
        self.sessionActivityViewModel = activityViewModel
        self.viewModel = UsageViewModel(
            webViewPool: pool,
            usageFetcher: externalServices.usageSnapshotFetcher,
            copilotBillingFetcher: externalServices.copilotBillingFetcher,
            tokenUsageViewModel: tokenViewModel,
            sessionActivityDataClearer: activityViewModel
        )
        pool.webViewStoreWillRetire
            .sink { [weak self] accountID in
                self?.stopObservingWebViewStore(accountID: accountID)
            }
            .store(in: &lifecycleCancellables)
        for store in pool.webViewStores {
            observeWebViewStore(store)
        }
        pool.onWebViewStoreCreated = { [weak self] store in
            self?.observeWebViewStore(store)
        }
        let storedMode = UsageDisplayMode.makeSelectableMode(
            from: AppDefaults.shared.string(forKey: UserDefaultsKeys.displayMode)
        )
        viewModel.updateDisplayMode(storedMode)
        if allowsExternalServices {
            Task { [weak removalManager] in
                await removalManager?
                    .drainPendingWebKitDataStoreDeletions()
            }
            startBackgroundRefresh()

            // Initialize WakeUpScheduler to sync LaunchAgents on startup
            _ = WakeUpScheduler.shared

            // Refresh widgets once on app launch.
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    /// Starts background refresh and loads WebViews (called once)
    func startBackgroundRefresh() {
        guard allowsExternalServices, !isStarted else { return }
        isStarted = true
        loadWebViews()
        viewModel.startAutoRefresh()
        tokenUsageViewModel.startAutoRefresh()
        sessionActivityViewModel.startAutoRefresh()
    }

    /// Applies the background WebView policy for providers with fetch history.
    private func loadWebViews() {
        webViewPool.applyBackgroundPolicy(
            activeAccounts: viewModel.backgroundActiveAccounts
        )
    }

    /// 設定画面で操作するため、選択中プロバイダーのWebViewを復帰する。
    func resumeWebViewForSettings() {
        guard allowsExternalServices else { return }
        webViewPool.resume(viewModel.selectedProvider)
    }

    /// 設定画面を閉じた後、取得実績のないWebViewを停止状態に戻す。
    func applyBackgroundPolicyOnSettingsClose() {
        guard allowsExternalServices else { return }
        webViewPool.clearForegroundProvider()
        webViewPool.applyBackgroundPolicy(
            activeAccounts: viewModel.backgroundActiveAccounts
        )
    }

    /// Observes every account store once. The view model preserves the exact
    /// account identity for foreground and background sibling events.
    private func observeWebViewStore(_ store: WebViewStore) {
        guard observedAccountIDs.insert(store.account.id).inserted else { return }
        let accountID = store.account.id
        var storeCancellables: Set<AnyCancellable> = []
        store.$isPageReady
            .removeDuplicates()
            .sink { [weak self, weak store] isReady in
                guard let store else { return }
                self?.viewModel.handlePageReadyChange(
                    for: store,
                    isReady: isReady
                )
            }
            .store(in: &storeCancellables)

        store.$cookieChangeToken
            .sink { [weak self, weak store] _ in
                guard let store else { return }
                self?.viewModel.handleCookieChange(for: store)
            }
            .store(in: &storeCancellables)
        cancellablesByAccountID[accountID] = storeCancellables
    }

    private func stopObservingWebViewStore(accountID: UUID) {
        cancellablesByAccountID
            .removeValue(forKey: accountID)?
            .forEach { $0.cancel() }
        observedAccountIDs.remove(accountID)
    }
}
