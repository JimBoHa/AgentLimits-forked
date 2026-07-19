import XCTest
@testable import AgentLimits

@MainActor
final class TokenUsageViewModelClearTests: XCTestCase {
    func testExternalSnapshotSaveAndClearStayInSyncWithMemory() throws {
        let store = FakeTokenUsageSnapshotStore()
        let visibilityStore = FakeSnapshotVisibilityStore()
        let viewModel = makeViewModel(store: store, visibilityStore: visibilityStore)
        let snapshot = makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 1_000))
        let context = try XCTUnwrap(
            viewModel.captureExternalSnapshotContext(for: .copilot)
        )

        try viewModel.saveExternallyFetchedSnapshot(snapshot, context: context)
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

    func testDataClearInvalidatesStaleFetchWithoutFinishingNewerFetch() async throws {
        let store = FakeTokenUsageSnapshotStore()
        let visibilityStore = FakeSnapshotVisibilityStore()
        let fetcher = ControlledCCUsageFetcher()
        let viewModel = makeViewModel(
            store: store,
            visibilityStore: visibilityStore,
            fetcher: fetcher
        )
        let oldSnapshot = makeSnapshot(
            provider: .codex,
            fetchedAt: Date(timeIntervalSince1970: 3_000)
        )
        let newSnapshot = makeSnapshot(
            provider: .codex,
            fetchedAt: Date(timeIntervalSince1970: 4_000)
        )

        let oldTask = Task { await viewModel.refreshNow(for: .codex) }
        await waitForRequestCount(1, fetcher: fetcher)

        let clearToken = try XCTUnwrap(viewModel.beginDataClear())
        XCTAssertTrue(viewModel.clearAllSnapshots(during: clearToken).isEmpty)
        XCTAssertTrue(viewModel.finishDataClear(clearToken))

        let newTask = Task { await viewModel.refreshNow(for: .codex) }
        await waitForRequestCount(2, fetcher: fetcher)
        XCTAssertTrue(viewModel.isFetching[.codex] ?? false)

        fetcher.succeedRequest(at: 0, with: oldSnapshot)
        await oldTask.value

        XCTAssertNil(store.snapshots[.codex])
        XCTAssertNil(viewModel.snapshots[.codex])
        XCTAssertTrue(viewModel.isFetching[.codex] ?? false)

        fetcher.succeedRequest(at: 0, with: newSnapshot)
        await newTask.value

        XCTAssertEqual(store.snapshots[.codex]?.fetchedAt, newSnapshot.fetchedAt)
        XCTAssertEqual(viewModel.snapshots[.codex]?.fetchedAt, newSnapshot.fetchedAt)
        XCTAssertFalse(viewModel.isFetching[.codex] ?? true)
    }

    func testStaleExternalWriteCannotUndoFailedDeletionSuppression() throws {
        let oldSnapshot = makeSnapshot(
            provider: .copilot,
            fetchedAt: Date(timeIntervalSince1970: 5_000)
        )
        let freshSnapshot = makeSnapshot(
            provider: .copilot,
            fetchedAt: Date(timeIntervalSince1970: 6_000)
        )
        let store = FakeTokenUsageSnapshotStore(snapshots: [.copilot: oldSnapshot])
        store.deletionError = TestStoreError.deleteFailed
        let visibilityStore = FakeSnapshotVisibilityStore()
        let viewModel = makeViewModel(store: store, visibilityStore: visibilityStore)
        let staleContext = try XCTUnwrap(
            viewModel.captureExternalSnapshotContext(for: .copilot)
        )

        XCTAssertThrowsError(try viewModel.clearSnapshot(for: .copilot))

        let staleWriteSaved = try viewModel.saveExternallyFetchedSnapshot(
            freshSnapshot,
            context: staleContext
        )
        XCTAssertFalse(staleWriteSaved)
        XCTAssertEqual(store.snapshots[.copilot]?.fetchedAt, oldSnapshot.fetchedAt)
        XCTAssertNil(viewModel.snapshots[.copilot])
        XCTAssertTrue(
            visibilityStore.isSnapshotSuppressed(
                fileName: TokenUsageProvider.copilot.snapshotFileName
            )
        )

        store.deletionError = nil
        let freshContext = try XCTUnwrap(
            viewModel.captureExternalSnapshotContext(for: .copilot)
        )
        let freshWriteSaved = try viewModel.saveExternallyFetchedSnapshot(
            freshSnapshot,
            context: freshContext
        )
        XCTAssertTrue(freshWriteSaved)
        XCTAssertEqual(store.snapshots[.copilot]?.fetchedAt, freshSnapshot.fetchedAt)
        XCTAssertEqual(viewModel.snapshots[.copilot]?.fetchedAt, freshSnapshot.fetchedAt)
        XCTAssertFalse(
            visibilityStore.isSnapshotSuppressed(
                fileName: TokenUsageProvider.copilot.snapshotFileName
            )
        )
    }

    func testDisabledProviderCannotCaptureExternalFetchContext() {
        let viewModel = makeViewModel(
            store: FakeTokenUsageSnapshotStore(),
            visibilityStore: FakeSnapshotVisibilityStore(),
            enabledProviders: []
        )

        XCTAssertNil(viewModel.captureExternalSnapshotContext(for: .copilot))
    }

    func testDisablingProviderRejectsExternalFetchCompletion() throws {
        let store = FakeTokenUsageSnapshotStore()
        let visibilityStore = FakeSnapshotVisibilityStore()
        let viewModel = makeViewModel(store: store, visibilityStore: visibilityStore)
        let initialStatus = viewModel.statusMessages[.copilot]
        let context = try XCTUnwrap(
            viewModel.captureExternalSnapshotContext(for: .copilot)
        )
        viewModel.updateSettings(.defaultSettings(for: .copilot))

        let didSave = try viewModel.saveExternallyFetchedSnapshot(
            makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 7_000)),
            context: context
        )

        XCTAssertFalse(didSave)
        XCTAssertNil(store.snapshots[.copilot])
        XCTAssertNil(viewModel.snapshots[.copilot])
        XCTAssertEqual(viewModel.statusMessages[.copilot], initialStatus)
        XCTAssertFalse(
            visibilityStore.isSnapshotSuppressed(
                fileName: TokenUsageProvider.copilot.snapshotFileName
            )
        )
    }

    func testDisableAndReenableStillRejectsPriorExternalContext() throws {
        let store = FakeTokenUsageSnapshotStore()
        let viewModel = makeViewModel(
            store: store,
            visibilityStore: FakeSnapshotVisibilityStore()
        )
        let context = try XCTUnwrap(
            viewModel.captureExternalSnapshotContext(for: .copilot)
        )
        viewModel.updateSettings(.defaultSettings(for: .copilot))
        viewModel.updateSettings(
            CCUsageSettings(provider: .copilot, isEnabled: true, additionalArgs: "")
        )

        XCTAssertFalse(
            try viewModel.saveExternallyFetchedSnapshot(
                makeSnapshot(fetchedAt: Date(timeIntervalSince1970: 8_000)),
                context: context
            )
        )
        XCTAssertNil(store.snapshots[.copilot])
    }

    func testExternalContextCannotSaveAnotherProviderSnapshot() throws {
        let store = FakeTokenUsageSnapshotStore()
        let viewModel = makeViewModel(
            store: store,
            visibilityStore: FakeSnapshotVisibilityStore(),
            enabledProviders: [.copilot, .codex]
        )
        let copilotContext = try XCTUnwrap(
            viewModel.captureExternalSnapshotContext(for: .copilot)
        )

        XCTAssertFalse(
            try viewModel.saveExternallyFetchedSnapshot(
                makeSnapshot(
                    provider: .codex,
                    fetchedAt: Date(timeIntervalSince1970: 9_000)
                ),
                context: copilotContext
            )
        )
        XCTAssertTrue(store.snapshots.isEmpty)
        XCTAssertTrue(viewModel.snapshots.isEmpty)
    }

    private func makeViewModel(
        store: FakeTokenUsageSnapshotStore,
        visibilityStore: FakeSnapshotVisibilityStore,
        fetcher: (any CCUsageFetching)? = nil,
        enabledProviders: Set<TokenUsageProvider> = [.copilot]
    ) -> TokenUsageViewModel {
        let defaults = UserDefaults(suiteName: "TokenUsageViewModelClearTests-\(UUID().uuidString)")!
        let viewModel = TokenUsageViewModel(
            fetcher: fetcher,
            snapshotStore: store,
            settingsStore: CCUsageSettingsStore(userDefaults: defaults),
            snapshotVisibilityStore: visibilityStore
        )
        for provider in enabledProviders {
            viewModel.updateSettings(
                CCUsageSettings(provider: provider, isEnabled: true, additionalArgs: "")
            )
        }
        return viewModel
    }

    private func makeSnapshot(
        provider: TokenUsageProvider = .copilot,
        fetchedAt: Date
    ) -> TokenUsageSnapshot {
        TokenUsageSnapshot(
            provider: provider,
            fetchedAt: fetchedAt,
            today: TokenUsagePeriod(costUSD: 1, totalTokens: 10),
            thisWeek: TokenUsagePeriod(costUSD: 2, totalTokens: 20),
            thisMonth: TokenUsagePeriod(costUSD: 3, totalTokens: 30)
        )
    }

    private func waitForRequestCount(
        _ expectedCount: Int,
        fetcher: ControlledCCUsageFetcher
    ) async {
        for _ in 0..<100 where fetcher.requestCount < expectedCount {
            await Task.yield()
        }
        XCTAssertEqual(fetcher.requestCount, expectedCount)
    }
}

@MainActor
private final class ControlledCCUsageFetcher: CCUsageFetching {
    private struct PendingRequest {
        let provider: TokenUsageProvider
        let continuation: CheckedContinuation<TokenUsageSnapshot, Error>
    }

    private var pendingRequests: [PendingRequest] = []
    private(set) var requestCount = 0

    func fetchSnapshot(for provider: TokenUsageProvider) async throws -> TokenUsageSnapshot {
        requestCount += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests.append(
                PendingRequest(provider: provider, continuation: continuation)
            )
        }
    }

    func succeedRequest(at index: Int, with snapshot: TokenUsageSnapshot) {
        let request = pendingRequests.remove(at: index)
        XCTAssertEqual(request.provider, snapshot.provider)
        request.continuation.resume(returning: snapshot)
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
