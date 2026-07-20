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
}
