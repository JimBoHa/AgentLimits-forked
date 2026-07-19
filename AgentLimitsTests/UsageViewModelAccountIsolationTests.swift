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
        let fixture = try makeFixture()
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
        XCTAssertTrue(fixture.pool.cancelAccountRetirement(retirement))
    }

    func testGlobalClearRejectsFetchCompletionAfterDeletion() async throws {
        let fixture = try makeFixture()
        let personalStore = fixture.pool.getWebViewStore(
            for: fixture.personal
        )
        personalStore.isPageReady = true
        let fetchTask = Task {
            await fixture.viewModel.refreshNow(for: .chatgptCodex)
        }
        await fixture.fetcher.waitUntilRequested(using: personalStore.webView)

        let clearTask = Task {
            try await fixture.viewModel.clearData()
        }
        await fixture.repository.waitUntilDeleted(accountID: fixture.personal.id)
        try await clearTask.value

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
            label: "Consulting"
        )
        let addedStore = fixture.pool.getWebViewStore(for: added)

        XCTAssertEqual(added.label, "Consulting")
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

    private func makeFixture(
        initialSnapshots: ((ProviderAccount, ProviderAccount) -> [UUID: UsageSnapshot])? = nil
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
        let repository = IsolationSnapshotRepository(
            snapshots: initialSnapshots?(personal, work) ?? [:]
        )
        let fetcher = ControlledUsageSnapshotFetcher()
        let pool = UsageWebViewPool(
            accountStore: accountStore,
            websiteDataClearer: IsolationWebsiteDataClearer(),
            websiteDataStoreProvider: { _ in .nonPersistent() },
            quiescenceTimeout: .milliseconds(100)
        )
        let visibilityStore = IsolationSnapshotVisibilityStore()
        let tokenViewModel = TokenUsageViewModel(
            snapshotStore: IsolationTokenSnapshotStore(),
            settingsStore: CCUsageSettingsStore(userDefaults: defaults),
            snapshotVisibilityStore: visibilityStore
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
}

@MainActor
private struct IsolationFixture {
    let accountStore: ProviderAccountStore
    let personal: ProviderAccount
    let work: ProviderAccount
    let repository: IsolationSnapshotRepository
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
    }

    func waitUntilDeleted(accountID: UUID) async {
        while !deletionAttempts.contains(accountID) {
            await Task.yield()
        }
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
private final class IsolationTokenSnapshotStore: TokenUsageSnapshotStoring {
    private var snapshots: [TokenUsageProvider: TokenUsageSnapshot] = [:]

    func loadSnapshot(for provider: TokenUsageProvider) -> TokenUsageSnapshot? {
        snapshots[provider]
    }

    func saveSnapshot(_ snapshot: TokenUsageSnapshot) throws {
        snapshots[snapshot.provider] = snapshot
    }

    func deleteSnapshot(for provider: TokenUsageProvider) throws {
        snapshots.removeValue(forKey: provider)
    }
}

private final class IsolationSnapshotVisibilityStore:
    SnapshotVisibilityControlling,
    @unchecked Sendable {
    private var suppressed: Set<String> = []

    func isSnapshotSuppressed(fileName: String) -> Bool {
        suppressed.contains(fileName)
    }

    func setSnapshotSuppressed(_ isSuppressed: Bool, fileName: String) {
        if isSuppressed {
            suppressed.insert(fileName)
        } else {
            suppressed.remove(fileName)
        }
    }
}
