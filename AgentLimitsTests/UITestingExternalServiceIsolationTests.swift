import WebKit
import XCTest
@testable import AgentLimits

@MainActor
final class UITestingExternalServiceIsolationTests: XCTestCase {
    func testUITestingCompositionUsesOnlyInertFetchers() async {
        let dependencies = AppExternalServiceDependencies.make(
            isUITesting: true
        )

        XCTAssertTrue(
            dependencies.ccUsageFetcher is UITestingCCUsageFetcher
        )
        XCTAssertTrue(
            dependencies.usageSnapshotFetcher
                is UITestingUsageSnapshotFetcher
        )
        XCTAssertTrue(
            dependencies.copilotBillingFetcher
                is UITestingCopilotBillingFetcher
        )

        do {
            _ = try await dependencies.ccUsageFetcher.fetchSnapshot(
                for: .codex
            )
            XCTFail("UI-test ccusage fetcher unexpectedly fetched data")
        } catch {
            XCTAssertEqual(
                error as? UITestingExternalServiceError,
                .disabled
            )
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(
            frame: .zero,
            configuration: configuration
        )

        let hasSession = await dependencies.usageSnapshotFetcher
            .hasValidSession(for: .chatgptCodex, using: webView)
        XCTAssertFalse(hasSession)

        do {
            _ = try await dependencies.usageSnapshotFetcher.fetchSnapshot(
                for: .chatgptCodex,
                using: webView
            )
            XCTFail("UI-test web fetcher unexpectedly fetched data")
        } catch {
            XCTAssertEqual(
                error as? UITestingExternalServiceError,
                .disabled
            )
        }

        do {
            _ = try await dependencies.copilotBillingFetcher
                .fetchBillingSnapshot(using: webView)
            XCTFail("UI-test billing fetcher unexpectedly fetched data")
        } catch {
            XCTAssertEqual(
                error as? UITestingExternalServiceError,
                .disabled
            )
        }
    }

    func testProductionCompositionKeepsRealFetcherTypes() {
        let dependencies = AppExternalServiceDependencies.make(
            isUITesting: false
        )

        XCTAssertTrue(dependencies.ccUsageFetcher is CCUsageFetcher)
        XCTAssertTrue(
            dependencies.usageSnapshotFetcher
                is DefaultUsageSnapshotFetcher
        )
        XCTAssertTrue(
            dependencies.copilotBillingFetcher is CopilotBillingFetcher
        )
    }
}
