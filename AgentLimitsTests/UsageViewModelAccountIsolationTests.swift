import WebKit
import XCTest
@testable import AgentLimits

@MainActor
final class UsageViewModelAccountIsolationTests: XCTestCase {
    func testFetchCompletionAfterSelectionSwitchWritesOnlyOriginAccount() async throws {
        let fixture = try makeFixture(
            initialSnapshots: { personal, work in
                [
                    personal.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 100
                    ),
                    work.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 200
                    )
                ]
            }
        )
        let personalStore = fixture.pool.getWebViewStore(
            for: fixture.personal
        )
        personalStore.isPageReady = true

        let fetchTask = Task {
            await fixture.viewModel.refreshNow(for: .chatgptCodex)
        }
        await fixture.fetcher.waitUntilRequested(using: personalStore.webView)

        try fixture.viewModel.selectAccount(id: fixture.work.id)
        XCTAssertEqual(fixture.viewModel.snapshot?.fetchedAt, Date(timeIntervalSince1970: 200))

        fixture.fetcher.complete(
            using: personalStore.webView,
            with: makeSnapshot(.chatgptCodex, timestamp: 300)
        )
        await fetchTask.value

        XCTAssertEqual(
            fixture.repository.snapshots[fixture.personal.id]?.fetchedAt,
            Date(timeIntervalSince1970: 300)
        )
        XCTAssertEqual(
            fixture.repository.snapshots[fixture.work.id]?.fetchedAt,
            Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(
            fixture.viewModel.snapshot?.fetchedAt,
            Date(timeIntervalSince1970: 200)
        )
        XCTAssertEqual(
            fixture.repository.projections[.chatgptCodex]?.fetchedAt,
            Date(timeIntervalSince1970: 200)
        )
    }

    func testSameProviderSiblingFetchesCanCompleteOutOfOrder() async throws {
        let fixture = try makeFixture()
        let personalStore = fixture.pool.getWebViewStore(
            for: fixture.personal
        )
        personalStore.isPageReady = true
        let personalTask = Task {
            await fixture.viewModel.refreshNow(for: .chatgptCodex)
        }
        await fixture.fetcher.waitUntilRequested(using: personalStore.webView)

        try fixture.viewModel.selectAccount(id: fixture.work.id)
        let workStore = fixture.pool.getWebViewStore(for: fixture.work)
        workStore.isPageReady = true
        let workTask = Task {
            await fixture.viewModel.refreshNow(for: .chatgptCodex)
        }
        await fixture.fetcher.waitUntilRequested(using: workStore.webView)

        fixture.fetcher.complete(
            using: workStore.webView,
            with: makeSnapshot(.chatgptCodex, timestamp: 400)
        )
        await workTask.value
        fixture.fetcher.complete(
            using: personalStore.webView,
            with: makeSnapshot(.chatgptCodex, timestamp: 500)
        )
        await personalTask.value

        XCTAssertEqual(
            fixture.repository.snapshots[fixture.personal.id]?.fetchedAt,
            Date(timeIntervalSince1970: 500)
        )
        XCTAssertEqual(
            fixture.repository.snapshots[fixture.work.id]?.fetchedAt,
            Date(timeIntervalSince1970: 400)
        )
        XCTAssertEqual(
            fixture.viewModel.snapshot?.fetchedAt,
            Date(timeIntervalSince1970: 400)
        )
        XCTAssertEqual(
            Set(fixture.viewModel.backgroundActiveAccounts.map(\.id)),
            Set([fixture.personal.id, fixture.work.id])
        )
    }

    func testRetirementInvalidatesFetchBeforeAccountDataCanBeDeleted() async throws {
        let fixture = try makeFixture(
            initialSnapshots: { personal, work in
                [
                    personal.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 100
                    ),
                    work.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 200
                    )
                ]
            }
        )
        let personalStore = fixture.pool.getWebViewStore(
            for: fixture.personal
        )
        personalStore.isPageReady = true
        let fetchTask = Task {
            await fixture.viewModel.refreshNow(for: .chatgptCodex)
        }
        await fixture.fetcher.waitUntilRequested(using: personalStore.webView)

        let plan = try fixture.accountStore.prepareRemoval(
            id: fixture.personal.id
        )
        let retirement = try fixture.pool.beginAccountRetirement(plan)
        XCTAssertEqual(
            fixture.repository.projections[.chatgptCodex]?.fetchedAt,
            Date(timeIntervalSince1970: 200)
        )
        fixture.fetcher.complete(
            using: personalStore.webView,
            with: makeSnapshot(.chatgptCodex, timestamp: 600)
        )
        await fetchTask.value

        XCTAssertFalse(
            fixture.repository.saveAttempts.contains(fixture.personal.id)
        )
        XCTAssertFalse(
            fixture.viewModel.snapshotsByAccountID.keys.contains(
                fixture.personal.id
            )
        )
        XCTAssertNil(fixture.tokenViewModel.snapshot(for: fixture.personal.id))
        XCTAssertTrue(fixture.pool.cancelAccountRetirement(retirement))
        XCTAssertEqual(
            fixture.viewModel.snapshot(for: fixture.personal.id)?.fetchedAt,
            Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(
            fixture.tokenViewModel.snapshot(for: fixture.personal.id)?.fetchedAt,
            Date(timeIntervalSince1970: 1_001)
        )
    }

    func testRetirementCancellationDoesNotResurrectDeletedLocalSnapshots()
        throws {
        let fixture = try makeFixture(
            initialSnapshots: { personal, _ in
                [
                    personal.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 100
                    )
                ]
            }
        )
        let plan = try fixture.accountStore.prepareRemoval(
            id: fixture.personal.id
        )
        let retirement = try fixture.pool.beginAccountRetirement(plan)

        XCTAssertNil(fixture.viewModel.snapshot(for: fixture.personal.id))
        XCTAssertNil(fixture.tokenViewModel.snapshot(for: fixture.personal.id))
        try fixture.repository.deleteSnapshot(for: fixture.personal)
        try fixture.tokenRepository.deleteSnapshot(for: fixture.personal)

        XCTAssertTrue(fixture.pool.cancelAccountRetirement(retirement))
        XCTAssertNil(fixture.viewModel.snapshot(for: fixture.personal.id))
        XCTAssertNil(fixture.tokenViewModel.snapshot(for: fixture.personal.id))
    }

    func testGlobalClearRejectsFetchCompletionAfterDeletion() async throws {
        let fixture = try makeFixture(quiescenceTimeout: .seconds(2))
        let personalStore = fixture.pool.getWebViewStore(
            for: fixture.personal
        )
        personalStore.isPageReady = true
        let fetchTask = Task {
            await fixture.viewModel.refreshNow(for: .chatgptCodex)
        }
        await fixture.fetcher.waitUntilRequested(using: personalStore.webView)

        try await fixture.viewModel.clearData()

        fixture.fetcher.complete(
            using: personalStore.webView,
            with: makeSnapshot(.chatgptCodex, timestamp: 700)
        )
        await fetchTask.value

        XCTAssertNil(fixture.repository.snapshots[fixture.personal.id])
        XCTAssertFalse(
            fixture.repository.saveAttempts.contains(fixture.personal.id)
        )
        XCTAssertNil(fixture.viewModel.snapshot)
    }

    func testFailedClearLockStillResetsInvalidatedFetchingState() async throws {
        let fixture = try makeFixture()
        let personalStore = fixture.pool.getWebViewStore(
            for: fixture.personal
        )
        personalStore.isPageReady = true
        let fetchTask = Task {
            await fixture.viewModel.refreshNow(for: .chatgptCodex)
        }
        await fixture.fetcher.waitUntilRequested(using: personalStore.webView)
        XCTAssertTrue(fixture.viewModel.isFetching)

        let competingClear = try XCTUnwrap(fixture.pool.beginDataClear())
        do {
            try await fixture.viewModel.clearData()
            XCTFail("Expected the WebKit clear lock to be unavailable")
        } catch let error as ClearDataError {
            guard case .websiteData = error else {
                return XCTFail("Unexpected clear error: \(error)")
            }
        }
        XCTAssertFalse(fixture.viewModel.isFetching)

        fixture.fetcher.complete(
            using: personalStore.webView,
            with: makeSnapshot(.chatgptCodex, timestamp: 800)
        )
        await fetchTask.value
        XCTAssertFalse(
            fixture.repository.saveAttempts.contains(fixture.personal.id)
        )
        XCTAssertTrue(fixture.pool.cancelDataClear(competingClear))
    }

    func testCatalogSynchronizationReconcilesEveryBackgroundAccount() throws {
        let fixture = try makeFixture(
            initialSnapshots: { personal, work in
                [
                    personal.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 900
                    ),
                    work.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 901
                    )
                ]
            }
        )
        let personalStore = fixture.pool.getWebViewStore(
            for: fixture.personal
        )
        let workStore = fixture.pool.getWebViewStore(for: fixture.work)

        fixture.viewModel.reloadAccounts()
        XCTAssertFalse(personalStore.isSuspended)
        XCTAssertFalse(workStore.isSuspended)

        try fixture.accountStore.updateAccount(
            fixture.personal.updating(
                label: fixture.personal.label,
                isEnabled: false,
                cliDataRoot: fixture.personal.cliDataRoot
            )
        )
        fixture.viewModel.reloadAccounts()

        XCTAssertTrue(personalStore.isSuspended)
        XCTAssertFalse(workStore.isSuspended)
        XCTAssertEqual(
            fixture.viewModel.backgroundActiveAccounts.map(\.id),
            [fixture.work.id]
        )
    }

    func testSelectionHidesPriorProjectionBeforePersistingNewAccount() throws {
        let fixture = try makeFixture(
            initialSnapshots: { personal, work in
                [
                    personal.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 1_000
                    ),
                    work.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 1_001
                    )
                ]
            }
        )
        var events: [(
            publishedAccountID: UUID,
            snapshotWasNil: Bool,
            selectedAccountID: UUID
        )] = []
        fixture.repository.onPublish = { account, snapshot in
            events.append((
                account.id,
                snapshot == nil,
                fixture.accountStore.selectedAccount(
                    for: account.provider
                ).id
            ))
        }

        try fixture.viewModel.selectAccount(id: fixture.work.id)

        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].publishedAccountID, fixture.personal.id)
        XCTAssertTrue(events[0].snapshotWasNil)
        XCTAssertEqual(events[0].selectedAccountID, fixture.personal.id)
        XCTAssertEqual(events[1].publishedAccountID, fixture.work.id)
        XCTAssertFalse(events[1].snapshotWasNil)
        XCTAssertEqual(events[1].selectedAccountID, fixture.work.id)
    }

    func testAccountFacadeAddsSelectsAndCreatesIsolatedSession() throws {
        let fixture = try makeFixture()
        let personalStore = fixture.pool.getWebViewStore(
            for: fixture.personal
        )

        let added = try fixture.viewModel.addAndSelectAccount(
            provider: .chatgptCodex,
            label: "Consulting",
            cliDataRoot: "/profiles/consulting"
        )
        let addedStore = fixture.pool.getWebViewStore(for: added)

        XCTAssertEqual(added.label, "Consulting")
        XCTAssertEqual(added.cliDataRoot, "/profiles/consulting")
        XCTAssertEqual(added.webKitStorage, .isolated)
        XCTAssertEqual(
            fixture.viewModel.selectedAccount(for: .chatgptCodex).id,
            added.id
        )
        XCTAssertEqual(
            Set(fixture.viewModel.accounts(for: .chatgptCodex).map(\.id)),
            Set([fixture.personal.id, fixture.work.id, added.id])
        )
        XCTAssertNotEqual(
            ObjectIdentifier(personalStore.websiteDataStore),
            ObjectIdentifier(addedStore.websiteDataStore)
        )
        XCTAssertTrue(fixture.pool.isActive(addedStore))
    }

    func testAccountFacadeUpdatesOnlyMutableMetadata() throws {
        let fixture = try makeFixture()
        try fixture.accountStore.updateAccount(
            fixture.work.updating(
                label: fixture.work.label,
                isEnabled: fixture.work.isEnabled,
                cliDataRoot: "/profiles/work"
            )
        )
        fixture.viewModel.reloadAccounts()

        let updated = try fixture.viewModel.updateAccount(
            id: fixture.work.id,
            label: "  Client Work  ",
            isEnabled: false
        )

        XCTAssertEqual(updated.id, fixture.work.id)
        XCTAssertEqual(updated.provider, fixture.work.provider)
        XCTAssertEqual(updated.label, "Client Work")
        XCTAssertFalse(updated.isEnabled)
        XCTAssertEqual(updated.cliDataRoot, "/profiles/work")
        XCTAssertEqual(updated.createdAt, fixture.work.createdAt)
        XCTAssertEqual(updated.webKitStorage, fixture.work.webKitStorage)
        XCTAssertEqual(
            fixture.viewModel.accounts(for: .claudeCode).map(\.provider),
            [.claudeCode]
        )

        let rootUpdated = try fixture.viewModel.updateAccount(
            id: fixture.work.id,
            label: updated.label,
            isEnabled: updated.isEnabled,
            cliDataRoot: "/profiles/client-work"
        )
        XCTAssertEqual(rootUpdated.cliDataRoot, "/profiles/client-work")
        XCTAssertEqual(rootUpdated.id, fixture.work.id)
        XCTAssertEqual(rootUpdated.createdAt, fixture.work.createdAt)
        XCTAssertEqual(
            rootUpdated.webKitStorage,
            fixture.work.webKitStorage
        )
    }

    func testNonCurrentProviderSelectionPublishesCatalogRevision() throws {
        let fixture = try makeFixture()
        let secondaryClaude = try fixture.accountStore.addAccount(
            provider: .claudeCode,
            label: "Work Claude"
        )
        fixture.viewModel.reloadAccounts()
        let priorRevision = fixture.viewModel.accountCatalogRevision
        XCTAssertEqual(fixture.viewModel.selectedProvider, .chatgptCodex)

        try fixture.viewModel.selectAccount(id: secondaryClaude.id)

        XCTAssertGreaterThan(
            fixture.viewModel.accountCatalogRevision,
            priorRevision
        )
        XCTAssertEqual(
            fixture.viewModel.selectedAccount(for: .claudeCode).id,
            secondaryClaude.id
        )
        XCTAssertEqual(fixture.viewModel.selectedProvider, .chatgptCodex)
    }

    func testAddAndSelectFailsBeforeCreatingWhenProjectionCannotHide() throws {
        let fixture = try makeFixture()
        let originalAccountIDs = Set(fixture.accountStore.loadAccounts().map(\.id))
        fixture.repository.rejectNextNilProjection = true

        XCTAssertThrowsError(
            try fixture.viewModel.addAndSelectAccount(
                id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
                provider: .chatgptCodex,
                label: "Consulting"
            )
        )

        XCTAssertEqual(
            Set(fixture.accountStore.loadAccounts().map(\.id)),
            originalAccountIDs
        )
        let added = try fixture.viewModel.addAndSelectAccount(
            id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!,
            provider: .chatgptCodex,
            label: "Consulting"
        )
        XCTAssertEqual(
            fixture.accountStore.accounts(for: .chatgptCodex)
                .filter { $0.label == "Consulting" }
                .map(\.id),
            [added.id]
        )
    }

    func testIndeterminateUsageProjectionBlocksSelectionAndAdd() throws {
        let fixture = try makeFixture(indeterminateSelectedUsage: true)
        let legacySnapshot = try XCTUnwrap(
            fixture.repository.projections[.chatgptCodex]
        )
        let originalIDs = Set(fixture.accountStore.loadAccounts().map(\.id))

        XCTAssertThrowsError(
            try fixture.viewModel.selectAccount(id: fixture.work.id)
        ) { error in
            XCTAssertEqual(
                error as? AccountUsageSnapshotRepositoryError,
                .indeterminateSnapshot(
                    provider: .chatgptCodex,
                    accountLabel: fixture.personal.label
                )
            )
        }
        XCTAssertThrowsError(
            try fixture.viewModel.addAndSelectAccount(
                provider: .chatgptCodex,
                label: "Consulting"
            )
        )

        XCTAssertEqual(
            fixture.accountStore.selectedAccount(for: .chatgptCodex).id,
            fixture.personal.id
        )
        XCTAssertEqual(
            Set(fixture.accountStore.loadAccounts().map(\.id)),
            originalIDs
        )
        XCTAssertEqual(
            fixture.repository.projections[.chatgptCodex]?.fetchedAt,
            legacySnapshot.fetchedAt
        )
        XCTAssertTrue(
            fixture.repository.suppressedProjectionProviders.contains(
                .chatgptCodex
            )
        )
    }

    func testStableIDAddRetryQuarantinesOldCLIRootBeforeRegistryWrite()
        throws {
        let fixture = try makeFixture()
        let oldRoot = fixture.work.cliDataRoot
        fixture.tokenRepository.seedSnapshot(
            makeTokenSnapshot(provider: .codex, timestamp: 1_500),
            for: fixture.work
        )
        var observedRootDuringDelete: String?
        var didObserveDelete = false
        fixture.tokenRepository.onDelete = { account in
            guard account.id == fixture.work.id,
                  !didObserveDelete else { return }
            didObserveDelete = true
            observedRootDuringDelete = fixture.accountStore.account(
                id: account.id
            )?.cliDataRoot
        }

        let updated = try fixture.viewModel.addAndSelectAccount(
            id: fixture.work.id,
            provider: .chatgptCodex,
            label: "Work",
            cliDataRoot: "/profiles/work-retry"
        )

        XCTAssertTrue(didObserveDelete)
        XCTAssertEqual(observedRootDuringDelete, oldRoot)
        XCTAssertEqual(updated.cliDataRoot, "/profiles/work-retry")
        XCTAssertNil(fixture.tokenRepository.snapshot(for: fixture.work.id))
    }

    func testSelectionRestoresBothProjectionsWhenTokenProjectionCannotHide()
        throws {
        let fixture = try makeFixture(
            initialSnapshots: { personal, _ in
                [
                    personal.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 1_000
                    )
                ]
            }
        )
        fixture.tokenRepository.rejectNextNilProjection = true

        XCTAssertThrowsError(
            try fixture.viewModel.selectAccount(id: fixture.work.id)
        )

        XCTAssertEqual(
            fixture.accountStore.selectedAccount(for: .chatgptCodex).id,
            fixture.personal.id
        )
        XCTAssertEqual(
            fixture.repository.projections[.chatgptCodex]?.fetchedAt,
            Date(timeIntervalSince1970: 1_000)
        )
        XCTAssertEqual(
            fixture.tokenRepository.projections[.codex]?.fetchedAt,
            Date(timeIntervalSince1970: 1_001)
        )
    }

    func testAddRestoresBothProjectionsWhenTokenProjectionCannotHide() throws {
        let fixture = try makeFixture(
            initialSnapshots: { personal, _ in
                [
                    personal.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 1_100
                    )
                ]
            }
        )
        let originalAccountIDs = Set(
            fixture.accountStore.loadAccounts().map(\.id)
        )
        fixture.tokenRepository.rejectNextNilProjection = true

        XCTAssertThrowsError(
            try fixture.viewModel.addAndSelectAccount(
                provider: .chatgptCodex,
                label: "Consulting"
            )
        )

        XCTAssertEqual(
            Set(fixture.accountStore.loadAccounts().map(\.id)),
            originalAccountIDs
        )
        XCTAssertEqual(
            fixture.repository.projections[.chatgptCodex]?.fetchedAt,
            Date(timeIntervalSince1970: 1_100)
        )
        XCTAssertEqual(
            fixture.tokenRepository.projections[.codex]?.fetchedAt,
            Date(timeIntervalSince1970: 1_001)
        )
    }

    func testSuccessfulLegacyRetirementRestoresSharedSiblingState() throws {
        let fixture = try makeFixture(
            initialSnapshots: { personal, _ in
                [
                    personal.id: self.makeSnapshot(
                        .chatgptCodex,
                        timestamp: 100
                    )
                ]
            },
            additionalUsageSnapshots: { accountStore in
                let claude = accountStore.selectedAccount(for: .claudeCode)
                return [
                    claude.id: self.makeSnapshot(
                        .claudeCode,
                        timestamp: 700
                    )
                ]
            },
            additionalTokenSnapshots: { accountStore in
                let claude = accountStore.selectedAccount(for: .claudeCode)
                return [
                    claude.id: self.makeTokenSnapshot(
                        provider: .claude,
                        timestamp: 701
                    )
                ]
            }
        )
        let claude = fixture.accountStore.selectedAccount(for: .claudeCode)
        let targetStore = fixture.pool.getWebViewStore(for: fixture.personal)
        let plan = try fixture.accountStore.prepareRemoval(
            id: fixture.personal.id
        )

        let token = try fixture.pool.beginAccountRetirement(plan)
        XCTAssertTrue(targetStore.beginRetirementDuringDataClear())
        try fixture.repository.deleteSnapshot(for: fixture.personal)
        try fixture.tokenRepository.deleteSnapshot(for: fixture.personal)
        let commit = try fixture.accountStore.commitRemoval(plan)
        try fixture.pool.finalizeAccountRetirement(token, commit: commit)

        XCTAssertNil(fixture.accountStore.account(id: fixture.personal.id))
        XCTAssertEqual(
            fixture.viewModel.snapshot(for: claude.id)?.fetchedAt,
            Date(timeIntervalSince1970: 700)
        )
        XCTAssertEqual(
            fixture.tokenViewModel.snapshot(for: claude.id)?.fetchedAt,
            Date(timeIntervalSince1970: 701)
        )
    }

    private func makeFixture(
        initialSnapshots: ((ProviderAccount, ProviderAccount) -> [UUID: UsageSnapshot])? = nil,
        additionalUsageSnapshots:
            ((ProviderAccountStore) -> [UUID: UsageSnapshot])? = nil,
        additionalTokenSnapshots:
            ((ProviderAccountStore) -> [UUID: TokenUsageSnapshot])? = nil,
        indeterminateSelectedUsage: Bool = false,
        quiescenceTimeout: Duration = .milliseconds(100)
    ) throws -> IsolationFixture {
        let defaults = UserDefaults(
            suiteName: "UsageAccountIsolation-\(UUID().uuidString)"
        )!
        let accountStore = ProviderAccountStore(
            userDefaults: defaults,
            key: "accounts"
        )
        let personal = accountStore.selectedAccount(for: .chatgptCodex)
        let work = try accountStore.addAccount(
            provider: .chatgptCodex,
            label: "Work"
        )
        var usageSnapshots = initialSnapshots?(personal, work) ?? [:]
        usageSnapshots.merge(
            additionalUsageSnapshots?(accountStore) ?? [:]
        ) { _, newValue in newValue }
        let repository = IsolationSnapshotRepository(snapshots: usageSnapshots)
        if indeterminateSelectedUsage {
            repository.indeterminateAccountIDs.insert(personal.id)
            repository.seedProjection(
                makeSnapshot(.chatgptCodex, timestamp: 1_450)
            )
        }
        let fetcher = ControlledUsageSnapshotFetcher()
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: IsolationWebsiteDataClearer(),
            websiteDataStoreProvider: { _ in .nonPersistent() },
            quiescenceTimeout: quiescenceTimeout
        )
        var tokenSnapshots = [
            personal.id: makeTokenSnapshot(
                provider: .codex,
                timestamp: 1_001
            )
        ]
        tokenSnapshots.merge(
            additionalTokenSnapshots?(accountStore) ?? [:]
        ) { _, newValue in newValue }
        let tokenRepository = IsolationAccountTokenSnapshotRepository(
            snapshots: tokenSnapshots
        )
        let tokenViewModel = TokenUsageViewModel(
            snapshotRepository: tokenRepository,
            accountStore: accountStore,
            settingsStore: CCUsageSettingsStore(userDefaults: defaults)
        )
        let viewModel = UsageViewModel(
            webViewPool: pool,
            snapshotRepository: repository,
            usageFetcher: fetcher,
            tokenUsageViewModel: tokenViewModel,
            displayModeStore: UsageDisplayModeStore(
                userDefaults: defaults,
                appGroupDefaults: nil
            )
        )
        return IsolationFixture(
            accountStore: accountStore,
            personal: personal,
            work: work,
            repository: repository,
            tokenRepository: tokenRepository,
            tokenViewModel: tokenViewModel,
            fetcher: fetcher,
            pool: pool,
            viewModel: viewModel
        )
    }

    private func makeSnapshot(
        _ provider: UsageProvider,
        timestamp: TimeInterval
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            fetchedAt: Date(timeIntervalSince1970: timestamp),
            primaryWindow: UsageWindow(
                kind: .primary,
                usedPercent: 1,
                resetAt: Date(timeIntervalSince1970: timestamp + 1_000),
                limitWindowSeconds: UsageLimitDuration.fiveHours
            ),
            secondaryWindow: nil
        )
    }

    private func makeTokenSnapshot(
        provider: TokenUsageProvider,
        timestamp: TimeInterval
    ) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            provider: provider,
            fetchedAt: Date(timeIntervalSince1970: timestamp),
            today: TokenUsagePeriod(costUSD: 1, totalTokens: 10),
            thisWeek: TokenUsagePeriod(costUSD: 2, totalTokens: 20),
            thisMonth: TokenUsagePeriod(costUSD: 3, totalTokens: 30)
        )
    }
}

@MainActor
private struct IsolationFixture {
    let accountStore: ProviderAccountStore
    let personal: ProviderAccount
    let work: ProviderAccount
    let repository: IsolationSnapshotRepository
    let tokenRepository: IsolationAccountTokenSnapshotRepository
    let tokenViewModel: TokenUsageViewModel
    let fetcher: ControlledUsageSnapshotFetcher
    let pool: UsageWebViewPool
    let viewModel: UsageViewModel
}

@MainActor
private final class IsolationSnapshotRepository:
    AccountUsageSnapshotRepository {
    var snapshots: [UUID: UsageSnapshot]
    private(set) var projections: [UsageProvider: UsageSnapshot] = [:]
    private(set) var saveAttempts: [UUID] = []
    private(set) var deletionAttempts: [UUID] = []
    private var suppressedAccountIDs: Set<UUID> = []
    var indeterminateAccountIDs: Set<UUID> = []
    private(set) var suppressedProjectionProviders: Set<UsageProvider> = []
    var onPublish: ((ProviderAccount, UsageSnapshot?) -> Void)?
    var rejectNextNilProjection = false

    init(snapshots: [UUID: UsageSnapshot] = [:]) {
        self.snapshots = snapshots
    }

    func loadSnapshot(for account: ProviderAccount) -> UsageSnapshot? {
        guard !suppressedAccountIDs.contains(account.id),
              snapshots[account.id]?.provider == account.provider else {
            return nil
        }
        return snapshots[account.id]
    }

    func canSafelyPublishMissingSnapshot(
        for account: ProviderAccount
    ) -> Bool {
        !indeterminateAccountIDs.contains(account.id)
    }

    func saveSnapshot(
        _ snapshot: UsageSnapshot,
        for account: ProviderAccount
    ) throws {
        guard snapshot.provider == account.provider else {
            throw AccountUsageSnapshotRepositoryError.providerMismatch
        }
        saveAttempts.append(account.id)
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

    func setSelectedProjectionSuppressed(
        _ isSuppressed: Bool,
        for account: ProviderAccount
    ) {
        if isSuppressed {
            suppressedProjectionProviders.insert(account.provider)
        } else {
            suppressedProjectionProviders.remove(account.provider)
        }
    }

    func publishSelectedSnapshot(
        _ snapshot: UsageSnapshot?,
        for account: ProviderAccount
    ) throws {
        if snapshot == nil, rejectNextNilProjection {
            rejectNextNilProjection = false
            throw AccountUsageSnapshotRepositoryError.providerMismatch
        }
        onPublish?(account, snapshot)
        if let snapshot {
            guard snapshot.provider == account.provider else {
                throw AccountUsageSnapshotRepositoryError.providerMismatch
            }
            projections[account.provider] = snapshot
        } else {
            projections.removeValue(forKey: account.provider)
        }
        suppressedProjectionProviders.remove(account.provider)
    }

    func seedProjection(_ snapshot: UsageSnapshot) {
        projections[snapshot.provider] = snapshot
    }

}

@MainActor
private final class ControlledUsageSnapshotFetcher: UsageSnapshotFetching {
    private var continuations: [
        ObjectIdentifier: CheckedContinuation<UsageSnapshot, Error>
    ] = [:]

    func hasValidSession(
        for provider: UsageProvider,
        using webView: WKWebView
    ) async -> Bool {
        true
    }

    func fetchSnapshot(
        for provider: UsageProvider,
        using webView: WKWebView
    ) async throws -> UsageSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            continuations[ObjectIdentifier(webView)] = continuation
        }
    }

    func waitUntilRequested(using webView: WKWebView) async {
        let identifier = ObjectIdentifier(webView)
        while continuations[identifier] == nil {
            await Task.yield()
        }
    }

    func complete(using webView: WKWebView, with snapshot: UsageSnapshot) {
        continuations.removeValue(forKey: ObjectIdentifier(webView))?
            .resume(returning: snapshot)
    }
}

@MainActor
private final class IsolationWebsiteDataClearer: WebsiteDataClearing {
    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws {}
}

@MainActor
private final class IsolationAccountTokenSnapshotRepository:
    AccountTokenUsageSnapshotRepository {
    private(set) var snapshots: [UUID: TokenUsageSnapshot]
    private(set) var projections: [TokenUsageProvider: TokenUsageSnapshot] = [:]
    private var suppressedAccountIDs: Set<UUID> = []
    var rejectNextNilProjection = false
    var onDelete: ((ProviderAccount) -> Void)?

    init(snapshots: [UUID: TokenUsageSnapshot] = [:]) {
        self.snapshots = snapshots
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
        onDelete?(account)
        snapshots.removeValue(forKey: account.id)
    }

    func seedSnapshot(
        _ snapshot: TokenUsageSnapshot,
        for account: ProviderAccount
    ) {
        snapshots[account.id] = snapshot
    }

    func snapshot(for accountID: UUID) -> TokenUsageSnapshot? {
        snapshots[accountID]
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
        if snapshot == nil, rejectNextNilProjection {
            projections.removeValue(forKey: provider)
            rejectNextNilProjection = false
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
