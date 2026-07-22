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

    @MainActor
    func testAppStoreCopilotAccountsScreenshot() {
        let app = launchAppStoreFixture()
        let workAccount = app.descendants(matching: .any)[
            "watch.account.a6100000-0000-4000-8000-000000000004"
        ]

        XCTAssertTrue(workAccount.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Personal Copilot"].exists)
        XCTAssertTrue(app.staticTexts["Work Copilot"].exists)
        XCTAssertTrue(app.staticTexts["5 open"].exists)
        XCTAssertTrue(app.staticTexts["8 open"].exists)

        addStableScreenshot(named: "app-store-watch-copilot-accounts")
    }

    @MainActor
    func testAppStoreCopilotDetailScreenshot() {
        let app = launchAppStoreFixture()
        let workAccount = app.descendants(matching: .any)[
            "watch.account.a6100000-0000-4000-8000-000000000004"
        ]

        XCTAssertTrue(workAccount.waitForExistence(timeout: 5))
        workAccount.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["watch.refreshAccount"]
                .waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.staticTexts["8 open"].exists)
        XCTAssertTrue(app.staticTexts["6"].exists)
        XCTAssertTrue(app.staticTexts["2"].exists)

        dragContent(in: app, fromY: 0.30, toY: 0.70)
        addStableScreenshot(named: "app-store-watch-session-detail")
    }

    @MainActor
    private func launchAppStoreFixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing-sample-data",
            "-AppleLanguages",
            "(en)",
            "-AppleLocale",
            "en_US",
            "-AppleInterfaceStyle",
            "Light",
            "-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryL"
        ]
        app.launch()
        XCTAssertTrue(
            app.descendants(matching: .any)["watch.root"]
                .waitForExistence(timeout: 8)
        )
        return app
    }

    @MainActor
    private func dragContent(
        in app: XCUIApplication,
        fromY: CGFloat,
        toY: CGFloat
    ) {
        let start = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: fromY)
        )
        let end = app.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: toY)
        )
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    @MainActor
    private func captureVisuallyStableScreenshot(
        timeout: TimeInterval = 5,
        sampleInterval: TimeInterval = 0.2,
        requiredMatchingSamples: Int = 3
    ) -> XCUIScreenshot? {
        let deadline = Date().addingTimeInterval(timeout)
        var previousFrame: Data?
        var matchingSamples = 0

        while Date() < deadline {
            let screenshot = XCUIScreen.main.screenshot()
            let frame = screenshot.pngRepresentation
            if frame == previousFrame {
                matchingSamples += 1
                if matchingSamples >= requiredMatchingSamples {
                    return screenshot
                }
            } else {
                previousFrame = frame
                matchingSamples = 0
            }
            RunLoop.current.run(
                until: Date().addingTimeInterval(sampleInterval)
            )
        }
        return nil
    }

    @MainActor
    private func addStableScreenshot(named name: String) {
        guard let screenshot = captureVisuallyStableScreenshot() else {
            XCTFail("Screenshot did not reach repeated identical frames")
            return
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
