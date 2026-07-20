// MARK: - ContentView.swift
// Main settings window UI for viewing and refreshing usage data.
// Displays usage summary, provider selector, and embedded WebView for login.

import SwiftUI
import WebKit
import WidgetKit

// MARK: - Main Content View

/// Settings window content displaying usage data and login WebView
struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var viewModel: UsageViewModel
    @ObservedObject private var webViewPool: UsageWebViewPool
    @ObservedObject private var sessionActivityViewModel:
        SessionActivityViewModel
    private let accountRemovalManager: ProviderAccountRemovalManager
    @AppStorage(
        UserDefaultsKeys.displayMode,
        store: AppDefaults.shared
    ) private var displayMode: UsageDisplayMode = .used
    @AppStorage(
        AppGroupConfig.usageRefreshIntervalMinutesKey,
        store: AppGroupDefaults.shared
    ) private var refreshIntervalMinutes: Int = RefreshIntervalConfig.defaultMinutes
    @AppStorage(
        UserDefaultsKeys.menuBarStatusCodexEnabled,
        store: AppDefaults.shared
    ) private var menuBarCodexEnabled = false
    @AppStorage(
        UserDefaultsKeys.menuBarStatusClaudeEnabled,
        store: AppDefaults.shared
    ) private var menuBarClaudeEnabled = false
    @AppStorage(
        UserDefaultsKeys.menuBarStatusCopilotEnabled,
        store: AppDefaults.shared
    ) private var menuBarCopilotEnabled = false
    @AppStorage(
        UserDefaultsKeys.menuBarDashboardCodexEnabled,
        store: AppDefaults.shared
    ) private var menuBarDashboardCodexEnabled = true
    @AppStorage(
        UserDefaultsKeys.menuBarDashboardClaudeEnabled,
        store: AppDefaults.shared
    ) private var menuBarDashboardClaudeEnabled = true
    @AppStorage(
        UserDefaultsKeys.menuBarDashboardCopilotEnabled,
        store: AppDefaults.shared
    ) private var menuBarDashboardCopilotEnabled = true
    @State private var orderedProviders: [UsageProvider] = ProviderOrderStore.loadProviderOrder()
    @State private var isShowingClearDataConfirm = false
    @State private var isClearingData = false
    @State private var clearDataErrorMessage: String?
    @State private var isWebViewExpanded = false
    @State private var popupWebView: WKWebView?
    @State private var popupWebViewStore: WebViewStore?
    @State private var isShowingAccountManager = false
    @State private var activityCredentialAccount: ProviderAccount?
    @State private var accountErrorMessage: String?

    init(
        viewModel: UsageViewModel,
        webViewPool: UsageWebViewPool,
        sessionActivityViewModel: SessionActivityViewModel,
        accountRemovalManager: ProviderAccountRemovalManager
    ) {
        self.viewModel = viewModel
        self._webViewPool = ObservedObject(wrappedValue: webViewPool)
        self._sessionActivityViewModel = ObservedObject(
            wrappedValue: sessionActivityViewModel
        )
        self.accountRemovalManager = accountRemovalManager
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.large) {
                    Form {
                        SettingsFormSection {
                            LabeledContent("content.provider".localized()) {
                                providerPicker
                            }
                            LabeledContent("content.account".localized()) {
                                accountPicker
                            }
                            LabeledContent("refreshInterval.label".localized()) {
                                RefreshIntervalPickerRow(showsLabel: false, refreshIntervalMinutes: $refreshIntervalMinutes)
                            }
                        }

                        SettingsFormSection {
                            menuBarToggleRow
                        }

                        SettingsFormSection(title: "settings.providerOrder".localized()) {
                            List {
                                ForEach(orderedProviders, id: \.self) { provider in
                                    HStack(spacing: 8) {
                                        Image(systemName: "line.3.horizontal")
                                            .foregroundStyle(.secondary)
                                        Text(provider.displayName)
                                        Spacer()
                                    }
                                    .padding(.vertical, 2)
                                }
                                .onMove { source, destination in
                                    orderedProviders.move(fromOffsets: source, toOffset: destination)
                                    ProviderOrderStore.saveProviderOrder(orderedProviders)
                                }
                            }
                            .listStyle(.bordered(alternatesRowBackgrounds: true))
                            .frame(height: CGFloat(orderedProviders.count) * 34)
                        }

                        SettingsFormSection(title: "content.usageSummary".localized()) {
                            UsageSummaryView(
                                snapshot: viewModel.snapshot,
                                displayMode: displayMode,
                                fetchStatuses: viewModel.fetchStatuses
                            )
                        }

                        SettingsFormSection(title: "activity.title".localized()) {
                            SessionActivitySummaryView(
                                account: selectedAccount,
                                snapshot: sessionActivityViewModel.snapshot(
                                    for: selectedAccount.id
                                ),
                                isFetching: sessionActivityViewModel.isFetching(
                                    accountID: selectedAccount.id
                                ),
                                onRefresh: {
                                    let account = selectedAccount
                                    Task {
                                        await sessionActivityViewModel.refresh(
                                            account: account
                                        )
                                    }
                                },
                                onManageCredential: {
                                    activityCredentialAccount = selectedAccount
                                }
                            )
                        }

                        SettingsFormSection {
                            controlView
                        }
                    }
                    .formStyle(.grouped)
                }
                .padding(DesignTokens.Spacing.large)
                .padding(.bottom, webViewPanelCollapsedHeight + DesignTokens.Spacing.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(!isWebViewExpanded)

                if isWebViewExpanded {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()
                        .onTapGesture {
                            collapseWebViewPanel()
                        }
                        .transition(.opacity)
                }

                webViewPanel(totalHeight: geometry.size.height)
            }
        }
        .onChange(of: refreshIntervalMinutes) { _, _ in
            // Restart auto-refresh and notify widgets when interval changes.
            viewModel.restartAutoRefresh()
            sessionActivityViewModel.restartAutoRefresh()
            WidgetCenter.shared.reloadAllTimelines()
        }
        .onChange(of: viewModel.selectedProvider) { _, newProvider in
            webViewPool.resume(viewModel.selectedAccount(for: newProvider))
        }
        .onChange(of: selectedAccount.id) { _, _ in
            closePopupWebView()
            webViewPool.resume(selectedAccount)
        }
        .onChange(of: isWebViewExpanded) { _, isExpanded in
            if isExpanded {
                webViewPool.resume(viewModel.selectedProvider)
            }
        }
        .onAppear {
            orderedProviders = ProviderOrderStore.loadProviderOrder()
        }
        .confirmationDialog(
            "content.clearDataConfirmTitle".localized(),
            isPresented: $isShowingClearDataConfirm,
            titleVisibility: .visible
        ) {
            Button("content.clearDataConfirmAction".localized(), role: .destructive) {
                Task {
                    // Keep fetches blocked until snapshots and WebKit login data are both gone.
                    isClearingData = true
                    defer { isClearingData = false }
                    do {
                        try await viewModel.clearData()
                    } catch {
                        clearDataErrorMessage = error.localizedDescription
                    }
                }
            }
            Button("content.clearDataCancel".localized(), role: .cancel) {}
        } message: {
            Text("content.clearDataConfirmMessage".localized())
        }
        .alert(
            "content.clearData".localized(),
            isPresented: Binding(
                get: { clearDataErrorMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        clearDataErrorMessage = nil
                    }
                }
            )
        ) {
            Button("content.clearDataCancel".localized(), role: .cancel) {
                clearDataErrorMessage = nil
            }
        } message: {
            Text(clearDataErrorMessage ?? "")
        }
        .alert(
            "accounts.title".localized(),
            isPresented: Binding(
                get: { accountErrorMessage != nil },
                set: { isPresented in
                    if !isPresented { accountErrorMessage = nil }
                }
            )
        ) {
            Button("accounts.ok".localized(), role: .cancel) {
                accountErrorMessage = nil
            }
        } message: {
            Text(accountErrorMessage ?? "")
        }
        .sheet(isPresented: $isShowingAccountManager) {
            ProviderAccountsSettingsView(
                viewModel: viewModel,
                sessionActivityViewModel: sessionActivityViewModel,
                removalManager: accountRemovalManager,
                initialProvider: viewModel.selectedProvider
            )
        }
        .sheet(item: $activityCredentialAccount) { account in
            GitHubActivityCredentialView(
                account: account,
                viewModel: sessionActivityViewModel
            )
        }
        .sheet(
            isPresented: Binding(
                get: { popupWebView != nil },
                set: { isPresented in
                    if !isPresented {
                        // Close popup and release WebView when sheet dismissed.
                        popupWebViewStore?.closePopupWebView()
                        popupWebViewStore = nil
                        popupWebView = nil
                    }
                }
            )
        ) {
            if let popup = popupWebView {
                PopupWebViewSheet(
                    webView: popup,
                    onClose: {
                        // Explicit close action from sheet UI.
                        popupWebViewStore?.closePopupWebView()
                        popupWebViewStore = nil
                        popupWebView = nil
                    }
                )
            }
        }
        .onReceive(webViewPool.webViewStoreWillRetire) { accountID in
            guard popupWebViewStore?.account.id == accountID else { return }
            popupWebViewStore?.closePopupWebView()
            popupWebViewStore = nil
            popupWebView = nil
        }
        .accessibilityIdentifier("mac.usage.root")
    }

    // MARK: - Provider Picker

    private var providerPicker: some View {
        Picker("", selection: $viewModel.selectedProvider) {
            ForEach(UsageProvider.allCases) { provider in
                Text(provider.displayName)
                    .tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        .labelsHidden()
        .accessibilityLabel(Text("content.provider".localized()))
        .accessibilityIdentifier("mac.usage.providerPicker")
    }

    private var selectedAccount: ProviderAccount {
        viewModel.selectedAccount(for: viewModel.selectedProvider)
    }

    private var accountPicker: some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            Picker(
                "",
                selection: Binding(
                    get: { selectedAccount.id },
                    set: { accountID in
                        do {
                            _ = try viewModel.selectAccount(id: accountID)
                        } catch {
                            accountErrorMessage = error.localizedDescription
                        }
                    }
                )
            ) {
                ForEach(viewModel.accounts(for: viewModel.selectedProvider)) {
                    account in
                    Text(
                        account.isEnabled
                            ? account.label
                            : "accounts.disabledFormat".localized(account.label)
                    )
                    .tag(account.id)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 190)
            .labelsHidden()
            .accessibilityLabel(Text("content.account".localized()))
            .accessibilityIdentifier("mac.usage.accountPicker")

            Button("accounts.manage".localized()) {
                isShowingAccountManager = true
            }
            .settingsButtonStyle(.secondary)
            .accessibilityIdentifier("mac.usage.manageAccounts")
        }
    }

    private var controlView: some View {
        VStack(spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.medium) {
                Button("content.refreshNow".localized()) {
                    viewModel.fetchNow()
                }
                .disabled(viewModel.isFetching)
                .settingsButtonStyle(.primary)
                .accessibilityIdentifier("mac.usage.refresh")

                if viewModel.isFetching {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("content.clearData".localized(), role: .destructive) {
                    isShowingClearDataConfirm = true
                }
                .disabled(isClearingData)
                .settingsButtonStyle(.destructive)
                .accessibilityIdentifier("mac.usage.clearData")

                if isClearingData {
                    ProgressView()
                        .controlSize(.small)
                }

                Spacer()

                Text(viewModel.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var menuBarToggleRow: some View {
        Group {
            Toggle("settings.showInMenuBar".localized(), isOn: menuBarEnabledBinding)
                .toggleStyle(.checkbox)
            Toggle("settings.showMenuDashboard".localized(), isOn: menuBarDashboardEnabledBinding)
                .toggleStyle(.checkbox)
        }
    }

    private var menuBarEnabledBinding: Binding<Bool> {
        Binding(
            get: {
                switch viewModel.selectedProvider {
                case .chatgptCodex:
                    return menuBarCodexEnabled
                case .claudeCode:
                    return menuBarClaudeEnabled
                case .githubCopilot:
                    return menuBarCopilotEnabled
                }
            },
            set: { newValue in
                switch viewModel.selectedProvider {
                case .chatgptCodex:
                    menuBarCodexEnabled = newValue
                case .claudeCode:
                    menuBarClaudeEnabled = newValue
                case .githubCopilot:
                    menuBarCopilotEnabled = newValue
                }
            }
        )
    }

    private var menuBarDashboardEnabledBinding: Binding<Bool> {
        Binding(
            get: {
                switch viewModel.selectedProvider {
                case .chatgptCodex:
                    return menuBarDashboardCodexEnabled
                case .claudeCode:
                    return menuBarDashboardClaudeEnabled
                case .githubCopilot:
                    return menuBarDashboardCopilotEnabled
                }
            },
            set: { newValue in
                switch viewModel.selectedProvider {
                case .chatgptCodex:
                    menuBarDashboardCodexEnabled = newValue
                case .claudeCode:
                    menuBarDashboardClaudeEnabled = newValue
                case .githubCopilot:
                    menuBarDashboardCopilotEnabled = newValue
                }
            }
        )
    }

    private var webViewPanelCollapsedHeight: CGFloat { 42 }

    private func webViewPanel(totalHeight: CGFloat) -> some View {
        let panelPadding = DesignTokens.Spacing.large
        let expandedHeight = max(
            webViewPanelCollapsedHeight,
            totalHeight - (panelPadding * 2)
        )

        return VStack(spacing: 0) {
            webViewPanelHandle

            if isWebViewExpanded {
                Divider()
                loginWebViewSection
                    .padding(DesignTokens.Spacing.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(
            height: isWebViewExpanded ? expandedHeight : webViewPanelCollapsedHeight,
            alignment: .top
        )
        .background(.regularMaterial)
        .clipShape(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.CornerRadius.medium)
                .strokeBorder(Color.secondary.opacity(0.25))
        )
        .shadow(color: .black.opacity(isWebViewExpanded ? 0.16 : 0.08), radius: isWebViewExpanded ? 10 : 4, y: 2)
        .padding(.horizontal, panelPadding)
        .padding(.bottom, panelPadding)
        .animation(loginPanelAnimation, value: isWebViewExpanded)
    }

    private var webViewPanelHandle: some View {
        Button {
            withAnimation(loginPanelAnimation) {
                isWebViewExpanded.toggle()
            }
        } label: {
            HStack(spacing: DesignTokens.Spacing.small) {
                Image(systemName: isWebViewExpanded ? "chevron.down" : "chevron.up")
                    .font(.caption.bold())
                Text("content.login".localized())
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text(viewModel.selectedProvider.displayName)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("—")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                Text(selectedAccount.label)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, DesignTokens.Spacing.medium)
            .padding(.vertical, DesignTokens.Spacing.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("content.login".localized()))
    }

    private func collapseWebViewPanel() {
        guard isWebViewExpanded else { return }
        withAnimation(loginPanelAnimation) {
            isWebViewExpanded = false
        }
    }

    private var loginPanelAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.2)
    }

    private var loginWebViewSection: some View {
        let store = webViewPool.getWebViewStore(for: selectedAccount)
        return WebViewRepresentable(store: store)
            .id(store.account.id)
            .onReceive(store.$popupWebView) { [weak store] popup in
                guard let store else { return }
                if let popup {
                    popupWebView = popup
                    popupWebViewStore = store
                    store.onPopupNavigationFinished = {
                        [weak viewModel, weak store] _ in
                        guard let viewModel, let store else { return false }
                        return await viewModel.checkLoginStatus(using: store)
                    }
                } else if popupWebViewStore === store {
                    popupWebView = nil
                    popupWebViewStore = nil
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)
            .cornerRadius(DesignTokens.CornerRadius.medium)
    }

    private func closePopupWebView() {
        popupWebViewStore?.closePopupWebView()
        popupWebViewStore = nil
        popupWebView = nil
    }

}

// MARK: - Popup WebView Sheet

/// Sheet for displaying popup windows (e.g., OAuth login flows)
private struct PopupWebViewSheet: View {
    let webView: WKWebView
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Spacer()
                Button("content.popupClose".localized()) {
                    onClose()
                }
            }
            WebViewContainer(webView: webView)
        }
        .padding()
        .frame(minWidth: 520, minHeight: 640)
    }
}

/// NSViewRepresentable wrapper for displaying WKWebView
private struct WebViewContainer: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
    }
}

// MARK: - Usage Summary Views

/// Displays the current usage snapshot with 5-hour and weekly windows
private struct UsageSummaryView: View {
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    let snapshot: UsageSnapshot?
    let displayMode: UsageDisplayMode
    let fetchStatuses: [UsageProvider: ProviderFetchStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            statusSection

            Divider()
                .padding(.vertical, 2)

            usageSection
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            ForEach(UsageProvider.allCases) { provider in
                HStack(spacing: DesignTokens.Spacing.small) {
                    SettingsStatusIndicator(
                        text: provider.displayName,
                        level: statusLevel(for: provider)
                    )
                    Spacer()
                    Text(statusText(for: provider))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var usageSection: some View {
        Group {
            if let snapshot {
                if snapshot.isSingleMonthlyWindow {
                    UsageWindowRow(title: "content.month".localized(), window: snapshot.primaryWindow, displayMode: displayMode)
                } else {
                    UsageWindowRow(title: "content.5hours".localized(), window: snapshot.primaryWindow, displayMode: displayMode)
                    UsageWindowRow(title: "content.week".localized(), window: snapshot.secondaryWindow, displayMode: displayMode)
                }
            } else {
                Text("content.notFetched".localized())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func statusLevel(for provider: UsageProvider) -> SettingsStatusLevel {
        switch fetchStatuses[provider] ?? .notFetched {
        case .success:
            return .success
        case .failure:
            return .error
        case .notFetched:
            return .warning
        }
    }

    private func statusText(for provider: UsageProvider) -> String {
        switch fetchStatuses[provider] ?? .notFetched {
        case .success(let fetchedAt):
            return "usage.updated".localized() + Self.timeFormatter.string(from: fetchedAt)
        case .failure(let message):
            return message
        case .notFetched:
            return "status.notFetched".localized()
        }
    }
}

/// Displays a single usage window row with percentage and reset time
private struct UsageWindowRow: View {
    let title: String
    let window: UsageWindow?
    let displayMode: UsageDisplayMode

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.body)
            Spacer()
            HStack(spacing: 6) {
                Text(windowPercentText)
                    .font(.body)
                    .monospacedDigit()
                Text("•")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text("content.reset".localized())
                    .font(.body)
                    .foregroundStyle(.secondary)
                if let resetAt = window?.resetAt {
                    Text(resetAt, style: .relative)
                        .font(.body)
                        .foregroundStyle(.secondary)
                } else {
                    Text("-")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var windowPercentText: String {
        let percent = window.map { displayMode.displayPercent(from: $0.usedPercent, window: $0) }
        return UsagePercentFormatter.formatPercentText(percent)
    }
}

#if DEBUG
private final class PreviewSessionActivityCredentialStore:
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

nonisolated private struct PreviewGitHubAgentTaskFetcher:
    GitHubAgentTaskFetching {
    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        throw GitHubAgentTaskFetcherError.authenticationRequired
    }
}

#Preview {
    let previewDefaults = UserDefaults(
        suiteName: "AgentLimits.ContentViewPreview"
    )!
    let accountStore = ProviderAccountStore(
        userDefaults: previewDefaults,
        key: "preview_accounts"
    )
    let pool = UsageWebViewPool(
        accountStore: accountStore,
        websiteDataStoreProvider: { _ in .nonPersistent() }
    )
    let viewModel = UsageViewModel(webViewPool: pool)
    let activityViewModel = SessionActivityViewModel(
        accountStore: accountStore,
        credentialStore: PreviewSessionActivityCredentialStore(),
        githubFetcher: PreviewGitHubAgentTaskFetcher()
    )
    let removalManager = ProviderAccountRemovalManager(
        accountStore: accountStore,
        webViewPool: pool,
        activityDataRetirer: activityViewModel
    )
    return ContentView(
        viewModel: viewModel,
        webViewPool: pool,
        sessionActivityViewModel: activityViewModel,
        accountRemovalManager: removalManager
    )
}
#endif
