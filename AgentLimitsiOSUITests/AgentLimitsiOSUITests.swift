import XCTest

final class AgentLimitsiOSUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsEveryProviderAndAccountList() {
        let app = launchFreshApp()

        XCTAssertTrue(
            app.descendants(matching: .any)["mobile.accountList"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.navigationBars["AgentLimits"].exists)
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        XCTAssertTrue(app.staticTexts["Claude Code"].exists)
        XCTAssertTrue(scrollToElement(
            app.staticTexts["GitHub Copilot"],
            in: app
        ))
    }

    @MainActor
    func testAddsSecondCopilotAccount() {
        let app = launchFreshApp()
        let addButton = app.buttons["mobile.addAccount"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 5))

        addButton.tap()
        let copilotOption = app.descendants(matching: .any)[
            "mobile.addAccount.copilot"
        ]
        XCTAssertTrue(copilotOption.waitForExistence(timeout: 5))
        copilotOption.tap()

        let nameField = app.textFields["mobile.accountNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 5))
        nameField.tap()
        nameField.typeText("Work Copilot")
        app.buttons["mobile.saveAccount"].tap()

        XCTAssertTrue(app.staticTexts["Work Copilot"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.switches["Refresh GitHub Copilot when active"].exists
        )
        XCTAssertTrue(
            app.switches["Refresh Work Copilot when active"].exists
        )
        XCTAssertTrue(app.buttons["Refresh GitHub Copilot"].exists)
        XCTAssertTrue(app.buttons["Refresh Work Copilot"].exists)
    }

    @MainActor
    func testPrivacyPolicyIsAccessibleInApp() {
        let app = launchFreshApp()

        let privacy = app.descendants(matching: .any)["mobile.privacy"]
        XCTAssertTrue(scrollToElement(privacy, in: app))
        privacy.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["mobile.privacyPolicy"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["mobile.privacyPolicyLink"].exists
        )
    }

    @MainActor
    func testAccessibilityTextSizeKeepsCoreControlsReachable() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-reset",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["GitHub Copilot"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["mobile.addAccount"].exists)
        XCTAssertTrue(
            app.switches["Refresh GitHub Copilot when active"].exists
        )
    }

    @MainActor
    func testLandscapeLayoutKeepsNavigationAndAccountsReachable() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launchFreshApp(orientation: .landscapeLeft)

        XCTAssertTrue(app.buttons["mobile.addAccount"].waitForExistence(timeout: 5))
        XCTAssertTrue(scrollToElement(
            app.staticTexts["GitHub Copilot"],
            in: app
        ))
        XCTAssertTrue(
            app.descendants(matching: .any)["mobile.accountList"].exists
        )
    }

    @MainActor
    private func launchFreshApp(
        orientation: UIDeviceOrientation = .portrait
    ) -> XCUIApplication {
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = ["-ui-testing-reset"]
        app.launch()
        return app
    }

    @MainActor
    private func scrollToElement(
        _ element: XCUIElement,
        in app: XCUIApplication,
        maximumSwipes: Int = 8
    ) -> Bool {
        if element.waitForExistence(timeout: 1) { return true }
        let accountList = app.descendants(matching: .any)["mobile.accountList"]
        for _ in 0..<maximumSwipes {
            if accountList.exists {
                accountList.swipeUp()
            } else {
                app.swipeUp()
            }
            if element.waitForExistence(timeout: 0.5) { return true }
        }
        return false
    }
}
