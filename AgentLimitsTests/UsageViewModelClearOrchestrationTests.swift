import WebKit
import XCTest
@testable import AgentLimits

@MainActor
final class UsageViewModelClearOrchestrationTests: XCTestCase {
    func testClearQuiescesWebsiteDataBeforeDeletingSnapshots() async throws {
        let accountStore = makeProviderAccountStore()
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let usageRepository = OrchestrationAccountUsageSnapshotRepository(
            accounts: accountStore.loadAccounts(),
            snapshots: Dictionary(
                uniqueKeysWithValues: UsageProvider.allCases.map { ($0, makeUsageSnapshot($0)) }
            ),
            visibilityStore: visibilityStore
        )
        let tokenStore = OrchestrationTokenSnapshotStore(
            snapshots: Dictionary(
                uniqueKeysWithValues: TokenUsageProvider.allCases.map {
                    ($0, makeTokenSnapshot($0))
                }
            )
        )
        let websiteDataClearer = RecordingWebsiteDataClearer()
        let activityCredentialStore =
            OrchestrationSessionActivityCredentialStore()
        let activityViewModel = SessionActivityViewModel(
            accountStore: accountStore,
            credentialStore: activityCredentialStore
        )
        activityCredentialStore.onDeleteAll = {
            XCTAssertTrue(websiteDataClearer.didClear)
        }
        usageRepository.onDelete = { _ in
            XCTAssertTrue(websiteDataClearer.didClear)
            XCTAssertEqual(activityCredentialStore.deleteAllCallCount, 1)
        }
        tokenStore.onDelete = {
            XCTAssertTrue(websiteDataClearer.didClear)
            XCTAssertEqual(activityCredentialStore.deleteAllCallCount, 1)
        }
        let tokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore
        )
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: websiteDataClearer
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageRepository: usageRepository,
            tokenViewModel: tokenViewModel,
            sessionActivityDataClearer: activityViewModel
        )

        XCTAssertNotNil(viewModel.snapshot)
        try await viewModel.clearData()

        XCTAssertEqual(websiteDataClearer.clearCount, 1)
        XCTAssertEqual(activityCredentialStore.deleteAllCallCount, 1)
        XCTAssertTrue(usageRepository.snapshotsByAccountID.isEmpty)
        XCTAssertEqual(
            Set(usageRepository.deletionAttempts),
            Set(accountStore.loadAccounts().map(\.id))
        )
        XCTAssertTrue(tokenStore.snapshots.isEmpty)
        XCTAssertEqual(
            Set(tokenStore.deletionAttempts),
            Set(TokenUsageProvider.allCases)
        )
        XCTAssertNil(viewModel.snapshot)
        XCTAssertTrue(viewModel.backgroundActiveAccounts.isEmpty)
        XCTAssertTrue(tokenViewModel.snapshots.isEmpty)
        for account in accountStore.loadAccounts() {
            XCTAssertFalse(usageRepository.isSnapshotSuppressed(for: account))
            XCTAssertTrue(pool.getWebViewStore(for: account).isSuspended)
        }
        for provider in TokenUsageProvider.allCases {
            XCTAssertFalse(
                visibilityStore.isSnapshotSuppressed(
                    fileName: provider.snapshotFileName
                )
            )
        }
        let retryToken = activityViewModel.beginActivityDataClear()
        XCTAssertNotNil(retryToken)
        if let retryToken {
            XCTAssertTrue(
                activityViewModel.finishActivityDataClear(retryToken)
            )
        }
    }

    func testClearRetriesForAccountRegisteredDuringSnapshotDeletion() async throws {
        let accountStore = makeProviderAccountStore()
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let usageRepository = OrchestrationAccountUsageSnapshotRepository(
            accounts: accountStore.loadAccounts(),
            snapshots: [.chatgptCodex: makeUsageSnapshot(.chatgptCodex)],
            visibilityStore: visibilityStore
        )
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
        usageRepository.onDelete = { _ in
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
            usageRepository: usageRepository,
            tokenViewModel: tokenViewModel
        )

        try await viewModel.clearData()

        let account = try XCTUnwrap(addedAccount)
        XCTAssertEqual(websiteDataClearer.clearCount, 3)
        XCTAssertTrue(usageRepository.deletionAttempts.contains(account.id))
        XCTAssertFalse(pool.getWebViewStore(for: account).isDataClearInProgress)
    }

    func testLateAccountAfterInitialTokenSweepAlsoClearsTokenNamespace()
        async throws {
        let accountStore = makeProviderAccountStore()
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let usageRepository = OrchestrationAccountUsageSnapshotRepository(
            accounts: accountStore.loadAccounts(),
            snapshots: [:],
            visibilityStore: visibilityStore
        )
        let tokenRepository = OrchestrationAccountTokenSnapshotRepository()
        let tokenViewModel = TokenUsageViewModel(
            snapshotRepository: tokenRepository,
            accountStore: accountStore,
            settingsStore: CCUsageSettingsStore(
                userDefaults: UserDefaults(
                    suiteName: "LateTokenSweep-\(UUID().uuidString)"
                )!
            )
        )
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: RecordingWebsiteDataClearer(),
            websiteDataStoreProvider: { _ in .nonPersistent() }
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageRepository: usageRepository,
            tokenViewModel: tokenViewModel
        )
        var lateAccount: ProviderAccount?
        usageRepository.onPublish = { _, snapshot in
            guard snapshot == nil, lateAccount == nil else { return }
            do {
                let account = try accountStore.addAccount(
                    provider: .chatgptCodex,
                    label: "Added After Token Sweep",
                    cliDataRoot: "/tmp/agentlimits-late-token"
                )
                lateAccount = account
                tokenRepository.snapshots[account.id] = self.makeTokenSnapshot(
                    .codex
                )
            } catch {
                XCTFail("Could not add late account: \(error)")
            }
        }

        try await viewModel.clearData()

        let account = try XCTUnwrap(lateAccount)
        XCTAssertNil(tokenRepository.snapshots[account.id])
        XCTAssertTrue(
            tokenRepository.deletionAttempts.contains(account.id)
        )
        XCTAssertTrue(
            usageRepository.deletionAttempts.contains(account.id)
        )
        XCTAssertFalse(pool.getWebViewStore(for: account).isDataClearInProgress)
    }

    func testFinalSweepClearsRepublishedProjectionWithoutNewAccount()
        async throws {
        let accountStore = makeProviderAccountStore()
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let usageRepository = OrchestrationAccountUsageSnapshotRepository(
            accounts: accountStore.loadAccounts(),
            snapshots: [:],
            visibilityStore: visibilityStore
        )
        let tokenRepository = OrchestrationAccountTokenSnapshotRepository()
        let tokenViewModel = TokenUsageViewModel(
            snapshotRepository: tokenRepository,
            accountStore: accountStore,
            settingsStore: CCUsageSettingsStore(
                userDefaults: UserDefaults(
                    suiteName: "FinalProjectionSweep-\(UUID().uuidString)"
                )!
            )
        )
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: RecordingWebsiteDataClearer(),
            websiteDataStoreProvider: { _ in .nonPersistent() }
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageRepository: usageRepository,
            tokenViewModel: tokenViewModel
        )
        var didRepublish = false
        usageRepository.onPublish = { _, snapshot in
            guard snapshot == nil, !didRepublish else { return }
            didRepublish = true
            tokenRepository.seedProjection(
                self.makeTokenSnapshot(.codex)
            )
        }

        try await viewModel.clearData()

        XCTAssertTrue(didRepublish)
        XCTAssertNil(tokenRepository.projection(for: .codex))
    }

    func testSuccessfulFinalProjectionRetryClearsEarlierFailure()
        async throws {
        let accountStore = makeProviderAccountStore()
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let usageRepository = OrchestrationAccountUsageSnapshotRepository(
            accounts: accountStore.loadAccounts(),
            snapshots: [:],
            visibilityStore: visibilityStore
        )
        let tokenViewModel = TokenUsageViewModel(
            snapshotRepository: OrchestrationAccountTokenSnapshotRepository(),
            accountStore: accountStore,
            settingsStore: CCUsageSettingsStore(
                userDefaults: UserDefaults(
                    suiteName: "ProjectionRetry-(UUID().uuidString)"
                )!
            )
        )
        let viewModel = makeUsageViewModel(
            pool: UsageWebViewPool(
                accountStore: accountStore,
                websiteDataClearer: RecordingWebsiteDataClearer(),
                websiteDataStoreProvider: { _ in .nonPersistent() }
            ),
            usageRepository: usageRepository,
            tokenViewModel: tokenViewModel
        )
        let baselineAttempts = usageRepository.projectionDeletionAttempts[
            .chatgptCodex
        ] ?? 0
        usageRepository.projectionDeletionFailuresRemaining[
            .chatgptCodex
        ] = 1

        try await viewModel.clearData()

        XCTAssertEqual(
            usageRepository.projectionDeletionAttempts[.chatgptCodex],
            baselineAttempts + 2
        )
        XCTAssertNil(usageRepository.projectionSnapshots[.chatgptCodex])
    }

    func testDeletionFailuresStaySuppressedAcrossRelaunchAndReturnStructuredError() async throws {
        let claudeSnapshot = makeUsageSnapshot(.claudeCode)
        let copilotTokenSnapshot = makeTokenSnapshot(.copilot)
        let accountStore = makeProviderAccountStore()
        let claudeAccount = accountStore.selectedAccount(for: .claudeCode)
        let copilotAccount = accountStore.selectedAccount(
            for: .githubCopilot
        )
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let usageRepository = OrchestrationAccountUsageSnapshotRepository(
            accounts: accountStore.loadAccounts(),
            snapshots: [.claudeCode: claudeSnapshot],
            visibilityStore: visibilityStore
        )
        usageRepository.deletionErrors[claudeAccount.id] = OrchestrationError.deleteFailed
        let tokenStore = OrchestrationTokenSnapshotStore(
            snapshots: [.copilot: copilotTokenSnapshot]
        )
        tokenStore.deletionErrors[.copilot] = OrchestrationError.deleteFailed
        let tokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore
        )
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: RecordingWebsiteDataClearer()
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageRepository: usageRepository,
            tokenViewModel: tokenViewModel,
            selectedProvider: .claudeCode
        )

        do {
            try await viewModel.clearData()
            XCTFail("Expected snapshot deletion failures")
        } catch let error as ClearDataError {
            guard case .snapshotDeletion(let failures) = error else {
                return XCTFail("Unexpected clear error: \(error)")
            }
            XCTAssertEqual(failures.count, 3)
            XCTAssertTrue(failures.contains {
                $0.target == "\(UsageProvider.claudeCode.displayName) — \(claudeAccount.label)"
            })
            XCTAssertTrue(failures.contains {
                $0.target == "Copilot — \(copilotAccount.label)"
            })
            XCTAssertTrue(failures.contains {
                $0.target == "Copilot widget"
            })
        }

        XCTAssertEqual(
            usageRepository.snapshotsByAccountID[claudeAccount.id]?.fetchedAt,
            claudeSnapshot.fetchedAt
        )
        XCTAssertEqual(
            tokenStore.snapshots[.copilot]?.fetchedAt,
            copilotTokenSnapshot.fetchedAt
        )
        XCTAssertEqual(
            Set(tokenStore.deletionAttempts),
            Set(TokenUsageProvider.allCases)
        )
        XCTAssertTrue(usageRepository.isSnapshotSuppressed(for: claudeAccount))
        XCTAssertTrue(
            visibilityStore.isSnapshotSuppressed(
                fileName: TokenUsageProvider.copilot.snapshotFileName
            )
        )

        let relaunchedStateManager = ProviderStateManager(
            accounts: accountStore.loadAccounts()
        )
        relaunchedStateManager.loadCachedSnapshots(
            for: accountStore.loadAccounts(),
            from: usageRepository
        )
        XCTAssertNil(relaunchedStateManager.getState(for: claudeAccount.id).snapshot)

        let relaunchedTokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore
        )
        XCTAssertNil(relaunchedTokenViewModel.snapshots[.copilot])
    }

    func testWebsiteDataFailureDoesNotPartiallyDeleteSnapshots() async throws {
        let snapshot = makeUsageSnapshot(.chatgptCodex)
        let accountStore = makeProviderAccountStore()
        let codexAccount = accountStore.selectedAccount(for: .chatgptCodex)
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let usageRepository = OrchestrationAccountUsageSnapshotRepository(
            accounts: accountStore.loadAccounts(),
            snapshots: [.chatgptCodex: snapshot],
            visibilityStore: visibilityStore
        )
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
        let activityCredentialStore =
            OrchestrationSessionActivityCredentialStore()
        let activityViewModel = SessionActivityViewModel(
            accountStore: accountStore,
            credentialStore: activityCredentialStore
        )
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: websiteDataClearer
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageRepository: usageRepository,
            tokenViewModel: tokenViewModel,
            sessionActivityDataClearer: activityViewModel
        )

        do {
            try await viewModel.clearData()
            XCTFail("Expected website-data failure")
        } catch let error as ClearDataError {
            guard case .websiteData = error else {
                return XCTFail("Unexpected clear error: \(error)")
            }
        }

        XCTAssertEqual(
            usageRepository.snapshotsByAccountID[codexAccount.id]?.fetchedAt,
            snapshot.fetchedAt
        )
        XCTAssertEqual(tokenStore.snapshots.count, TokenUsageProvider.allCases.count)
        XCTAssertEqual(tokenViewModel.snapshots.count, TokenUsageProvider.allCases.count)
        XCTAssertEqual(activityCredentialStore.deleteAllCallCount, 0)
        XCTAssertNotNil(viewModel.snapshot)
        XCTAssertFalse(usageRepository.isSnapshotSuppressed(for: codexAccount))
        XCTAssertFalse(pool.getWebViewStore(for: .chatgptCodex).isDataClearInProgress)
        for provider in TokenUsageProvider.allCases {
            XCTAssertFalse(
                visibilityStore.isSnapshotSuppressed(fileName: provider.snapshotFileName)
            )
        }
        let retryToken = activityViewModel.beginActivityDataClear()
        XCTAssertNotNil(retryToken)
        if let retryToken {
            XCTAssertTrue(
                activityViewModel.finishActivityDataClear(retryToken)
            )
        }
    }

    func testActivityDataFailurePreservesSnapshotsAndReleasesClearGates()
        async throws {
        let accountStore = makeProviderAccountStore()
        let codexAccount = accountStore.selectedAccount(for: .chatgptCodex)
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let usageRepository = OrchestrationAccountUsageSnapshotRepository(
            accounts: accountStore.loadAccounts(),
            snapshots: [.chatgptCodex: makeUsageSnapshot(.chatgptCodex)],
            visibilityStore: visibilityStore
        )
        let tokenStore = OrchestrationTokenSnapshotStore(
            snapshots: [.codex: makeTokenSnapshot(.codex)]
        )
        let tokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore
        )
        let activityCredentialStore =
            OrchestrationSessionActivityCredentialStore()
        activityCredentialStore.deleteAllError =
            OrchestrationError.activityDataFailed
        let activityViewModel = SessionActivityViewModel(
            accountStore: accountStore,
            credentialStore: activityCredentialStore
        )
        let websiteDataClearer = RecordingWebsiteDataClearer()
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: websiteDataClearer
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageRepository: usageRepository,
            tokenViewModel: tokenViewModel,
            sessionActivityDataClearer: activityViewModel
        )

        do {
            try await viewModel.clearData()
            XCTFail("Expected session-activity clear failure")
        } catch let error as ClearDataError {
            guard case .activityData = error else {
                return XCTFail("Unexpected clear error: \(error)")
            }
        }

        XCTAssertEqual(websiteDataClearer.clearCount, 1)
        XCTAssertEqual(activityCredentialStore.deleteAllCallCount, 1)
        XCTAssertNotNil(
            usageRepository.snapshotsByAccountID[codexAccount.id]
        )
        XCTAssertNotNil(tokenStore.snapshots[.codex])
        XCTAssertFalse(
            pool.getWebViewStore(for: codexAccount).isDataClearInProgress
        )

        activityCredentialStore.deleteAllError = nil
        try await viewModel.clearData()

        XCTAssertEqual(websiteDataClearer.clearCount, 2)
        XCTAssertEqual(activityCredentialStore.deleteAllCallCount, 2)
        XCTAssertTrue(usageRepository.snapshotsByAccountID.isEmpty)
        XCTAssertTrue(tokenStore.snapshots.isEmpty)
    }

    func testActivityClearContentionRollsBackOtherClearGates() async throws {
        let accountStore = makeProviderAccountStore()
        let visibilityStore = OrchestrationSnapshotVisibilityStore()
        let usageRepository = OrchestrationAccountUsageSnapshotRepository(
            accounts: accountStore.loadAccounts(),
            snapshots: [.chatgptCodex: makeUsageSnapshot(.chatgptCodex)],
            visibilityStore: visibilityStore
        )
        let tokenStore = OrchestrationTokenSnapshotStore(
            snapshots: [.codex: makeTokenSnapshot(.codex)]
        )
        let tokenViewModel = makeTokenViewModel(
            store: tokenStore,
            visibilityStore: visibilityStore
        )
        let activityCredentialStore =
            OrchestrationSessionActivityCredentialStore()
        let activityViewModel = SessionActivityViewModel(
            accountStore: accountStore,
            credentialStore: activityCredentialStore
        )
        let heldToken = try XCTUnwrap(
            activityViewModel.beginActivityDataClear()
        )
        let websiteDataClearer = RecordingWebsiteDataClearer()
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: websiteDataClearer
        )
        let viewModel = makeUsageViewModel(
            pool: pool,
            usageRepository: usageRepository,
            tokenViewModel: tokenViewModel,
            sessionActivityDataClearer: activityViewModel
        )

        do {
            try await viewModel.clearData()
            XCTFail("Expected session-activity clear contention")
        } catch let error as ClearDataError {
            guard case .activityData = error else {
                return XCTFail("Unexpected clear error: \(error)")
            }
        }

        XCTAssertEqual(websiteDataClearer.clearCount, 0)
        XCTAssertEqual(activityCredentialStore.deleteAllCallCount, 0)
        XCTAssertFalse(usageRepository.snapshotsByAccountID.isEmpty)
        XCTAssertFalse(tokenStore.snapshots.isEmpty)
        XCTAssertTrue(activityViewModel.finishActivityDataClear(heldToken))

        try await viewModel.clearData()
        XCTAssertEqual(websiteDataClearer.clearCount, 1)
        XCTAssertEqual(activityCredentialStore.deleteAllCallCount, 1)
        XCTAssertTrue(usageRepository.snapshotsByAccountID.isEmpty)
        XCTAssertTrue(tokenStore.snapshots.isEmpty)
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
            usageRepository: OrchestrationAccountUsageSnapshotRepository(
                visibilityStore: visibilityStore
            ),
            tokenViewModel: tokenViewModel
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
        usageRepository: OrchestrationAccountUsageSnapshotRepository,
        tokenViewModel: TokenUsageViewModel,
        sessionActivityDataClearer:
            (any SessionActivityDataClearing)? = nil,
        selectedProvider: UsageProvider = .chatgptCodex
    ) -> UsageViewModel {
        let defaults = UserDefaults(
            suiteName: "UsageViewModelClearOrchestrationTests-\(UUID().uuidString)"
        )!
        return UsageViewModel(
            webViewPool: pool,
            snapshotRepository: usageRepository,
            tokenUsageViewModel: tokenViewModel,
            sessionActivityDataClearer: sessionActivityDataClearer,
            displayModeStore: UsageDisplayModeStore(
                userDefaults: defaults,
                appGroupDefaults: nil
            ),
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
private final class OrchestrationAccountUsageSnapshotRepository:
    AccountUsageSnapshotRepository {
    private(set) var snapshotsByAccountID: [UUID: UsageSnapshot]
    private(set) var projectionSnapshots: [UsageProvider: UsageSnapshot] = [:]
    private(set) var deletionAttempts: [UUID] = []
    var deletionErrors: [UUID: Error] = [:]
    var projectionDeletionFailuresRemaining: [UsageProvider: Int] = [:]
    private(set) var projectionDeletionAttempts: [UsageProvider: Int] = [:]
    var onDelete: ((ProviderAccount) -> Void)?
    var onPublish: ((ProviderAccount, UsageSnapshot?) -> Void)?

    private var suppressedAccountIDs: Set<UUID> = []
    private let visibilityStore: OrchestrationSnapshotVisibilityStore

    init(
        accounts: [ProviderAccount] = [],
        snapshots: [UsageProvider: UsageSnapshot] = [:],
        visibilityStore: OrchestrationSnapshotVisibilityStore
    ) {
        self.snapshotsByAccountID = Dictionary(
            uniqueKeysWithValues: accounts.compactMap { account in
                snapshots[account.provider].map { (account.id, $0) }
            }
        )
        self.visibilityStore = visibilityStore
    }

    func loadSnapshot(for account: ProviderAccount) -> UsageSnapshot? {
        guard !suppressedAccountIDs.contains(account.id) else { return nil }
        return snapshotsByAccountID[account.id]
    }

    func saveSnapshot(
        _ snapshot: UsageSnapshot,
        for account: ProviderAccount
    ) throws {
        guard snapshot.provider == account.provider else {
            throw AccountUsageSnapshotRepositoryError.providerMismatch
        }
        snapshotsByAccountID[account.id] = snapshot
    }

    func deleteSnapshot(for account: ProviderAccount) throws {
        onDelete?(account)
        deletionAttempts.append(account.id)
        if let error = deletionErrors[account.id] {
            throw error
        }
        snapshotsByAccountID.removeValue(forKey: account.id)
    }

    func setSnapshotSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) {
        if isSuppressed {
            suppressedAccountIDs.insert(account.id)
        } else {
            suppressedAccountIDs.remove(account.id)
        }
    }

    func publishSelectedSnapshot(
        _ snapshot: UsageSnapshot?,
        for account: ProviderAccount
    ) throws {
        onPublish?(account, snapshot)
        let fileName = account.provider.snapshotFileName
        visibilityStore.setSnapshotSuppressed(true, fileName: fileName)
        if snapshot == nil {
            projectionDeletionAttempts[account.provider, default: 0] += 1
            let failuresRemaining = projectionDeletionFailuresRemaining[
                account.provider,
                default: 0
            ]
            if failuresRemaining > 0 {
                projectionDeletionFailuresRemaining[account.provider] =
                    failuresRemaining - 1
                throw OrchestrationError.deleteFailed
            }
        }
        if let snapshot {
            guard snapshot.provider == account.provider else {
                throw AccountUsageSnapshotRepositoryError.providerMismatch
            }
            projectionSnapshots[account.provider] = snapshot
        } else {
            projectionSnapshots.removeValue(forKey: account.provider)
        }
        visibilityStore.setSnapshotSuppressed(false, fileName: fileName)
    }

    func isSnapshotSuppressed(for account: ProviderAccount) -> Bool {
        suppressedAccountIDs.contains(account.id)
    }
}

@MainActor
private final class OrchestrationAccountTokenSnapshotRepository:
    AccountTokenUsageSnapshotRepository {
    var snapshots: [UUID: TokenUsageSnapshot] = [:]
    private(set) var deletionAttempts: [UUID] = []
    private var suppressedAccountIDs: Set<UUID> = []
    private var projections: [TokenUsageProvider: TokenUsageSnapshot] = [:]

    func seedProjection(_ snapshot: TokenUsageSnapshot) {
        projections[snapshot.provider] = snapshot
    }

    func projection(
        for provider: TokenUsageProvider
    ) -> TokenUsageSnapshot? {
        projections[provider]
    }

    func loadSnapshot(for account: ProviderAccount) -> TokenUsageSnapshot? {
        guard !suppressedAccountIDs.contains(account.id),
              let provider = account.provider.tokenUsageProvider,
              snapshots[account.id]?.provider == provider else {
            return nil
        }
        return snapshots[account.id]
    }

    func saveSnapshot(
        _ snapshot: TokenUsageSnapshot,
        for account: ProviderAccount
    ) throws {
        guard account.provider.tokenUsageProvider == snapshot.provider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        snapshots[account.id] = snapshot
        suppressedAccountIDs.remove(account.id)
    }

    func deleteSnapshot(for account: ProviderAccount) throws {
        deletionAttempts.append(account.id)
        snapshots.removeValue(forKey: account.id)
    }

    func setSnapshotSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) {
        if isSuppressed {
            suppressedAccountIDs.insert(account.id)
        } else {
            suppressedAccountIDs.remove(account.id)
        }
    }

    func publishSelectedSnapshot(
        _ snapshot: TokenUsageSnapshot?,
        for account: ProviderAccount
    ) throws {
        guard let provider = account.provider.tokenUsageProvider else {
            throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
        }
        if let snapshot {
            guard snapshot.provider == provider else {
                throw AccountTokenUsageSnapshotRepositoryError.providerMismatch
            }
            projections[provider] = snapshot
        } else {
            projections.removeValue(forKey: provider)
        }
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

private final class OrchestrationSessionActivityCredentialStore:
    SessionActivityCredentialStoring {
    var credentials: [UUID: String] = [:]
    var deleteAllError: Error?
    var onDeleteAll: (() -> Void)?
    private(set) var deleteAllCallCount = 0

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
        deleteAllCallCount += 1
        onDeleteAll?()
        if let deleteAllError { throw deleteAllError }
        credentials.removeAll()
    }
}

private enum OrchestrationError: LocalizedError {
    case deleteFailed
    case websiteDataFailed
    case activityDataFailed

    var errorDescription: String? {
        switch self {
        case .deleteFailed:
            return "Test deletion failed"
        case .websiteDataFailed:
            return "Test website-data clear failed"
        case .activityDataFailed:
            return "Test session-activity clear failed"
        }
    }
}
