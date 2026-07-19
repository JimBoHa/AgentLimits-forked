import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class ProviderStateManagerAccountTests: XCTestCase {
    func testSameProviderAccountsKeepIndependentStateAndSelectionProjection() throws {
        let personal = makeAccount(
            id: "10000000-0000-0000-0000-000000000001",
            provider: .chatgptCodex,
            label: "Personal",
            createdAt: 1
        )
        let work = makeAccount(
            id: "20000000-0000-0000-0000-000000000002",
            provider: .chatgptCodex,
            label: "Work",
            createdAt: 2
        )
        let manager = ProviderStateManager(accounts: [personal, work])
        let personalSnapshot = makeSnapshot(
            provider: .chatgptCodex,
            fetchedAt: 100
        )
        let workSnapshot = makeSnapshot(
            provider: .chatgptCodex,
            fetchedAt: 200
        )

        manager.updateAfterSuccessfulFetch(
            snapshot: personalSnapshot,
            for: personal.id
        )
        manager.setFetching(true, for: personal.id)
        manager.setSnapshot(workSnapshot, for: work.id)
        manager.setFetchStatus(.failure("work failed"), for: work.id)

        XCTAssertEqual(
            manager.getState(for: personal.id).snapshot?.fetchedAt,
            personalSnapshot.fetchedAt
        )
        XCTAssertTrue(manager.getState(for: personal.id).isFetching)
        XCTAssertEqual(
            manager.getState(for: personal.id).lastFetchStatus,
            .success(personalSnapshot.fetchedAt)
        )
        XCTAssertEqual(
            manager.getState(for: work.id).snapshot?.fetchedAt,
            workSnapshot.fetchedAt
        )
        XCTAssertFalse(manager.getState(for: work.id).isFetching)
        XCTAssertEqual(
            manager.getState(for: work.id).lastFetchStatus,
            .failure("work failed")
        )

        XCTAssertEqual(
            manager.selectedSnapshots(for: [.chatgptCodex: personal])[
                .chatgptCodex
            ]?.fetchedAt,
            personalSnapshot.fetchedAt
        )
        XCTAssertEqual(
            manager.selectedSnapshots(for: [.chatgptCodex: work])[
                .chatgptCodex
            ]?.fetchedAt,
            workSnapshot.fetchedAt
        )
        XCTAssertEqual(
            manager.selectedFetchStatuses(for: [.chatgptCodex: personal])[
                .chatgptCodex
            ],
            .success(personalSnapshot.fetchedAt)
        )
        XCTAssertEqual(
            manager.selectedFetchStatuses(for: [.chatgptCodex: work])[
                .chatgptCodex
            ],
            .failure("work failed")
        )
    }

    func testSynchronizationPreservesSurvivorStateAndDropsRemovedAccount() {
        let first = makeAccount(
            id: "30000000-0000-0000-0000-000000000003",
            provider: .claudeCode,
            label: "First",
            createdAt: 1
        )
        let removed = makeAccount(
            id: "40000000-0000-0000-0000-000000000004",
            provider: .claudeCode,
            label: "Removed",
            createdAt: 2
        )
        let added = makeAccount(
            id: "50000000-0000-0000-0000-000000000005",
            provider: .claudeCode,
            label: "Added",
            createdAt: 3
        )
        let snapshot = makeSnapshot(provider: .claudeCode, fetchedAt: 300)
        let manager = ProviderStateManager(accounts: [first, removed])
        manager.updateAfterSuccessfulFetch(snapshot: snapshot, for: first.id)
        manager.setFetching(true, for: removed.id)

        let renamedFirst = first.updating(
            label: "Renamed",
            isEnabled: true,
            cliDataRoot: nil
        )
        manager.synchronizeAccounts([renamedFirst, added])

        XCTAssertEqual(manager.accountIDs, [first.id, added.id])
        XCTAssertEqual(manager.account(id: first.id)?.label, "Renamed")
        XCTAssertEqual(
            manager.getState(for: first.id).snapshot?.fetchedAt,
            snapshot.fetchedAt
        )
        XCTAssertEqual(
            manager.getState(for: removed.id).lastFetchStatus,
            .notFetched
        )
        XCTAssertFalse(manager.getState(for: removed.id).isFetching)
        XCTAssertEqual(
            manager.getState(for: added.id).lastFetchStatus,
            .notFetched
        )
    }

    func testBackgroundAndAutoRefreshEligibilityAreAccountScoped() {
        let selected = makeAccount(
            id: "60000000-0000-0000-0000-000000000006",
            provider: .chatgptCodex,
            label: "Selected",
            createdAt: 1
        )
        let sibling = makeAccount(
            id: "70000000-0000-0000-0000-000000000007",
            provider: .chatgptCodex,
            label: "Sibling",
            createdAt: 2
        )
        let optedOut = makeAccount(
            id: "80000000-0000-0000-0000-000000000008",
            provider: .claudeCode,
            label: "Opted Out",
            createdAt: 3
        )
        let disabled = makeAccount(
            id: "90000000-0000-0000-0000-000000000009",
            provider: .githubCopilot,
            label: "Disabled",
            isEnabled: false,
            createdAt: 4
        )
        let manager = ProviderStateManager(
            accounts: [selected, sibling, optedOut, disabled]
        )

        manager.setSnapshot(
            makeSnapshot(provider: .chatgptCodex, fetchedAt: 400),
            for: selected.id
        )
        manager.updateAfterSuccessfulFetch(
            snapshot: makeSnapshot(provider: .chatgptCodex, fetchedAt: 500),
            for: sibling.id
        )
        manager.setSnapshot(
            makeSnapshot(provider: .claudeCode, fetchedAt: 600),
            for: optedOut.id
        )
        manager.setAutoRefreshEnabled(false, for: optedOut.id)
        manager.updateAfterSuccessfulFetch(
            snapshot: makeSnapshot(provider: .githubCopilot, fetchedAt: 700),
            for: disabled.id
        )

        XCTAssertEqual(
            manager.backgroundActiveAccounts.map(\.id),
            [selected.id, sibling.id, optedOut.id]
        )
        XCTAssertEqual(
            manager.autoRefreshEligibleAccounts(
                selectedAccountIDs: [selected.id]
            ).map(\.id),
            [selected.id, sibling.id]
        )

        manager.setAutoRefreshEnabled(false, for: sibling.id)
        manager.setAutoRefreshEnabled(true, for: optedOut.id)

        XCTAssertEqual(
            manager.autoRefreshEligibleAccounts(
                selectedAccountIDs: [selected.id]
            ).map(\.id),
            [selected.id, optedOut.id]
        )
    }

    private func makeAccount(
        id: String,
        provider: UsageProvider,
        label: String,
        isEnabled: Bool = true,
        createdAt: TimeInterval
    ) -> ProviderAccount {
        ProviderAccount(
            id: UUID(uuidString: id)!,
            provider: provider,
            label: label,
            isEnabled: isEnabled,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
    }

    private func makeSnapshot(
        provider: UsageProvider,
        fetchedAt: TimeInterval
    ) -> UsageSnapshot {
        UsageSnapshot(
            provider: provider,
            fetchedAt: Date(timeIntervalSince1970: fetchedAt),
            primaryWindow: nil,
            secondaryWindow: nil
        )
    }
}
