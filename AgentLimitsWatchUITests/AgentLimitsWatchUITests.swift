import XCTest

final class AgentLimitsWatchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchWithoutPhoneDataShowsRecoveryGuidance() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-reset",
            "-ui-testing-disable-connectivity"
        ]
        app.launch()

        XCTAssertTrue(
            app.descendants(matching: .any)["watch.root"]
                .waitForExistence(timeout: 8)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["watch.noData"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["No iPhone Data"].exists)
    }
}
