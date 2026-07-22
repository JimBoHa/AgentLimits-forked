import XCTest
@testable import AgentLimitsiOS

final class MobileAppRuntimeTests: XCTestCase {
    @MainActor
    func testUITestRuntimeIsMutableAndUsesIsolatedServices() async throws {
        let arguments = [
            "AgentLimits",
            "-ui-testing-reset"
        ]
        XCTAssertFalse(
            MobileAppRuntime.isUITesting(arguments: ["AgentLimits"])
        )
        XCTAssertTrue(MobileAppRuntime.isUITesting(arguments: arguments))
        let runtime = MobileAppRuntime.make(arguments: arguments)

        XCTAssertFalse(runtime.watchConnectivityEnabled)
        XCTAssertTrue(runtime.model.accountStore.canMutate)

        let account = try runtime.model.addAccount(
            provider: .copilot,
            label: "Work Copilot"
        )
        try await runtime.model.activityController.saveCredential(
            "ui-test-credential",
            for: account.id
        )
        XCTAssertTrue(
            try runtime.model.activityController.hasCredential(
                for: account.id
            )
        )

        await runtime.model.activityController.refresh(accountID: account.id)
        XCTAssertEqual(
            runtime.model.activityController.snapshot(for: account)
                .availability,
            .unavailable
        )
        XCTAssertEqual(
            runtime.model.accountStore.accounts(for: .copilot).count,
            2
        )
    }

    @MainActor
    func testUITestRuntimeResetClearsOnlyIsolatedState() throws {
        let standardDefaults = UserDefaults.standard
        let productionKey = MobileAccountStore.persistenceKey
        let originalProductionValue = standardDefaults.object(
            forKey: productionKey
        )
        let productionSentinel = Data(
            "MobileAppRuntimeTests.production-account-sentinel"
                .utf8
        )
        standardDefaults.set(productionSentinel, forKey: productionKey)
        defer {
            if let originalProductionValue {
                standardDefaults.set(
                    originalProductionValue,
                    forKey: productionKey
                )
            } else {
                standardDefaults.removeObject(forKey: productionKey)
            }
        }
        let arguments = ["AgentLimits", "-ui-testing-reset"]
        let firstRuntime = MobileAppRuntime.make(arguments: arguments)
        _ = try firstRuntime.model.addAccount(
            provider: .copilot,
            label: "Work Copilot"
        )

        let resetRuntime = MobileAppRuntime.make(arguments: arguments)

        XCTAssertTrue(resetRuntime.model.accountStore.canMutate)
        XCTAssertEqual(
            resetRuntime.model.accountStore.accounts(for: .copilot).count,
            1
        )
        XCTAssertEqual(
            standardDefaults.data(forKey: productionKey),
            productionSentinel
        )
    }

    @MainActor
    func testAppStoreScreenshotRuntimeUsesOnlyFictionalIsolatedData()
        async throws {
        let standardDefaults = UserDefaults.standard
        let productionKey = MobileAccountStore.persistenceKey
        let originalProductionValue = standardDefaults.object(
            forKey: productionKey
        )
        let productionSentinel = Data(
            "MobileAppRuntimeTests.screenshot-production-sentinel".utf8
        )
        standardDefaults.set(productionSentinel, forKey: productionKey)
        defer {
            if let originalProductionValue {
                standardDefaults.set(
                    originalProductionValue,
                    forKey: productionKey
                )
            } else {
                standardDefaults.removeObject(forKey: productionKey)
            }
        }
        let arguments = ["AgentLimits", "-ui-testing-sample-data"]
        XCTAssertFalse(
            MobileAppRuntime.isAppStoreScreenshotTesting(
                arguments: ["AgentLimits"]
            )
        )
        XCTAssertTrue(
            MobileAppRuntime.isAppStoreScreenshotTesting(
                arguments: arguments
            )
        )

        let runtime = MobileAppRuntime.make(arguments: arguments)
        XCTAssertFalse(runtime.watchConnectivityEnabled)
        XCTAssertEqual(
            runtime.model.accountStore.accounts.map(\.id),
            [
                AppStoreScreenshotFixture.personalCodexID,
                AppStoreScreenshotFixture.personalClaudeID,
                AppStoreScreenshotFixture.personalCopilotID,
                AppStoreScreenshotFixture.workCopilotID
            ]
        )
        XCTAssertEqual(
            runtime.model.accountStore.accounts.map(\.label),
            [
                "Personal Codex",
                "Personal Claude",
                "Personal Copilot",
                "Work Copilot"
            ]
        )

        await runtime.model.refreshEnabledAccounts()

        let personal = try XCTUnwrap(
            runtime.model.accountStore.account(
                id: AppStoreScreenshotFixture.personalCopilotID
            )
        )
        let work = try XCTUnwrap(
            runtime.model.accountStore.account(
                id: AppStoreScreenshotFixture.workCopilotID
            )
        )
        XCTAssertEqual(
            runtime.model.activityController.snapshot(for: personal).open,
            5
        )
        XCTAssertEqual(
            runtime.model.activityController.snapshot(for: work).open,
            8
        )
        XCTAssertEqual(
            standardDefaults.data(forKey: productionKey),
            productionSentinel
        )
    }
}
