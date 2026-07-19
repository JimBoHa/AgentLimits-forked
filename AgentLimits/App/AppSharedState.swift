// MARK: - AppSharedState.swift
// Shared application state for menu bar and settings window.
// Manages WebView pool, view model, and page-ready observation.

import Combine
import Foundation
import WidgetKit

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

    /// 設定ウィンドウクローズ時のコールバック（AppDelegate が設定する）
    var onSettingsWindowClosed: (() -> Void)?

    private var isStarted = false
    private var lifecycleCancellables: Set<AnyCancellable> = []
    private var cancellablesByAccountID: [UUID: Set<AnyCancellable>] = [:]
    private var observedAccountIDs: Set<UUID> = []

    init() {
        let accountStore = ProviderAccountStore.shared
        let pool = UsageWebViewPool(accountStore: accountStore)
        let removalManager = ProviderAccountRemovalManager(
            accountStore: accountStore,
            webViewPool: pool
        )
        let tokenViewModel = TokenUsageViewModel()
        self.webViewPool = pool
        self.accountRemovalManager = removalManager
        self.tokenUsageViewModel = tokenViewModel
        self.viewModel = UsageViewModel(
            webViewPool: pool,
            tokenUsageViewModel: tokenViewModel
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
        Task { [weak removalManager] in
            await removalManager?.drainPendingWebKitDataStoreDeletions()
        }
        let storedMode = UsageDisplayMode.makeSelectableMode(
            from: UserDefaults.standard.string(forKey: UserDefaultsKeys.displayMode)
        )
        viewModel.updateDisplayMode(storedMode)
        startBackgroundRefresh()

        // Initialize WakeUpScheduler to sync LaunchAgents on startup
        _ = WakeUpScheduler.shared

        // Refresh widgets once on app launch.
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Starts background refresh and loads WebViews (called once)
    func startBackgroundRefresh() {
        guard !isStarted else { return }
        isStarted = true
        loadWebViews()
        viewModel.startAutoRefresh()
        tokenUsageViewModel.startAutoRefresh()
    }

    /// Applies the background WebView policy for providers with fetch history.
    private func loadWebViews() {
        webViewPool.applyBackgroundPolicy(
            activeAccounts: viewModel.backgroundActiveAccounts
        )
    }

    /// 設定画面で操作するため、選択中プロバイダーのWebViewを復帰する。
    func resumeWebViewForSettings() {
        webViewPool.resume(viewModel.selectedProvider)
    }

    /// 設定画面を閉じた後、取得実績のないWebViewを停止状態に戻す。
    func applyBackgroundPolicyOnSettingsClose() {
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
