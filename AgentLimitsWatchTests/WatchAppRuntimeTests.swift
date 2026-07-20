import Foundation
import XCTest
@testable import AgentLimitsWatch

final class WatchAppRuntimeTests: XCTestCase {
    @MainActor
    func testAppStoreScreenshotRuntimeUsesIsolatedEnvelope() throws {
        let defaults = UserDefaults.standard
        let originalCache = defaults.object(
            forKey: WatchCompanionStore.cacheKey
        )
        let productionSentinel = Data(
            "WatchAppRuntimeTests.production-cache-sentinel".utf8
        )
        defaults.set(productionSentinel, forKey: WatchCompanionStore.cacheKey)
        defer {
            if let originalCache {
                defaults.set(
                    originalCache,
                    forKey: WatchCompanionStore.cacheKey
                )
            } else {
                defaults.removeObject(forKey: WatchCompanionStore.cacheKey)
            }
        }
        let runtime = WatchAppRuntime.make(
            arguments: ["AgentLimitsWatch", "-ui-testing-sample-data"]
        )

        XCTAssertFalse(runtime.connectivityEnabled)
        XCTAssertTrue(runtime.appStoreScreenshotMode)
        XCTAssertTrue(runtime.store.isPhoneReachable)
        XCTAssertEqual(
            runtime.store.envelope?.accounts.map(\.id),
            [
                AppStoreScreenshotFixture.personalCodexID,
                AppStoreScreenshotFixture.personalClaudeID,
                AppStoreScreenshotFixture.personalCopilotID,
                AppStoreScreenshotFixture.workCopilotID
            ]
        )
        XCTAssertEqual(
            runtime.store.account(
                id: AppStoreScreenshotFixture.personalCopilotID
            )?.status.open,
            5
        )
        XCTAssertEqual(
            runtime.store.account(
                id: AppStoreScreenshotFixture.workCopilotID
            )?.status.open,
            8
        )
        XCTAssertEqual(
            defaults.data(forKey: WatchCompanionStore.cacheKey),
            productionSentinel
        )
    }
}
