import WebKit
import XCTest
@testable import AgentLimits

@MainActor
final class UsageWebViewActivationPolicyTests: XCTestCase {
    func testForegroundProviderSurvivesBackgroundPolicyUpdateDuringClear() {
        var policy = UsageWebViewActivationPolicy()
        policy.setBackgroundProviders([.chatgptCodex, .claudeCode])
        policy.setForegroundProvider(.githubCopilot)

        policy.setBackgroundProviders([])

        XCTAssertEqual(policy.activeProviders, [.githubCopilot])
    }

    func testClosingSettingsRestoresOnlyLatestBackgroundPolicy() {
        var policy = UsageWebViewActivationPolicy()
        policy.setBackgroundProviders([.chatgptCodex])
        policy.setForegroundProvider(.githubCopilot)

        policy.setBackgroundProviders([.claudeCode])
        policy.clearForegroundProvider()

        XCTAssertEqual(policy.activeProviders, [.claudeCode])
    }

    func testPoolBlocksResumeAndReloadUntilClearFinishes() throws {
        let pool = UsageWebViewPool(providers: [.chatgptCodex, .claudeCode])
        let codexStore = pool.getWebViewStore(for: .chatgptCodex)
        let claudeStore = pool.getWebViewStore(for: .claudeCode)
        let clear = try XCTUnwrap(pool.beginDataClear())

        pool.resume(.chatgptCodex)
        pool.reloadFromOrigin(.chatgptCodex)
        XCTAssertTrue(codexStore.isSuspended)

        pool.applyBackgroundPolicy(activeProviders: [.claudeCode])
        pool.clearForegroundProvider()
        XCTAssertTrue(claudeStore.isSuspended)

        XCTAssertTrue(pool.finishDataClear(clear))
        XCTAssertTrue(codexStore.isSuspended)
        XCTAssertFalse(claudeStore.isSuspended)

        pool.applyBackgroundPolicy(activeProviders: [])
        XCTAssertTrue(claudeStore.isSuspended)
    }

    func testWebsiteDataRemovalRunsOnlyInsideExclusiveNavigationInterval() async throws {
        let websiteDataClearer = SuspendingWebsiteDataClearer()
        let pool = UsageWebViewPool(
            providers: [.chatgptCodex],
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
}

@MainActor
private final class SuspendingWebsiteDataClearer: WebsiteDataClearing {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func clearAllWebsiteData() async throws {
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
