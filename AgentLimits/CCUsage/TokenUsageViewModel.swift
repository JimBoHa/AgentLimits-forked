// MARK: - TokenUsageViewModel.swift
// State management for ccusage token usage data with auto-refresh support.

import Foundation
import Combine
import WidgetKit

/// Storage boundary used to keep token-usage state and persistence coordinated.
protocol TokenUsageSnapshotStoring {
    func loadSnapshot(for provider: TokenUsageProvider) -> TokenUsageSnapshot?
    func saveSnapshot(_ snapshot: TokenUsageSnapshot) throws
    func deleteSnapshot(for provider: TokenUsageProvider) throws
}

extension AppGroupSnapshotStore: TokenUsageSnapshotStoring
    where Provider == TokenUsageProvider, Snapshot == TokenUsageSnapshot {}

protocol CCUsageFetching {
    func fetchSnapshot(for provider: TokenUsageProvider) async throws -> TokenUsageSnapshot
}

extension CCUsageFetcher: CCUsageFetching {}

struct TokenUsageSnapshotClearFailure {
    let provider: TokenUsageProvider
    let reason: String
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
            return failure.reason
        }
    }
}

/// ViewModel for managing ccusage token usage data
@MainActor
final class TokenUsageViewModel: ObservableObject {
    struct ExternalSnapshotContext: Equatable {
        fileprivate let value: UsageOperationGate.Context
        fileprivate let provider: TokenUsageProvider
        fileprivate let settingsRevision: UInt64
        fileprivate let requestIdentifier: UInt64
    }

    struct DataClearToken: Equatable {
        fileprivate let value: UsageOperationGate.ClearToken
    }

    // MARK: - Published Properties

    /// Token usage snapshots per provider
    @Published private(set) var snapshots: [TokenUsageProvider: TokenUsageSnapshot] = [:]
    /// Status messages per provider
    @Published private(set) var statusMessages: [TokenUsageProvider: String] = [:]
    /// Fetching state per provider
    @Published private(set) var isFetching: [TokenUsageProvider: Bool] = [:]
    /// Settings per provider
    @Published var settings: [TokenUsageProvider: CCUsageSettings] = [:]
    /// Whether auto-refresh is enabled
    @Published var isAutoRefreshEnabled: Bool = true

    // MARK: - Private Properties

    private let fetcher: any CCUsageFetching
    private let snapshotStore: any TokenUsageSnapshotStoring
    private let settingsStore: CCUsageSettingsStore
    private let snapshotVisibilityStore: any SnapshotVisibilityControlling
    private var autoRefreshCoordinator: AutoRefreshCoordinator?
    private var suppressedSnapshots: Set<TokenUsageProvider> = []
    private var operationGate = UsageOperationGate()
    private var settingsRevisions: [TokenUsageProvider: UInt64] = [:]
    private var latestExternalRequestIdentifiers: [TokenUsageProvider: UInt64] = [:]
    private var nextExternalRequestIdentifier: UInt64 = 0

    // MARK: - Initialization

    init(
        fetcher: (any CCUsageFetching)? = nil,
        snapshotStore: (any TokenUsageSnapshotStoring)? = nil,
        settingsStore: CCUsageSettingsStore? = nil,
        snapshotVisibilityStore: (any SnapshotVisibilityControlling)? = nil
    ) {
        let resolvedFetcher = fetcher ?? CCUsageFetcher()
        let resolvedSnapshotStore = snapshotStore ?? TokenUsageSnapshotStore.shared
        let resolvedSettingsStore = settingsStore ?? .shared

        self.fetcher = resolvedFetcher
        self.snapshotStore = resolvedSnapshotStore
        self.settingsStore = resolvedSettingsStore
        let resolvedSnapshotVisibilityStore = snapshotVisibilityStore ?? SnapshotVisibilityStore.shared
        self.snapshotVisibilityStore = resolvedSnapshotVisibilityStore

        // Load settings
        settings = resolvedSettingsStore.loadSettings()

        // Initialize state for all providers
        for provider in TokenUsageProvider.allCases {
            settingsRevisions[provider] = 0
            isFetching[provider] = false
            statusMessages[provider] = "tokenUsage.notFetched".localized()

            // Load cached snapshot
            if !resolvedSnapshotVisibilityStore.isSnapshotSuppressed(fileName: provider.snapshotFileName),
               let cached = resolvedSnapshotStore.loadSnapshot(for: provider) {
                snapshots[provider] = cached
                // Show last updated time for cached snapshot.
                statusMessages[provider] = formatLastUpdated(cached.fetchedAt)
            }
        }
    }

    // MARK: - Settings Management

    /// Updates settings for a provider
    func updateSettings(_ newSettings: CCUsageSettings) {
        if settings[newSettings.provider]?.isEnabled != newSettings.isEnabled {
            settingsRevisions[newSettings.provider, default: 0] &+= 1
        }
        // Persist updated settings for the selected provider.
        settings[newSettings.provider] = newSettings
        settingsStore.updateSettings(newSettings)
    }

    // MARK: - Auto Refresh

    /// Starts the auto-refresh timer.
    /// Uses AutoRefreshCoordinator to manage timer lifecycle.
    func startAutoRefresh() {
        guard autoRefreshCoordinator == nil else { return }
        autoRefreshCoordinator = AutoRefreshCoordinator(
            intervalProvider: { TokenUsageRefreshConfig.refreshIntervalDuration },
            refreshHandler: { [weak self] in
                // Skip refresh when disabled in UI.
                guard let self, self.isAutoRefreshEnabled else { return }
                await self.refreshEnabledProviders()
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

    /// Refreshes data for a single provider
    func refreshNow(for provider: TokenUsageProvider) async {
        await refresh(for: provider)
    }

    /// Refreshes data for all enabled providers
    func refreshEnabledProviders() async {
        await withTaskGroup(of: Void.self) { group in
            for provider in TokenUsageProvider.allCases {
                guard settings[provider]?.isEnabled == true else { continue }
                group.addTask {
                    // Refresh each enabled provider in parallel.
                    await self.refresh(for: provider)
                }
            }
        }
    }

    // MARK: - Externally Fetched Snapshots

    /// Captures the provider setting and clear-data generation before external
    /// async work starts. Disabled providers cannot begin external fetches.
    func captureExternalSnapshotContext(
        for provider: TokenUsageProvider
    ) -> ExternalSnapshotContext? {
        guard settings[provider]?.isEnabled == true,
              let value = operationGate.captureContext() else {
            return nil
        }
        nextExternalRequestIdentifier &+= 1
        let requestIdentifier = nextExternalRequestIdentifier
        latestExternalRequestIdentifiers[provider] = requestIdentifier
        return ExternalSnapshotContext(
            value: value,
            provider: provider,
            settingsRevision: settingsRevisions[provider, default: 0],
            requestIdentifier: requestIdentifier
        )
    }

    /// Persists a WebView-produced snapshot and updates the shared in-memory UI state.
    @discardableResult
    func saveExternallyFetchedSnapshot(
        _ snapshot: TokenUsageSnapshot,
        context: ExternalSnapshotContext
    ) throws -> Bool {
        let operationContext = context.value
        guard context.provider == snapshot.provider,
              settings[snapshot.provider]?.isEnabled == true,
              settingsRevisions[snapshot.provider, default: 0] == context.settingsRevision,
              latestExternalRequestIdentifiers[snapshot.provider] == context.requestIdentifier,
              operationGate.isCurrent(operationContext) else {
            return false
        }
        do {
            try snapshotStore.saveSnapshot(snapshot)
            snapshotVisibilityStore.setSnapshotSuppressed(
                false,
                fileName: snapshot.provider.snapshotFileName
            )
            suppressedSnapshots.remove(snapshot.provider)
            snapshots[snapshot.provider] = snapshot
            statusMessages[snapshot.provider] = formatLastUpdated(snapshot.fetchedAt)
            WidgetCenter.shared.reloadTimelines(ofKind: snapshot.provider.widgetKind)
            return true
        } catch {
            guard operationGate.isCurrent(operationContext) else { return false }
            statusMessages[snapshot.provider] = error.localizedDescription
            throw error
        }
    }

    /// Invalidates every in-flight token fetch and blocks new work while the
    /// surrounding Clear Data transaction removes WebKit and snapshot data.
    func beginDataClear() -> DataClearToken? {
        guard let token = operationGate.beginClear() else { return nil }
        for provider in TokenUsageProvider.allCases {
            isFetching[provider] = false
        }
        return DataClearToken(value: token)
    }

    /// Finishes only the matching token-data clear operation.
    @discardableResult
    func finishDataClear(_ token: DataClearToken) -> Bool {
        operationGate.finishClear(token.value)
    }

    /// Deletes all token providers while preserving a durable suppression
    /// marker for every file whose deletion fails.
    func clearAllSnapshots(
        during token: DataClearToken
    ) -> [TokenUsageSnapshotClearFailure] {
        guard operationGate.isCurrent(token.value) else {
            return TokenUsageProvider.allCases.map {
                TokenUsageSnapshotClearFailure(
                    provider: $0,
                    reason: TokenUsageSnapshotClearError.invalidClearOperation.localizedDescription
                )
            }
        }
        return clearSnapshots(for: TokenUsageProvider.allCases)
    }

    /// Clears both persisted and in-memory state. Memory is cleared even when
    /// disk deletion fails so Clear Data cannot leave stale data on screen.
    func clearSnapshot(for provider: TokenUsageProvider) throws {
        guard let clearToken = beginDataClear() else {
            throw TokenUsageSnapshotClearError.clearAlreadyInProgress
        }
        defer { _ = finishDataClear(clearToken) }
        guard let failure = clearSnapshots(for: [provider]).first else { return }
        throw TokenUsageSnapshotClearError.deletion(failure)
    }

    private func clearSnapshots(
        for providers: [TokenUsageProvider]
    ) -> [TokenUsageSnapshotClearFailure] {
        var failures: [TokenUsageSnapshotClearFailure] = []
        for provider in providers {
            if let failure = clearSnapshotStorage(for: provider) {
                failures.append(failure)
            }
        }
        return failures
    }

    private func clearSnapshotStorage(
        for provider: TokenUsageProvider
    ) -> TokenUsageSnapshotClearFailure? {
        // Prevent a cached disk read from restoring this snapshot while the
        // surrounding WebKit clear is still completing (or after delete fails).
        suppressedSnapshots.insert(provider)
        snapshotVisibilityStore.setSnapshotSuppressed(true, fileName: provider.snapshotFileName)
        let deletionError: Error?
        do {
            try snapshotStore.deleteSnapshot(for: provider)
            snapshotVisibilityStore.setSnapshotSuppressed(false, fileName: provider.snapshotFileName)
            deletionError = nil
        } catch {
            deletionError = error
        }

        snapshots.removeValue(forKey: provider)
        isFetching[provider] = false
        statusMessages[provider] = deletionError?.localizedDescription
            ?? "tokenUsage.notFetched".localized()
        WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)

        if let deletionError {
            return TokenUsageSnapshotClearFailure(
                provider: provider,
                reason: deletionError.localizedDescription
            )
        }
        return nil
    }

    // MARK: - Private Methods

    private func refresh(for provider: TokenUsageProvider) async {
        guard let fetchToken = operationGate.beginFetch(for: provider.usageProvider) else {
            return
        }
        isFetching[provider] = true
        defer {
            if operationGate.finishFetch(fetchToken) {
                isFetching[provider] = false
            }
        }

        // Copilot billing is fetched via UsageViewModel (WebView-based).
        // Only reload the cached snapshot here.
        guard provider.isCLIBased else {
            guard !suppressedSnapshots.contains(provider) else { return }
            guard !snapshotVisibilityStore.isSnapshotSuppressed(fileName: provider.snapshotFileName) else {
                return
            }
            guard operationGate.isCurrent(fetchToken) else { return }
            if let cached = snapshotStore.loadSnapshot(for: provider) {
                guard operationGate.isCurrent(fetchToken) else { return }
                snapshots[provider] = cached
                statusMessages[provider] = formatLastUpdated(cached.fetchedAt)
            }
            return
        }

        do {
            // Fetch snapshot via CLI and persist to App Group store.
            let snapshot = try await fetcher.fetchSnapshot(for: provider)
            guard operationGate.isCurrent(fetchToken) else { return }
            try snapshotStore.saveSnapshot(snapshot)
            snapshotVisibilityStore.setSnapshotSuppressed(
                false,
                fileName: snapshot.provider.snapshotFileName
            )
            suppressedSnapshots.remove(snapshot.provider)
            snapshots[provider] = snapshot
            statusMessages[provider] = formatLastUpdated(snapshot.fetchedAt)
            // Notify widgets to update with latest data.
            WidgetCenter.shared.reloadTimelines(ofKind: provider.widgetKind)
        } catch {
            guard operationGate.isCurrent(fetchToken) else { return }
            // Report error to UI.
            statusMessages[provider] = error.localizedDescription
        }
    }

    /// Formats the last updated time for display.
    /// Uses a cached DateFormatter to avoid repeated allocations.
    /// - Parameter date: The date to format
    /// - Returns: Localized string like "Updated: 10:30 AM"
    private func formatLastUpdated(_ date: Date) -> String {
        // Format timestamp for display with localized prefix.
        return "tokenUsage.updated".localized() + Self.timeFormatter.string(from: date)
    }

    // MARK: - Static Date Formatters

    /// Cached time formatter for displaying last updated time (short time style only)
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
