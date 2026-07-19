import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class SessionActivityViewModelTests: XCTestCase {
    private var registeredAccountsByID: [UUID: ProviderAccount] = [:]

    func testCodexAndClaudeReportUnsupportedWithUnknownCounts() async {
        let credentials = MemorySessionActivityCredentialStore()
        let fetcher = ControlledGitHubAgentTaskFetcher()
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 1_000)
        )
        let codex = makeAccount(
            id: "a4000000-0000-0000-0000-00000000000a",
            provider: .chatgptCodex
        )
        let claude = makeAccount(
            id: "b4000000-0000-0000-0000-00000000000b",
            provider: .claudeCode
        )

        await viewModel.refresh(account: codex)
        await viewModel.refresh(account: claude)

        for account in [codex, claude] {
            let snapshot = viewModel.snapshot(for: account.id)
            XCTAssertEqual(snapshot?.availability, .unsupported)
            XCTAssertEqual(snapshot?.scope, .localRuntime)
            XCTAssertNil(snapshot?.working)
            XCTAssertNil(snapshot?.waiting)
            XCTAssertNil(snapshot?.open)
        }
        XCTAssertTrue(credentials.loadedAccountIDs.isEmpty)
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testMissingCopilotCredentialReportsAuthenticationRequiredNotZero()
        async {
        let fetcher = ControlledGitHubAgentTaskFetcher()
        let viewModel = makeViewModel(
            credentials: MemorySessionActivityCredentialStore(),
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 2_000)
        )
        let account = makeAccount(
            id: "c4000000-0000-0000-0000-00000000000c",
            provider: .githubCopilot
        )

        await viewModel.refresh(account: account)

        let snapshot = viewModel.snapshot(for: account.id)
        XCTAssertEqual(snapshot?.availability, .authenticationRequired)
        XCTAssertEqual(snapshot?.scope, .cloudAgentSessions)
        XCTAssertNil(snapshot?.working)
        XCTAssertNil(snapshot?.waiting)
        XCTAssertNil(snapshot?.open)
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testSelectedAccountFetchUsesExactSelectedAccountCredential()
        async throws {
        let defaults = UserDefaults(
            suiteName: "SessionActivitySelectedAccount-\(UUID().uuidString)"
        )!
        let accountStore = ProviderAccountStore(
            userDefaults: defaults,
            key: "accounts"
        )
        let personal = accountStore.selectedAccount(for: .githubCopilot)
        let work = try accountStore.addAccount(
            provider: .githubCopilot,
            label: "Work"
        )
        _ = try accountStore.selectAccount(id: work.id)
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[personal.id] = "personal-token"
        credentials.credentials[work.id] = "work-token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 2, waiting: 1)
        ))
        let viewModel = SessionActivityViewModel(
            accountStore: accountStore,
            credentialStore: credentials,
            githubFetcher: fetcher,
            now: { Date(timeIntervalSince1970: 3_000) }
        )

        await viewModel.refreshSelectedAccount(for: .githubCopilot)

        let requestedCredentials = await fetcher.requestedCredentials
        XCTAssertEqual(requestedCredentials, ["work-token"])
        XCTAssertNil(viewModel.snapshot(for: personal.id))
        XCTAssertEqual(viewModel.snapshot(for: work.id)?.working, 2)
        XCTAssertEqual(viewModel.snapshot(for: work.id)?.waiting, 1)
        XCTAssertEqual(viewModel.snapshot(for: work.id)?.open, 3)
    }

    func testCopilotAccountsKeepCredentialsAndCountsIndependent() async {
        let personal = makeAccount(
            id: "c4100000-0000-0000-0000-00000000000c",
            provider: .githubCopilot
        )
        let work = makeAccount(
            id: "c4200000-0000-0000-0000-00000000000c",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[personal.id] = "personal-token"
        credentials.credentials[work.id] = "work-token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 1, waiting: 0)
        ))
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 3, waiting: 2)
        ))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 3_100)
        )

        await viewModel.refresh(account: personal)
        await viewModel.refresh(account: work)

        let requestedCredentials = await fetcher.requestedCredentials
        XCTAssertEqual(
            requestedCredentials,
            ["personal-token", "work-token"]
        )
        XCTAssertEqual(viewModel.snapshot(for: personal.id)?.open, 1)
        XCTAssertEqual(viewModel.snapshot(for: work.id)?.open, 5)
    }

    func testDisabledAccountSkipsBackgroundButManualRefreshWorks() async {
        let account = makeAccount(
            id: "d4000000-0000-0000-0000-00000000000d",
            provider: .githubCopilot,
            isEnabled: false
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 1, waiting: 0)
        ))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 4_000)
        )

        await viewModel.refresh(account: account, reason: .background)
        var requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(viewModel.snapshot(for: account.id))

        await viewModel.refresh(account: account, reason: .manual)
        requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(viewModel.snapshot(for: account.id)?.availability, .available)
        XCTAssertEqual(viewModel.snapshot(for: account.id)?.open, 1)
    }

    func testFailedRefreshPreservesPriorCountsAsStale() async {
        let account = makeAccount(
            id: "e4000000-0000-0000-0000-00000000000e",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 3, waiting: 2)
        ))
        await fetcher.enqueue(.failure(.transport))
        let clock = MutableSessionActivityClock(
            date: Date(timeIntervalSince1970: 5_000)
        )
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            clock: clock
        )

        await viewModel.refresh(account: account)
        clock.date = Date(timeIntervalSince1970: 6_000)
        await viewModel.refresh(account: account)

        let snapshot = viewModel.snapshot(for: account.id)
        XCTAssertEqual(snapshot?.availability, .stale)
        XCTAssertEqual(snapshot?.working, 3)
        XCTAssertEqual(snapshot?.waiting, 2)
        XCTAssertEqual(snapshot?.open, 5)
        XCTAssertEqual(
            snapshot?.observedAt,
            Date(timeIntervalSince1970: 5_000)
        )
    }

    func testRateLimitPreservesPriorCountsAsStale() async {
        let account = makeAccount(
            id: "e4100000-0000-0000-0000-00000000000e",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 2, waiting: 2)
        ))
        await fetcher.enqueue(.failure(.rateLimited(
            retryAt: Date(timeIntervalSince1970: 6_400)
        )))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 6_100)
        )

        await viewModel.refresh(account: account)
        await viewModel.refresh(account: account)

        let snapshot = viewModel.snapshot(for: account.id)
        XCTAssertEqual(snapshot?.availability, .stale)
        XCTAssertEqual(snapshot?.open, 4)
    }

    func testFailureWithoutPriorCountsReportsErrorNotZero() async {
        let account = makeAccount(
            id: "f4000000-0000-0000-0000-00000000000f",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.failure(.transport))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 7_000)
        )

        await viewModel.refresh(account: account)

        let snapshot = viewModel.snapshot(for: account.id)
        XCTAssertEqual(snapshot?.availability, .error)
        XCTAssertNil(snapshot?.working)
        XCTAssertNil(snapshot?.waiting)
        XCTAssertNil(snapshot?.open)
    }

    func testInvalidStoredCredentialDiscardsPriorCounts() async {
        let account = makeAccount(
            id: "fa000000-0000-0000-0000-00000000000f",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 2, waiting: 1)
        ))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 5_100)
        )
        await viewModel.refresh(account: account)

        credentials.credentialError =
            SessionActivityCredentialStoreError.invalidStoredCredential
        await viewModel.refresh(account: account)

        let snapshot = viewModel.snapshot(for: account.id)
        XCTAssertEqual(snapshot?.availability, .authenticationRequired)
        XCTAssertNil(snapshot?.open)
    }

    func testTransientCredentialReadFailurePreservesPriorCountsAsStale()
        async {
        let account = makeAccount(
            id: "fb000000-0000-0000-0000-00000000000f",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 1, waiting: 1)
        ))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 5_200)
        )
        await viewModel.refresh(account: account)

        credentials.credentialError = SessionActivityTestError.failed
        await viewModel.refresh(account: account)

        let snapshot = viewModel.snapshot(for: account.id)
        XCTAssertEqual(snapshot?.availability, .stale)
        XCTAssertEqual(snapshot?.open, 2)
    }

    func testAuthenticationFailureDiscardsPriorCounts() async {
        let account = makeAccount(
            id: "a5000000-0000-0000-0000-00000000000a",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 1, waiting: 1)
        ))
        await fetcher.enqueue(.failure(.authenticationRequired))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 8_000)
        )

        await viewModel.refresh(account: account)
        await viewModel.refresh(account: account)

        let snapshot = viewModel.snapshot(for: account.id)
        XCTAssertEqual(snapshot?.availability, .authenticationRequired)
        XCTAssertNil(snapshot?.working)
        XCTAssertNil(snapshot?.waiting)
        XCTAssertNil(snapshot?.open)
    }

    func testInsufficientPermissionsDiscardsPriorCounts() async {
        let account = makeAccount(
            id: "a5100000-0000-0000-0000-00000000000a",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "restricted-token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 4, waiting: 1)
        ))
        await fetcher.enqueue(.failure(.insufficientPermissions))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 8_100)
        )

        await viewModel.refresh(account: account)
        await viewModel.refresh(account: account)

        let snapshot = viewModel.snapshot(for: account.id)
        XCTAssertEqual(snapshot?.availability, .authenticationRequired)
        XCTAssertNil(snapshot?.open)
    }

    func testSuccessfulCountsBecomeStaleAfterFreshnessDeadline() async {
        let account = makeAccount(
            id: "a5200000-0000-0000-0000-00000000000a",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 2, waiting: 3)
        ))
        let clock = MutableSessionActivityClock(
            date: Date(timeIntervalSince1970: 8_200)
        )
        let viewModel = SessionActivityViewModel(
            accountStore: makeAccountStore(),
            credentialStore: credentials,
            githubFetcher: fetcher,
            now: { clock.date },
            freshnessInterval: 60,
            accountResolver: { [weak self] in
                self?.registeredAccountsByID[$0]
            }
        )

        await viewModel.refresh(account: account)
        XCTAssertEqual(
            viewModel.snapshot(for: account.id)?.availability,
            .available
        )

        clock.date = Date(timeIntervalSince1970: 8_261)
        let stale = viewModel.snapshot(for: account.id)
        XCTAssertEqual(stale?.availability, .stale)
        XCTAssertEqual(stale?.open, 5)
        XCTAssertEqual(
            stale?.observedAt,
            Date(timeIntervalSince1970: 8_200)
        )
        XCTAssertEqual(
            viewModel.snapshotsByAccountID[account.id]?.availability,
            .stale
        )
    }

    func testCredentialReplacementInvalidatesSuspendedCompletion() async throws {
        let account = makeAccount(
            id: "b5000000-0000-0000-0000-00000000000b",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "old-token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.suspended)
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 9_000)
        )

        let oldFetch = Task { await viewModel.refresh(account: account) }
        await waitForRequestCount(1, fetcher: fetcher)

        try viewModel.saveCredential("new-token", for: account)
        await fetcher.succeedNext(
            SessionActivityCounts(working: 9, waiting: 9)
        )
        await oldFetch.value

        XCTAssertNil(viewModel.snapshot(for: account.id))
        XCTAssertFalse(viewModel.isFetching(accountID: account.id))

        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 2, waiting: 0)
        ))
        await viewModel.refresh(account: account)
        let requestedCredentials = await fetcher.requestedCredentials
        XCTAssertEqual(
            requestedCredentials,
            ["old-token", "new-token"]
        )
        XCTAssertEqual(viewModel.snapshot(for: account.id)?.open, 2)
    }

    func testCredentialDeletionInvalidatesSuspendedCompletion() async throws {
        let account = makeAccount(
            id: "c5000000-0000-0000-0000-00000000000c",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "old-token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.suspended)
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 10_000)
        )

        let oldFetch = Task { await viewModel.refresh(account: account) }
        await waitForRequestCount(1, fetcher: fetcher)

        try viewModel.deleteCredential(for: account)
        await fetcher.succeedNext(
            SessionActivityCounts(working: 8, waiting: 8)
        )
        await oldFetch.value

        let snapshot = viewModel.snapshot(for: account.id)
        XCTAssertEqual(snapshot?.availability, .authenticationRequired)
        XCTAssertNil(snapshot?.open)
        XCTAssertNil(credentials.credentials[account.id])
        XCTAssertFalse(viewModel.isFetching(accountID: account.id))
    }

    func testRetiringAccountDeletesCredentialAndRejectsSuspendedCompletion()
        async throws {
        let account = makeAccount(
            id: "d5000000-0000-0000-0000-00000000000d",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "old-token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.suspended)
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 10_100)
        )

        let oldFetch = Task { await viewModel.refresh(account: account) }
        await waitForRequestCount(1, fetcher: fetcher)

        try viewModel.retireAccount(account)
        XCTAssertEqual(credentials.deletedAccountIDs, [account.id])
        XCTAssertNil(credentials.credentials[account.id])
        XCTAssertNil(viewModel.snapshot(for: account.id))
        XCTAssertFalse(viewModel.isFetching(accountID: account.id))

        await fetcher.succeedNext(
            SessionActivityCounts(working: 7, waiting: 7)
        )
        await oldFetch.value
        XCTAssertNil(viewModel.snapshot(for: account.id))
    }

    func testRetirementKeychainFailureLeavesAccountStateUntouched()
        async {
        let account = makeAccount(
            id: "e5000000-0000-0000-0000-00000000000e",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 1, waiting: 2)
        ))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 10_200)
        )
        await viewModel.refresh(account: account)
        credentials.deleteCredentialError = SessionActivityTestError.failed

        XCTAssertThrowsError(try viewModel.retireAccount(account))

        XCTAssertEqual(viewModel.snapshot(for: account.id)?.open, 3)
        XCTAssertEqual(credentials.credentials[account.id], "token")
    }

    func testGlobalClearDeletesServiceCredentialsAndRejectsOldCompletion()
        async throws {
        let account = makeAccount(
            id: "f5000000-0000-0000-0000-00000000000f",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        credentials.credentials[UUID()] = "other-token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.suspended)
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 10_300)
        )

        let oldFetch = Task { await viewModel.refresh(account: account) }
        await waitForRequestCount(1, fetcher: fetcher)

        try viewModel.clearAllActivityData()
        XCTAssertEqual(credentials.deleteAllCallCount, 1)
        XCTAssertTrue(credentials.credentials.isEmpty)
        XCTAssertTrue(viewModel.snapshotsByAccountID.isEmpty)
        XCTAssertFalse(viewModel.isFetching(accountID: account.id))

        await fetcher.succeedNext(
            SessionActivityCounts(working: 6, waiting: 6)
        )
        await oldFetch.value
        XCTAssertNil(viewModel.snapshot(for: account.id))
    }

    func testGlobalClearKeychainFailurePreservesSnapshots() async {
        let account = makeAccount(
            id: "a6000000-0000-0000-0000-00000000000a",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 3, waiting: 1)
        ))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 10_400)
        )
        await viewModel.refresh(account: account)
        credentials.deleteAllError = SessionActivityTestError.failed

        XCTAssertThrowsError(try viewModel.clearAllActivityData())

        XCTAssertEqual(viewModel.snapshot(for: account.id)?.open, 4)
        XCTAssertEqual(credentials.credentials[account.id], "token")
        let retryToken = viewModel.beginActivityDataClear()
        XCTAssertNotNil(retryToken)
        if let retryToken {
            XCTAssertTrue(viewModel.finishActivityDataClear(retryToken))
        }
    }

    func testHeldClearBlocksCredentialMutationAndRefreshUntilFinished()
        async throws {
        let account = makeAccount(
            id: "aa000000-0000-0000-0000-00000000000a",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "old-token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 10_500)
        )
        let clearToken = try XCTUnwrap(
            viewModel.beginActivityDataClear()
        )

        try viewModel.clearAllActivityData(during: clearToken)
        XCTAssertThrowsError(
            try viewModel.saveCredential("new-token", for: account)
        ) { error in
            XCTAssertEqual(
                error as? SessionActivityViewModelError,
                .dataClearInProgress
            )
        }
        XCTAssertThrowsError(
            try viewModel.deleteCredential(for: account)
        ) { error in
            XCTAssertEqual(
                error as? SessionActivityViewModelError,
                .dataClearInProgress
            )
        }
        await viewModel.refresh(account: account)

        XCTAssertNil(viewModel.snapshot(for: account.id))
        XCTAssertTrue(credentials.credentials.isEmpty)
        let blockedRequestCount = await fetcher.requestCount
        XCTAssertEqual(blockedRequestCount, 0)

        XCTAssertTrue(viewModel.finishActivityDataClear(clearToken))
        try viewModel.saveCredential("new-token", for: account)
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 1, waiting: 0)
        ))
        await viewModel.refresh(account: account)
        XCTAssertEqual(viewModel.snapshot(for: account.id)?.open, 1)
    }

    func testRemovedAccountCannotRefreshOrOrphanCredential() async {
        let account = makeAccount(
            id: "b6000000-0000-0000-0000-00000000000b",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        let fetcher = ControlledGitHubAgentTaskFetcher()
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 11_000)
        )
        registeredAccountsByID.removeValue(forKey: account.id)

        await viewModel.refresh(account: account)
        XCTAssertThrowsError(
            try viewModel.saveCredential("must-not-persist", for: account)
        ) { error in
            XCTAssertEqual(
                error as? SessionActivityViewModelError,
                .accountNotFound
            )
        }

        XCTAssertNil(credentials.credentials[account.id])
        XCTAssertTrue(credentials.savedAccountIDs.isEmpty)
        XCTAssertNil(viewModel.snapshot(for: account.id))
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 0)
    }

    func testBackgroundRefreshUsesCurrentEnabledRegistryState() async {
        let staleEnabled = makeAccount(
            id: "c6000000-0000-0000-0000-00000000000c",
            provider: .githubCopilot
        )
        var currentDisabled = staleEnabled
        currentDisabled.isEnabled = false
        registeredAccountsByID[staleEnabled.id] = currentDisabled
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[staleEnabled.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 11_100)
        )

        await viewModel.refresh(
            account: staleEnabled,
            reason: .background
        )

        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(viewModel.snapshot(for: staleEnabled.id))
    }

    func testBackgroundRefreshesAccountsWithoutOneSuspensionBlockingSibling()
        async {
        let first = makeAccount(
            id: "d6000000-0000-0000-0000-00000000000d",
            provider: .githubCopilot
        )
        let second = makeAccount(
            id: "e6000000-0000-0000-0000-00000000000e",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[first.id] = "first"
        credentials.credentials[second.id] = "second"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.suspended)
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 1, waiting: 0)
        ))
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            now: Date(timeIntervalSince1970: 11_200)
        )

        let refresh = Task {
            await viewModel.refreshEnabledAccountsInBackground([first, second])
        }
        await waitForRequestCount(2, fetcher: fetcher)
        await fetcher.succeedNext(
            SessionActivityCounts(working: 0, waiting: 1)
        )
        await refresh.value

        XCTAssertEqual(viewModel.snapshot(for: first.id)?.open, 1)
        XCTAssertEqual(viewModel.snapshot(for: second.id)?.open, 1)
    }

    func testRateLimitBackoffSkipsBackgroundButManualCanRecover() async {
        let account = makeAccount(
            id: "f6000000-0000-0000-0000-00000000000f",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = ControlledGitHubAgentTaskFetcher()
        await fetcher.enqueue(.failure(.rateLimited(
            retryAt: Date(timeIntervalSince1970: 12_120)
        )))
        await fetcher.enqueue(.success(
            SessionActivityCounts(working: 1, waiting: 1)
        ))
        let clock = MutableSessionActivityClock(
            date: Date(timeIntervalSince1970: 12_000)
        )
        let viewModel = makeViewModel(
            credentials: credentials,
            fetcher: fetcher,
            clock: clock
        )

        await viewModel.refresh(account: account, reason: .background)
        clock.date = Date(timeIntervalSince1970: 12_100)
        await viewModel.refresh(account: account, reason: .background)
        var requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 1)

        await viewModel.refresh(account: account, reason: .manual)
        requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(viewModel.snapshot(for: account.id)?.open, 2)
    }

    func testRetirementCancelsInFlightCredentialUse() async throws {
        let account = makeAccount(
            id: "a7000000-0000-0000-0000-00000000000a",
            provider: .githubCopilot
        )
        let credentials = MemorySessionActivityCredentialStore()
        credentials.credentials[account.id] = "token"
        let fetcher = CancellationRecordingGitHubAgentTaskFetcher()
        let viewModel = SessionActivityViewModel(
            accountStore: makeAccountStore(),
            credentialStore: credentials,
            githubFetcher: fetcher,
            now: { Date(timeIntervalSince1970: 13_000) },
            accountResolver: { [weak self] in
                self?.registeredAccountsByID[$0]
            }
        )

        let refresh = Task { await viewModel.refresh(account: account) }
        for _ in 0..<200 {
            if await fetcher.requestCount > 0 { break }
            await Task.yield()
        }
        try viewModel.retireAccount(account)
        registeredAccountsByID.removeValue(forKey: account.id)
        await refresh.value

        let cancellationCount = await fetcher.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
        XCTAssertNil(viewModel.snapshot(for: account.id))
        XCTAssertNil(credentials.credentials[account.id])
    }

    private func makeViewModel(
        credentials: MemorySessionActivityCredentialStore,
        fetcher: ControlledGitHubAgentTaskFetcher,
        now: Date
    ) -> SessionActivityViewModel {
        SessionActivityViewModel(
            accountStore: makeAccountStore(),
            credentialStore: credentials,
            githubFetcher: fetcher,
            now: { now },
            accountResolver: { [weak self] in
                self?.registeredAccountsByID[$0]
            }
        )
    }

    private func makeViewModel(
        credentials: MemorySessionActivityCredentialStore,
        fetcher: ControlledGitHubAgentTaskFetcher,
        clock: MutableSessionActivityClock
    ) -> SessionActivityViewModel {
        SessionActivityViewModel(
            accountStore: makeAccountStore(),
            credentialStore: credentials,
            githubFetcher: fetcher,
            now: { clock.date },
            accountResolver: { [weak self] in
                self?.registeredAccountsByID[$0]
            }
        )
    }

    private func makeAccountStore() -> ProviderAccountStore {
        ProviderAccountStore(
            userDefaults: UserDefaults(
                suiteName: "SessionActivityAccounts-\(UUID().uuidString)"
            )!,
            key: "accounts"
        )
    }

    private func makeAccount(
        id: String,
        provider: UsageProvider,
        isEnabled: Bool = true
    ) -> ProviderAccount {
        let account = ProviderAccount(
            id: UUID(uuidString: id)!,
            provider: provider,
            label: provider.displayName,
            isEnabled: isEnabled,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        registeredAccountsByID[account.id] = account
        return account
    }

    private func waitForRequestCount(
        _ expected: Int,
        fetcher: ControlledGitHubAgentTaskFetcher
    ) async {
        for _ in 0..<200 {
            if await fetcher.requestCount >= expected { return }
            await Task.yield()
        }
        let requestCount = await fetcher.requestCount
        XCTAssertEqual(requestCount, expected)
    }
}

private final class MemorySessionActivityCredentialStore:
    SessionActivityCredentialStoring {
    var credentials: [UUID: String] = [:]
    var credentialError: Error?
    var deleteCredentialError: Error?
    var deleteAllError: Error?
    private(set) var loadedAccountIDs: [UUID] = []
    private(set) var savedAccountIDs: [UUID] = []
    private(set) var deletedAccountIDs: [UUID] = []
    private(set) var deleteAllCallCount = 0

    func credential(for accountID: UUID) throws -> String? {
        loadedAccountIDs.append(accountID)
        if let credentialError { throw credentialError }
        return credentials[accountID]
    }

    func saveCredential(_ credential: String, for accountID: UUID) throws {
        savedAccountIDs.append(accountID)
        credentials[accountID] = credential
    }

    func deleteCredential(for accountID: UUID) throws {
        if let deleteCredentialError { throw deleteCredentialError }
        deletedAccountIDs.append(accountID)
        credentials.removeValue(forKey: accountID)
    }

    func deleteAllCredentials() throws {
        deleteAllCallCount += 1
        if let deleteAllError { throw deleteAllError }
        credentials.removeAll()
    }
}

private enum SessionActivityTestError: Error {
    case failed
}

private actor ControlledGitHubAgentTaskFetcher: GitHubAgentTaskFetching {
    enum Outcome {
        case success(SessionActivityCounts)
        case failure(GitHubAgentTaskFetcherError)
        case suspended
    }

    private var outcomes: [Outcome] = []
    private var continuations: [
        CheckedContinuation<SessionActivityCounts, Error>
    ] = []
    private(set) var requestedCredentials: [String] = []

    var requestCount: Int { requestedCredentials.count }

    func enqueue(_ outcome: Outcome) {
        outcomes.append(outcome)
    }

    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        requestedCredentials.append(credential)
        guard !outcomes.isEmpty else {
            throw GitHubAgentTaskFetcherError.transport
        }
        switch outcomes.removeFirst() {
        case .success(let counts):
            return counts
        case .failure(let error):
            throw error
        case .suspended:
            return try await withCheckedThrowingContinuation {
                continuations.append($0)
            }
        }
    }

    func succeedNext(_ counts: SessionActivityCounts) {
        continuations.removeFirst().resume(returning: counts)
    }
}

private actor CancellationRecordingGitHubAgentTaskFetcher:
    GitHubAgentTaskFetching {
    private(set) var requestCount = 0
    private(set) var cancellationCount = 0

    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        requestCount += 1
        do {
            try await Task.sleep(for: .seconds(3_600))
            return SessionActivityCounts(working: 0, waiting: 0)
        } catch is CancellationError {
            cancellationCount += 1
            throw CancellationError()
        }
    }
}

private final class MutableSessionActivityClock {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}
