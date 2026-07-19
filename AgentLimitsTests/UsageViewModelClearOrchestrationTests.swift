import WebKit
import XCTest
@testable import AgentLimits

@MainActor
final class UsageViewModelClearOrchestrationTests: XCTestCase {
    func testClearQuiescesWebsiteDataBeforeDeletingSnapshots() async throws {
        let usageStore = OrchestrationUsageSnapshotStore(
            snapshots: Dictionary(
                uniqueKeysWithValues: UsageProvider.allCases.map { ($0, makeUsageSnapshot($0)) }
            )
        )
        let tokenStore = OrchestrationTokenSnapshotStore(
            snapshots: Dictionary(
                uniqueKeysWithValues: TokenUsageProvider.allCases.map {
                    ($0, makeTokenSnapshot($0))
                }
            )
        )
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let websiteDataClearer = RecordingWebsiteDataClearer()
        usageStore.onDelete = {
            XCTAssertTrue(websiteDataClearer.didClear)
        }
        tokenStore.onDelete = {
            XCTAssertTrue(websiteDataClearer.didClear)
        }
        let tokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore
        )
        let pool = UsageWebViewPool(
            accountStore: makeProviderAccountStore(),
            websiteDataClearer: websiteDataClearer
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageStore: usageStore,
            tokenViewModel: tokenViewModel,
            visibilityStore: visibilityStore
        )

        XCTAssertNotNil(viewModel.snapshot)
        try await viewModel.clearData()

        XCTAssertEqual(websiteDataClearer.clearCount, 1)
        XCTAssertTrue(usageStore.snapshots.isEmpty)
        XCTAssertTrue(tokenStore.snapshots.isEmpty)
        XCTAssertEqual(
            Set(tokenStore.deletionAttempts),
            Set(TokenUsageProvider.allCases)
        )
        XCTAssertNil(viewModel.snapshot)
        XCTAssertTrue(viewModel.backgroundActiveProviders.isEmpty)
        XCTAssertTrue(tokenViewModel.snapshots.isEmpty)
        for provider in UsageProvider.allCases {
            XCTAssertFalse(
                visibilityStore.isSnapshotSuppressed(fileName: provider.snapshotFileName)
            )
            XCTAssertTrue(pool.getWebViewStore(for: provider).isSuspended)
        }
        for provider in TokenUsageProvider.allCases {
            XCTAssertFalse(
                visibilityStore.isSnapshotSuppressed(
                    fileName: provider.snapshotFileName
                )
            )
        }
    }

    func testClearRetriesForAccountRegisteredDuringSnapshotDeletion() async throws {
        let accountStore = makeProviderAccountStore()
        let usageStore = OrchestrationUsageSnapshotStore(
            snapshots: [.chatgptCodex: makeUsageSnapshot(.chatgptCodex)]
        )
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let websiteDataClearer = RecordingWebsiteDataClearer()
        let tokenViewModel = makeTokenViewModel(
            store: OrchestrationTokenSnapshotStore(),
            visibilityStore: visibilityStore
        )
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: websiteDataClearer,
            websiteDataStoreProvider: { _ in .nonPersistent() }
        )
        var addedAccount: ProviderAccount?
        usageStore.onDelete = {
            guard addedAccount == nil else { return }
            do {
                addedAccount = try accountStore.addAccount(
                    provider: .chatgptCodex,
                    label: "Added During Deletion"
                )
            } catch {
                XCTFail("Could not add account during deletion: \(error)")
            }
        }
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageStore: usageStore,
            tokenViewModel: tokenViewModel,
            visibilityStore: visibilityStore
        )

        try await viewModel.clearData()

        let account = try XCTUnwrap(addedAccount)
        XCTAssertEqual(websiteDataClearer.clearCount, 3)
        XCTAssertFalse(pool.getWebViewStore(for: account).isDataClearInProgress)
    }

    func testDeletionFailuresStaySuppressedAcrossRelaunchAndReturnStructuredError() async throws {
        let claudeSnapshot = makeUsageSnapshot(.claudeCode)
        let copilotTokenSnapshot = makeTokenSnapshot(.copilot)
        let usageStore = OrchestrationUsageSnapshotStore(
            snapshots: [.claudeCode: claudeSnapshot]
        )
        usageStore.deletionErrors[.claudeCode] = OrchestrationError.deleteFailed
        let tokenStore = OrchestrationTokenSnapshotStore(
            snapshots: [.copilot: copilotTokenSnapshot]
        )
        tokenStore.deletionErrors[.copilot] = OrchestrationError.deleteFailed
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let tokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore
        )
        let pool = UsageWebViewPool(
            accountStore: makeProviderAccountStore(),
            websiteDataClearer: RecordingWebsiteDataClearer()
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageStore: usageStore,
            tokenViewModel: tokenViewModel,
            visibilityStore: visibilityStore,
            selectedProvider: .claudeCode
        )

        do {
            try await viewModel.clearData()
            XCTFail("Expected snapshot deletion failures")
        } catch let error as ClearDataError {
            guard case .snapshotDeletion(let failures) = error else {
                return XCTFail("Unexpected clear error: \(error)")
            }
            XCTAssertEqual(failures.count, 2)
            XCTAssertTrue(failures.contains { $0.target == UsageProvider.claudeCode.displayName })
            XCTAssertTrue(failures.contains { $0.target == "Copilot billing" })
        }

        XCTAssertEqual(usageStore.snapshots[.claudeCode]?.fetchedAt, claudeSnapshot.fetchedAt)
        XCTAssertEqual(
            tokenStore.snapshots[.copilot]?.fetchedAt,
            copilotTokenSnapshot.fetchedAt
        )
        XCTAssertEqual(
            Set(tokenStore.deletionAttempts),
            Set(TokenUsageProvider.allCases)
        )
        XCTAssertTrue(
            visibilityStore.isSnapshotSuppressed(
                fileName: UsageProvider.claudeCode.snapshotFileName
            )
        )
        XCTAssertTrue(
            visibilityStore.isSnapshotSuppressed(
                fileName: TokenUsageProvider.copilot.snapshotFileName
            )
        )

        let relaunchedStateManager = ProviderStateManager()
        relaunchedStateManager.loadCachedSnapshots(
            from: usageStore,
            snapshotVisibilityStore: visibilityStore
        )
        XCTAssertNil(relaunchedStateManager.getState(for: .claudeCode).snapshot)

        let relaunchedTokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore
        )
        XCTAssertNil(relaunchedTokenViewModel.snapshots[.copilot])
    }

    func testWebsiteDataFailureDoesNotPartiallyDeleteSnapshots() async throws {
        let snapshot = makeUsageSnapshot(.chatgptCodex)
        let usageStore = OrchestrationUsageSnapshotStore(
            snapshots: [.chatgptCodex: snapshot]
        )
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let websiteDataClearer = RecordingWebsiteDataClearer(
            error: OrchestrationError.websiteDataFailed
        )
        let tokenSnapshots = Dictionary(
            uniqueKeysWithValues: TokenUsageProvider.allCases.map {
                ($0, makeTokenSnapshot($0))
            }
        )
        let tokenStore = OrchestrationTokenSnapshotStore(snapshots: tokenSnapshots)
        let tokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore
        )
        let pool = UsageWebViewPool(
            accountStore: makeProviderAccountStore(),
            websiteDataClearer: websiteDataClearer
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageStore: usageStore,
            tokenViewModel: tokenViewModel,
            visibilityStore: visibilityStore
        )

        do {
            try await viewModel.clearData()
            XCTFail("Expected website-data failure")
        } catch let error as ClearDataError {
            guard case .websiteData = error else {
                return XCTFail("Unexpected clear error: \(error)")
            }
        }

        XCTAssertEqual(usageStore.snapshots[.chatgptCodex]?.fetchedAt, snapshot.fetchedAt)
        XCTAssertEqual(tokenStore.snapshots.count, TokenUsageProvider.allCases.count)
        XCTAssertEqual(tokenViewModel.snapshots.count, TokenUsageProvider.allCases.count)
        XCTAssertNotNil(viewModel.snapshot)
        XCTAssertFalse(
            visibilityStore.isSnapshotSuppressed(
                fileName: UsageProvider.chatgptCodex.snapshotFileName
            )
        )
        XCTAssertFalse(pool.getWebViewStore(for: .chatgptCodex).isDataClearInProgress)
        for provider in TokenUsageProvider.allCases {
            XCTAssertFalse(
                visibilityStore.isSnapshotSuppressed(fileName: provider.snapshotFileName)
            )
        }
    }

    func testTokenRefreshRemainsBlockedThroughoutWebsiteDataClear() async throws {
        let websiteDataClearer = OrchestrationSuspendingWebsiteDataClearer()
        let tokenStore = OrchestrationTokenSnapshotStore()
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let fetcher = OrchestrationRecordingCCUsageFetcher()
        let tokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore,
            fetcher: fetcher
        )
        let viewModel = makeUsageViewModel(
            pool: UsageWebViewPool(
                accountStore: makeProviderAccountStore(),
                websiteDataClearer: websiteDataClearer
            ),
            usageStore: OrchestrationUsageSnapshotStore(),
            tokenViewModel: tokenViewModel,
            visibilityStore: visibilityStore
        )

        let clearTask = Task { try await viewModel.clearData() }
        await websiteDataClearer.waitUntilStarted()

        await tokenViewModel.refreshNow(for: .codex)
        XCTAssertEqual(fetcher.requestCount, 0)

        websiteDataClearer.finish()
        try await clearTask.value
    }

    private func makeUsageViewModel(
        pool: UsageWebViewPool,
        usageStore: OrchestrationUsageSnapshotStore,
        tokenViewModel: TokenUsageViewModel,
        visibilityStore: OrchestrationSnapshotVisibilityStore,
        selectedProvider: UsageProvider = .chatgptCodex
    ) -> UsageViewModel {
        let defaults = UserDefaults(
            suiteName: "UsageViewModelClearOrchestrationTests-\(UUID().uuidString)"
        )!
        return UsageViewModel(
            webViewPool: pool,
            store: usageStore,
            tokenUsageViewModel: tokenViewModel,
            displayModeStore: UsageDisplayModeStore(
                userDefaults: defaults,
                appGroupDefaults: nil
            ),
            snapshotVisibilityStore: visibilityStore,
            selectedProvider: selectedProvider
        )
    }

    private func makeProviderAccountStore() -> ProviderAccountStore {
        let defaults = UserDefaults(
            suiteName: "UsageViewModelClearAccounts-\(UUID().uuidString)"
        )!
        return ProviderAccountStore(
            userDefaults: defaults,
            key: "test_accounts"
        )
    }

    private func makeTokenViewModel(
        store: OrchestrationTokenSnapshotStore,
        visibilityStore: OrchestrationSnapshotVisibilityStore,
        fetcher: (any CCUsageFetching)? = nil
    ) -> TokenUsageViewModel {
        let defaults = UserDefaults(
            suiteName: "UsageViewModelClearTokenTests-\(UUID().uuidString)"
        )!
        return TokenUsageViewModel(
            fetcher: fetcher,
            snapshotStore: store,
            settingsStore: CCUsageSettingsStore(userDefaults: defaults),
            snapshotVisibilityStore: visibilityStore
        )
    }

    private func makeUsageSnapshot(_ provider: UsageProvider) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            fetchedAt: Date(timeIntervalSince1970: Double(provider.rawValue.count * 100)),
            primaryWindow: UsageWindow(
                kind: .primary,
                usedPercent: 50,
                resetAt: Date(timeIntervalSince1970: 5_000),
                limitWindowSeconds: UsageLimitDuration.fiveHours
            ),
            secondaryWindow: nil
        )
    }

    private func makeTokenSnapshot(_ provider: TokenUsageProvider) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            provider: provider,
            fetchedAt: Date(timeIntervalSince1970: Double(9_000 + provider.rawValue.count)),
            today: TokenUsagePeriod(costUSD: 1, totalTokens: 10),
            thisWeek: TokenUsagePeriod(costUSD: 2, totalTokens: 20),
            thisMonth: TokenUsagePeriod(costUSD: 3, totalTokens: 30)
        )
    }
}

@MainActor
private final class OrchestrationUsageSnapshotStore: UsageSnapshotStoring {
    var snapshots: [UsageProvider: UsageSnapshot]
    var deletionErrors: [UsageProvider: Error] = [:]
    var onDelete: (() -> Void)?

    init(snapshots: [UsageProvider: UsageSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    func loadSnapshot(for provider: UsageProvider) -> UsageSnapshot? {
        snapshots[provider]
    }

    func saveSnapshot(_ snapshot: UsageSnapshot) throws {
        snapshots[snapshot.provider] = snapshot
    }

    func deleteSnapshot(for provider: UsageProvider) throws {
        onDelete?()
        if let error = deletionErrors[provider] {
            throw error
        }
        snapshots.removeValue(forKey: provider)
    }
}

@MainActor
private final class OrchestrationTokenSnapshotStore: TokenUsageSnapshotStoring {
    var snapshots: [TokenUsageProvider: TokenUsageSnapshot]
    var deletionErrors: [TokenUsageProvider: Error] = [:]
    var onDelete: (() -> Void)?
    private(set) var deletionAttempts: [TokenUsageProvider] = []

    init(snapshots: [TokenUsageProvider: TokenUsageSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    func loadSnapshot(for provider: TokenUsageProvider) -> TokenUsageSnapshot? {
        snapshots[provider]
    }

    func saveSnapshot(_ snapshot: TokenUsageSnapshot) throws {
        snapshots[snapshot.provider] = snapshot
    }

    func deleteSnapshot(for provider: TokenUsageProvider) throws {
        onDelete?()
        deletionAttempts.append(provider)
        if let error = deletionErrors[provider] {
            throw error
        }
        snapshots.removeValue(forKey: provider)
    }
}

private final class OrchestrationSnapshotVisibilityStore: SnapshotVisibilityControlling, @unchecked Sendable {
    private var suppressedFileNames: Set<String> = []

    func isSnapshotSuppressed(fileName: String) -> Bool {
        suppressedFileNames.contains(fileName)
    }

    func setSnapshotSuppressed(_ isSuppressed: Bool, fileName: String) {
        if isSuppressed {
            suppressedFileNames.insert(fileName)
        } else {
            suppressedFileNames.remove(fileName)
        }
    }
}

@MainActor
private final class RecordingWebsiteDataClearer: WebsiteDataClearing {
    private(set) var clearCount = 0
    private(set) var didClear = false
    private(set) var identifiers: [UUID?] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws {
        clearCount += 1
        identifiers.append(dataStore.identifier)
        if let error {
            throw error
        }
        didClear = true
    }
}

@MainActor
private final class OrchestrationSuspendingWebsiteDataClearer: WebsiteDataClearing {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}

@MainActor
private final class OrchestrationRecordingCCUsageFetcher: CCUsageFetching {
    private(set) var requestCount = 0

    func fetchSnapshot(for provider: TokenUsageProvider) async throws -> TokenUsageSnapshot {
        requestCount += 1
        return TokenUsageSnapshot(
            provider: provider,
            fetchedAt: Date(timeIntervalSince1970: 12_000),
            today: TokenUsagePeriod(costUSD: 1, totalTokens: 10),
            thisWeek: TokenUsagePeriod(costUSD: 2, totalTokens: 20),
            thisMonth: TokenUsagePeriod(costUSD: 3, totalTokens: 30)
        )
    }
}

private enum OrchestrationError: LocalizedError {
    case deleteFailed
    case websiteDataFailed

    var errorDescription: String? {
        switch self {
        case .deleteFailed:
            return "Test deletion failed"
        case .websiteDataFailed:
            return "Test website-data clear failed"
        }
    }
}
