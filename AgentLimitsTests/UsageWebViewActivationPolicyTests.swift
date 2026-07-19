import Foundation
import WebKit
import XCTest
@testable import AgentLimits

@MainActor
final class UsageWebViewActivationPolicyTests: XCTestCase {
    func testForegroundProviderSurvivesBackgroundPolicyUpdateDuringClear() {
        var policy = UsageWebViewActivationPolicy()
        let codexID = UUID()
        let claudeID = UUID()
        let copilotID = UUID()
        policy.setBackgroundAccounts([codexID, claudeID])
        policy.setForegroundAccountID(copilotID, for: .githubCopilot)

        policy.setBackgroundAccounts([])

        XCTAssertEqual(policy.activeAccountIDs, [copilotID])
    }

    func testClosingSettingsRestoresOnlyLatestBackgroundPolicy() {
        var policy = UsageWebViewActivationPolicy()
        let codexID = UUID()
        let claudeID = UUID()
        let copilotID = UUID()
        policy.setBackgroundAccounts([codexID])
        policy.setForegroundAccountID(copilotID, for: .githubCopilot)

        policy.setBackgroundAccounts([claudeID])
        policy.clearForegroundAccount()

        XCTAssertEqual(policy.activeAccountIDs, [claudeID])
    }

    func testForegroundSelectionKeepsBackgroundSiblingForSameProvider() {
        var policy = UsageWebViewActivationPolicy()
        let personalID = UUID()
        let workID = UUID()
        policy.setBackgroundAccounts([personalID])

        policy.setForegroundAccountID(workID, for: .chatgptCodex)

        XCTAssertEqual(policy.activeAccountIDs, [personalID, workID])
        policy.clearForegroundAccount()

        XCTAssertEqual(policy.activeAccountIDs, [personalID])
    }

    func testBackgroundUpdateKeepsForegroundAndBackgroundSiblingsActive() {
        var policy = UsageWebViewActivationPolicy()
        let personalID = UUID()
        let workID = UUID()
        policy.setForegroundAccountID(personalID, for: .chatgptCodex)

        policy.setBackgroundAccounts([workID])

        XCTAssertEqual(policy.activeAccountIDs, [personalID, workID])
        policy.clearForegroundAccount()
        XCTAssertEqual(policy.activeAccountIDs, [workID])
    }

    func testMultipleBackgroundAccountsForSameProviderRemainActive() {
        var policy = UsageWebViewActivationPolicy()
        let personalID = UUID()
        let workID = UUID()

        policy.setBackgroundAccounts([personalID, workID])

        XCTAssertEqual(policy.backgroundAccountIDs, [personalID, workID])
        XCTAssertEqual(policy.activeAccountIDs, [personalID, workID])
    }

    func testAccountReplacementPreservesOtherBackgroundAccounts() {
        var policy = UsageWebViewActivationPolicy()
        let removedID = UUID()
        let replacementID = UUID()
        let otherID = UUID()
        policy.setBackgroundAccounts([removedID, otherID])
        policy.setForegroundAccountID(removedID, for: .chatgptCodex)

        XCTAssertTrue(
            policy.replaceAccountID(
                removedID,
                with: replacementID,
                for: .chatgptCodex
            )
        )

        XCTAssertEqual(policy.backgroundAccountIDs, [replacementID, otherID])
        XCTAssertEqual(policy.activeAccountIDs, [replacementID, otherID])
    }

    func testPoolKeepsMultipleSameProviderBackgroundAccountsActive() throws {
        let accountStore = makeAccountStore()
        let personal = accountStore.selectedAccount(for: .chatgptCodex)
        let work = try accountStore.addAccount(
            provider: .chatgptCodex,
            label: "Work"
        )
        let pool = UsageWebViewPool(
            providers: [.chatgptCodex],
            accountStore: accountStore,
            websiteDataStoreProvider: { _ in .nonPersistent() }
        )
        let personalStore = pool.getWebViewStore(for: personal)
        let workStore = pool.getWebViewStore(for: work)

        pool.applyBackgroundPolicy(activeAccounts: [personal, work])

        XCTAssertFalse(personalStore.isSuspended)
        XCTAssertFalse(workStore.isSuspended)

        pool.applyBackgroundPolicy(activeAccounts: [work])

        XCTAssertTrue(personalStore.isSuspended)
        XCTAssertFalse(workStore.isSuspended)
    }

    func testPoolBlocksResumeAndReloadUntilClearFinishes() throws {
        let pool = UsageWebViewPool(
            providers: [.chatgptCodex, .claudeCode],
            accountStore: makeAccountStore()
        )
        let codexStore = pool.getWebViewStore(for: .chatgptCodex)
        let claudeStore = pool.getWebViewStore(for: .claudeCode)
        let clear = try XCTUnwrap(pool.beginDataClear())

        pool.resume(.chatgptCodex)
        pool.reloadFromOrigin(.chatgptCodex)
        XCTAssertTrue(codexStore.isSuspended)

        pool.applyBackgroundPolicy(activeProviders: [.claudeCode])
        pool.clearForegroundProvider()
        XCTAssertTrue(claudeStore.isSuspended)

        XCTAssertTrue(pool.cancelDataClear(clear))
        XCTAssertTrue(codexStore.isSuspended)
        XCTAssertFalse(claudeStore.isSuspended)

        pool.applyBackgroundPolicy(activeProviders: [])
        XCTAssertTrue(claudeStore.isSuspended)
    }

    func testWebsiteDataRemovalRunsOnlyInsideExclusiveNavigationInterval() async throws {
        let websiteDataClearer = SuspendingWebsiteDataClearer()
        let pool = UsageWebViewPool(
            providers: [.chatgptCodex],
            accountStore: makeAccountStore(),
            websiteDataClearer: websiteDataClearer
        )
        let store = pool.getWebViewStore(for: .chatgptCodex)
        pool.resume(.chatgptCodex)
        let localPageURL = try XCTUnwrap(
            URL(string: "data:text/html,%3Chtml%3Eactive%3C/html%3E")
        )
        store.webView.load(URLRequest(url: localPageURL))
        await waitUntilNavigationSettles(store.webView, expectedScheme: "data")
        XCTAssertEqual(store.webView.url?.scheme, "data")

        let clear = try XCTUnwrap(pool.beginDataClear())

        XCTAssertTrue(store.isDataClearInProgress)
        XCTAssertFalse(
            store.shouldAllowNavigation(in: store.webView, to: UsageProvider.chatgptCodex.usageURL)
        )
        XCTAssertTrue(
            store.shouldAllowNavigation(in: store.webView, to: URL(string: "about:blank"))
        )
        XCTAssertFalse(store.shouldCreatePopup(from: store.webView))

        let clearTask = Task {
            try await pool.clearWebsiteData(clear)
        }
        await websiteDataClearer.waitUntilStarted()

        XCTAssertTrue(store.isDataClearInProgress)
        XCTAssertEqual(store.webView.url?.absoluteString, "about:blank")
        pool.reloadFromOrigin(.chatgptCodex)
        XCTAssertTrue(store.isSuspended)
        pool.clearForegroundProvider()

        websiteDataClearer.finish()
        try await clearTask.value
        XCTAssertTrue(pool.finishDataClear(clear))
        XCTAssertFalse(store.isDataClearInProgress)
        XCTAssertTrue(store.isSuspended)
    }

    func testStoppedNavigationFailureCannotResolveBlankQuiescence() async throws {
        let websiteDataClearer = SuspendingWebsiteDataClearer()
        let pool = UsageWebViewPool(
            providers: [.chatgptCodex],
            accountStore: makeAccountStore(),
            websiteDataClearer: websiteDataClearer
        )
        let store = pool.getWebViewStore(for: .chatgptCodex)
        pool.resume(.chatgptCodex)
        let staleNavigation = try XCTUnwrap(
            store.webView.load(
                URLRequest(
                    url: try XCTUnwrap(
                        URL(string: "data:text/html,%3Chtml%3Estale%3C/html%3E")
                    )
                )
            )
        )
        let clear = try XCTUnwrap(pool.beginDataClear())
        let clearTask = Task(priority: .high) {
            try await pool.clearWebsiteData(clear)
        }
        await Task.yield()

        XCTAssertTrue(store.isAwaitingDataClearQuiescence)
        store.navigationDidFail(in: store.webView, navigation: staleNavigation)
        XCTAssertTrue(store.isAwaitingDataClearQuiescence)

        await websiteDataClearer.waitUntilStarted()
        websiteDataClearer.finish()
        try await clearTask.value
        XCTAssertTrue(pool.finishDataClear(clear))
    }

    private func waitUntilNavigationSettles(
        _ webView: WKWebView,
        expectedScheme: String
    ) async {
        for _ in 0..<200 {
            if webView.url?.scheme == expectedScheme, !webView.isLoading {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("WebView did not finish loading \(expectedScheme)")
    }

    private func makeAccountStore() -> ProviderAccountStore {
        let defaults = UserDefaults(
            suiteName: "UsageWebViewActivationPolicyTests-\(UUID().uuidString)"
        )!
        return ProviderAccountStore(
            userDefaults: defaults,
            key: "test_accounts"
        )
    }
}

@MainActor
private final class SuspendingWebsiteDataClearer: WebsiteDataClearing {
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
