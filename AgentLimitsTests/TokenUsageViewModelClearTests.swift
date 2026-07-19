import XCTest
@testable import AgentLimits

@MainActor
final class TokenUsageViewModelClearTests: XCTestCase {
    func testExternalSnapshotSaveAndClearStayInSyncWithMemory() throws {
        let store = FakeTokenUsageSnapshotStore()
        let visibilityStore = FakeSnapshotVisibilityStore()
        let viewModel = makeViewModel(store: store, visibilityStore: visibilityStore)
        let snapshot = makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_000))

        try viewModel.saveExternallyFetchedSnapshot(snapshot)
        XCTAssertEqual(store.snapshots[.copilot]?.fetchedAt, snapshot.fetchedAt)
        XCTAssertEqual(viewModel.snapshots[.copilot]?.fetchedAt, snapshot.fetchedAt)

        try viewModel.clearSnapshot(for: .copilot)
        XCTAssertNil(store.snapshots[.copilot])
        XCTAssertNil(viewModel.snapshots[.copilot])
        XCTAssertFalse(viewModel.isFetching[.copilot] ?? true)
        XCTAssertFalse(
            visibilityStore.isSnapshotSuppressed(
                fileName: TokenUsageProvider.copilot.snapshotFileName
            )
        )
    }

    func testDeletionFailureStillClearsMemoryAndSurfacesError() async throws {
        let snapshot = makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 2_000))
        let store = FakeTokenUsageSnapshotStore(snapshots: [.copilot: snapshot])
        store.deletionError = TestStoreError.deleteFailed
        let visibilityStore = FakeSnapshotVisibilityStore()
        let viewModel = makeViewModel(store: store, visibilityStore: visibilityStore)
        XCTAssertNotNil(viewModel.snapshots[.copilot])

        XCTAssertThrowsError(try viewModel.clearSnapshot(for: .copilot))

        XCTAssertNil(viewModel.snapshots[.copilot])
        XCTAssertEqual(
            viewModel.statusMessages[.copilot],
            TestStoreError.deleteFailed.localizedDescription
        )
        XCTAssertNotNil(store.snapshots[.copilot])
        XCTAssertTrue(
            visibilityStore.isSnapshotSuppressed(
                fileName: TokenUsageProvider.copilot.snapshotFileName
            )
        )

        await viewModel.refreshNow(for: .copilot)
        XCTAssertNil(viewModel.snapshots[.copilot])

        let relaunchedViewModel = makeViewModel(
            store: store,
            visibilityStore: visibilityStore
        )
        XCTAssertNil(relaunchedViewModel.snapshots[.copilot])
    }

    private func makeViewModel(
        store: FakeTokenUsageSnapshotStore,
        visibilityStore: FakeSnapshotVisibilityStore
    ) -> TokenUsageViewModel {
        let defaults = UserDefaults(suiteName: "TokenUsageViewModelClearTests-\(UUID().uuidString)")!
        return TokenUsageViewModel(
            snapshotStore: store,
            settingsStore: CCUsageSettingsStore(userDefaults: defaults),
            snapshotVisibilityStore: visibilityStore
        )
    }

    private func makeSnapshot(fetchedAt: Date) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            provider: .copilot,
            fetchedAt: fetchedAt,
            today: TokenUsagePeriod(costUSD: 1, totalTokens: 10),
            thisWeek: TokenUsagePeriod(costUSD: 2, totalTokens: 20),
            thisMonth: TokenUsagePeriod(costUSD: 3, totalTokens: 30)
        )
    }
}

@MainActor
private final class FakeTokenUsageSnapshotStore: TokenUsageSnapshotStoring {
    var snapshots: [TokenUsageProvider: TokenUsageSnapshot]
    var deletionError: Error?

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
        if let deletionError {
            throw deletionError
        }
        snapshots.removeValue(forKey: provider)
    }
}

private enum TestStoreError: LocalizedError {
    case deleteFailed

    var errorDescription: String? {
        "Test deletion failed"
    }
}

private final class FakeSnapshotVisibilityStore: SnapshotVisibilityControlling, @unchecked Sendable {
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
