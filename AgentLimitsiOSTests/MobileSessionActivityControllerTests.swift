import Foundation
import XCTest
@testable import AgentLimitsiOS

final class MobileSessionActivityControllerTests: XCTestCase {
    @MainActor
    func testUnsupportedProvidersNeverInventZeroCounts() async throws {
        try await withStore { store in
            let credentials = FakeMobileCredentialStore()
            let fetcher = StubMobileActivityFetcher()
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher
            )
            let codex = try XCTUnwrap(store.accounts(for: .codex).first)

            await controller.refresh(accountID: codex.id)

            let snapshot = controller.snapshot(for: codex)
            XCTAssertEqual(snapshot.availability, .unsupported)
            XCTAssertNil(snapshot.open)
            XCTAssertNil(snapshot.working)
            XCTAssertNil(snapshot.waiting)
            let requestedCredentials = await fetcher.requestedCredentials()
            XCTAssertTrue(requestedCredentials.isEmpty)
        }
    }

    @MainActor
    func testCopilotAccountsUseOnlyTheirOwnCredentialAndCounts() async throws {
        try await withStore { store in
            let personal = try XCTUnwrap(store.accounts(for: .copilot).first)
            let work = try store.addAccount(provider: .copilot, label: "Work")
            let credentials = FakeMobileCredentialStore()
            credentials.values[personal.id] = "personal-token"
            credentials.values[work.id] = "work-token"
            let fetcher = StubMobileActivityFetcher()
            await fetcher.setCounts(
                .init(working: 1, waiting: 2),
                for: "personal-token"
            )
            await fetcher.setCounts(
                .init(working: 4, waiting: 3),
                for: "work-token"
            )
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher,
                now: { Date(timeIntervalSince1970: 2_000) }
            )

            await controller.refresh(accountID: personal.id)
            await controller.refresh(accountID: work.id)

            XCTAssertEqual(controller.snapshot(for: personal).open, 3)
            XCTAssertEqual(controller.snapshot(for: work).open, 7)
            let requestedCredentials = await fetcher.requestedCredentials()
            XCTAssertEqual(
                requestedCredentials,
                ["personal-token", "work-token"]
            )
        }
    }

    @MainActor
    func testTransientFailurePreservesPriorCountsAsStale() async throws {
        try await withStore { store in
            let account = try XCTUnwrap(store.accounts(for: .copilot).first)
            let credentials = FakeMobileCredentialStore()
            credentials.values[account.id] = "token"
            let fetcher = StubMobileActivityFetcher()
            await fetcher.setCounts(.init(working: 2, waiting: 1), for: "token")
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher,
                now: { Date(timeIntervalSince1970: 3_000) }
            )

            await controller.refresh(accountID: account.id)
            await fetcher.setFailure(.transient, for: "token")
            await controller.refresh(accountID: account.id)

            let snapshot = controller.snapshot(for: account)
            XCTAssertEqual(snapshot.availability, .stale)
            XCTAssertEqual(snapshot.open, 3)
            XCTAssertEqual(snapshot.observedAt, Date(timeIntervalSince1970: 3_000))
        }
    }

    @MainActor
    func testAvailableCountsAgeOutWithoutAnotherRequest() async throws {
        try await withStore { store in
            let account = try XCTUnwrap(store.accounts(for: .copilot).first)
            let credentials = FakeMobileCredentialStore()
            credentials.values[account.id] = "token"
            let fetcher = StubMobileActivityFetcher()
            await fetcher.setCounts(.init(working: 2, waiting: 1), for: "token")
            var currentDate = Date(timeIntervalSince1970: 4_000)
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher,
                now: { currentDate },
                freshnessInterval: 60
            )

            await controller.refresh(accountID: account.id)
            XCTAssertEqual(
                controller.snapshot(for: account).availability,
                .available
            )

            currentDate.addTimeInterval(61)

            let stale = controller.snapshot(for: account)
            XCTAssertEqual(stale.availability, .stale)
            XCTAssertEqual(stale.open, 3)
        }
    }

    @MainActor
    func testReplacingCredentialCancelsFetchBeforeKeychainWrite()
        async throws {
        try await withStore { store in
            let account = try XCTUnwrap(store.accounts(for: .copilot).first)
            let events = MobileActivityEventRecorder()
            let credentials = FakeMobileCredentialStore(events: events)
            credentials.values[account.id] = "old-token"
            let fetcher = BlockingMobileActivityFetcher(events: events)
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher
            )
            let refresh = Task { @MainActor in
                await controller.refresh(accountID: account.id)
            }
            await fetcher.waitUntilStarted()

            try controller.saveCredential("new-token", for: account.id)
            await refresh.value

            XCTAssertEqual(
                events.snapshot(),
                [.started, .cancelled, .saved]
            )
            XCTAssertEqual(credentials.values[account.id], "new-token")
        }
    }

    @MainActor
    func testClearCancelsFetchBeforeKeychainDeletion() async throws {
        try await withStore { store in
            let account = try XCTUnwrap(store.accounts(for: .copilot).first)
            let events = MobileActivityEventRecorder()
            let credentials = FakeMobileCredentialStore(events: events)
            credentials.values[account.id] = "token"
            let fetcher = BlockingMobileActivityFetcher(events: events)
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher
            )
            let refresh = Task { @MainActor in
                await controller.refresh(accountID: account.id)
            }
            await fetcher.waitUntilStarted()

            try controller.clearAllSessionData()
            await refresh.value

            XCTAssertEqual(
                events.snapshot(),
                [.started, .cancelled, .deletedAll]
            )
        }
    }

    @MainActor
    func testAuthenticationFailureDiscardsPriorCounts() async throws {
        try await withStore { store in
            let account = try XCTUnwrap(store.accounts(for: .copilot).first)
            let credentials = FakeMobileCredentialStore()
            credentials.values[account.id] = "token"
            let fetcher = StubMobileActivityFetcher()
            await fetcher.setCounts(.init(working: 1, waiting: 0), for: "token")
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher
            )

            await controller.refresh(accountID: account.id)
            await fetcher.setFailure(.authentication, for: "token")
            await controller.refresh(accountID: account.id)

            let snapshot = controller.snapshot(for: account)
            XCTAssertEqual(snapshot.availability, .authenticationRequired)
            XCTAssertNil(snapshot.open)
        }
    }

    @MainActor
    func testPermissionFailureIsDistinctAndDiscardsCounts() async throws {
        try await withStore { store in
            let account = try XCTUnwrap(store.accounts(for: .copilot).first)
            let credentials = FakeMobileCredentialStore()
            credentials.values[account.id] = "token"
            let fetcher = StubMobileActivityFetcher()
            await fetcher.setCounts(.init(working: 1, waiting: 0), for: "token")
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher
            )

            await controller.refresh(accountID: account.id)
            await fetcher.setFailure(.insufficientPermissions, for: "token")
            await controller.refresh(accountID: account.id)

            let snapshot = controller.snapshot(for: account)
            XCTAssertEqual(snapshot.availability, .insufficientPermissions)
            XCTAssertNil(snapshot.open)
        }
    }

    @MainActor
    func testAutomaticRefreshHonorsRateLimitButManualRefreshBypassesIt()
        async throws {
        try await withStore { store in
            let account = try XCTUnwrap(store.accounts(for: .copilot).first)
            let credentials = FakeMobileCredentialStore()
            credentials.values[account.id] = "token"
            let fetcher = StubMobileActivityFetcher()
            let retryAt = Date(timeIntervalSince1970: 9_000)
            await fetcher.setFailure(.rateLimited(retryAt), for: "token")
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher,
                now: { Date(timeIntervalSince1970: 8_000) }
            )

            await controller.refresh(accountID: account.id)
            XCTAssertEqual(
                controller.snapshot(for: account).availability,
                .rateLimited
            )
            await fetcher.setCounts(.init(working: 2, waiting: 0), for: "token")

            await controller.refreshEnabledAccounts()
            var requests = await fetcher.requestedCredentials()
            XCTAssertEqual(requests, ["token"])

            await controller.refresh(accountID: account.id)
            requests = await fetcher.requestedCredentials()
            XCTAssertEqual(requests, ["token", "token"])
            XCTAssertEqual(controller.snapshot(for: account).open, 2)
        }
    }

    @MainActor
    func testRemovalDeletesOnlyTargetCredentialAndCommitsRegistry()
        async throws {
        try await withStore { store in
            let primary = try XCTUnwrap(store.accounts(for: .copilot).first)
            let work = try store.addAccount(provider: .copilot, label: "Work")
            let credentials = FakeMobileCredentialStore()
            credentials.values[primary.id] = "personal"
            credentials.values[work.id] = "work"
            let model = MobileAppModel(
                accountStore: store,
                credentialStore: credentials,
                fetcher: StubMobileActivityFetcher()
            )

            try model.removeAccount(id: work.id)

            XCTAssertNil(store.account(id: work.id))
            XCTAssertNil(credentials.values[work.id])
            XCTAssertEqual(credentials.values[primary.id], "personal")
            XCTAssertEqual(credentials.deletedAccountIDs, [work.id])
        }
    }

    @MainActor
    func testClearAllDeletesCredentialsAndCountsButKeepsAccounts()
        async throws {
        try await withStore { store in
            let account = try XCTUnwrap(store.accounts(for: .copilot).first)
            let credentials = FakeMobileCredentialStore()
            credentials.values[account.id] = "token"
            let fetcher = StubMobileActivityFetcher()
            await fetcher.setCounts(.init(working: 1, waiting: 1), for: "token")
            let controller = MobileSessionActivityController(
                accountResolver: store,
                credentialStore: credentials,
                fetcher: fetcher
            )
            await controller.refresh(accountID: account.id)

            try controller.clearAllSessionData()

            XCTAssertTrue(credentials.values.isEmpty)
            XCTAssertEqual(credentials.deleteAllCount, 1)
            XCTAssertTrue(controller.snapshotsByAccountID.isEmpty)
            XCTAssertNotNil(store.account(id: account.id))
        }
    }

    @MainActor
    func testInconsistentDecodedSnapshotFailsClosed() throws {
        let object: [String: Any] = [
            "accountID": UUID().uuidString,
            "provider": "copilot",
            "availability": "available"
        ]
        let data = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try JSONDecoder().decode(
                MobileSessionActivitySnapshot.self,
                from: data
            )
        )
    }

    @MainActor
    private func withStore(
        _ body: (MobileAccountStore) async throws -> Void
    ) async rethrows {
        let suiteName = "MobileActivityTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(MobileAccountStore(defaults: defaults))
    }
}

@MainActor
private final class FakeMobileCredentialStore: MobileSessionCredentialStoring {
    var values: [UUID: String] = [:]
    private(set) var deletedAccountIDs: [UUID] = []
    private(set) var deleteAllCount = 0
    private let events: MobileActivityEventRecorder?

    init(events: MobileActivityEventRecorder? = nil) {
        self.events = events
    }

    func credential(for accountID: UUID) throws -> String? {
        values[accountID]
    }

    func saveCredential(_ credential: String, for accountID: UUID) throws {
        values[accountID] = credential
        events?.record(.saved)
    }

    func deleteCredential(for accountID: UUID) throws {
        deletedAccountIDs.append(accountID)
        values.removeValue(forKey: accountID)
    }

    func deleteAllCredentials() throws {
        deleteAllCount += 1
        values.removeAll()
        events?.record(.deletedAll)
    }
}

private final class MobileActivityEventRecorder: @unchecked Sendable {
    enum Event: Equatable {
        case started
        case cancelled
        case saved
        case deletedAll
    }

    private let lock = NSLock()
    private var events: [Event] = []

    func record(_ event: Event) {
        lock.withLock {
            events.append(event)
        }
    }

    func snapshot() -> [Event] {
        lock.withLock { events }
    }
}

private final class BlockingMobileActivityFetcher:
    GitHubAgentTaskFetching,
    @unchecked Sendable {
    private let events: MobileActivityEventRecorder
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(events: MobileActivityEventRecorder) {
        self.events = events
    }

    func waitUntilStarted() async {
        while !events.snapshot().contains(.started) {
            await Task.yield()
        }
    }

    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        events.record(.started)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if Task.isCancelled {
                        return true
                    }
                    self.continuation = continuation
                    return false
                }
                if resumeImmediately { continuation.resume() }
            }
        } onCancel: {
            events.record(.cancelled)
            let continuation = lock.withLock {
                let pending = self.continuation
                self.continuation = nil
                return pending
            }
            continuation?.resume()
        }
        try Task.checkCancellation()
        return .init(working: 0, waiting: 0)
    }
}

private actor StubMobileActivityFetcher: GitHubAgentTaskFetching {
    enum Failure: Sendable {
        case transient
        case authentication
        case insufficientPermissions
        case rateLimited(Date)
    }

    private var countsByCredential: [String: SessionActivityCounts] = [:]
    private var failuresByCredential: [String: Failure] = [:]
    private var requests: [String] = []

    func setCounts(
        _ counts: SessionActivityCounts,
        for credential: String
    ) {
        countsByCredential[credential] = counts
        failuresByCredential.removeValue(forKey: credential)
    }

    func setFailure(_ failure: Failure, for credential: String) {
        failuresByCredential[credential] = failure
    }

    func requestedCredentials() -> [String] {
        requests
    }

    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        requests.append(credential)
        switch failuresByCredential[credential] {
        case .authentication:
            throw GitHubAgentTaskFetcherError.authenticationRequired
        case .insufficientPermissions:
            throw GitHubAgentTaskFetcherError.insufficientPermissions
        case .rateLimited(let retryAt):
            throw GitHubAgentTaskFetcherError.rateLimited(retryAt: retryAt)
        case .transient:
            throw GitHubAgentTaskFetcherError.invalidResponse
        case nil:
            guard let counts = countsByCredential[credential] else {
                throw GitHubAgentTaskFetcherError.invalidResponse
            }
            return counts
        }
    }
}
