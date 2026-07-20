import XCTest

final class AgentLimitsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchOpensSettingsWithCoreUsageControls() {
        let app = launchIsolatedApp()

        let identifiers = [
            "mac.usage.root",
            "mac.usage.providerPicker",
            "mac.usage.accountPicker",
            "mac.usage.manageAccounts",
            "mac.usage.refresh",
            "mac.usage.clearData",
        ]
        for identifier in identifiers {
            XCTAssertTrue(
                element(identifier, in: app)
                    .waitForExistence(timeout: 5),
                "Missing core settings control: \(identifier)"
            )
        }
    }

    @MainActor
    func testEverySettingsTabShowsItsCoreContent() {
        let app = launchIsolatedApp()
        let destinations = [
            ("usage", "mac.usage.root"),
            ("wakeUp", "mac.wakeUp.root"),
            ("threshold", "mac.threshold.root"),
            ("pacemaker", "mac.pacemaker.root"),
            ("ccusage", "mac.ccusage.root"),
            ("update", "mac.update.root"),
            ("advanced", "mac.advanced.root"),
        ]

        for (tab, content) in destinations {
            let tabElement = element("mac.settings.tab.\(tab)", in: app)
            XCTAssertTrue(
                tabElement.waitForExistence(timeout: 5),
                "Missing settings tab: \(tab)"
            )
            tabElement.click()
            XCTAssertTrue(
                element(content, in: app).waitForExistence(timeout: 5),
                "Missing content after selecting: \(tab)"
            )
        }
    }

    @MainActor
    func testUsageSettingsHaveSufficientElementDescriptions() throws {
        let app = launchIsolatedApp()
        try app.performAccessibilityAudit(
            for: [.sufficientElementDescription]
        ) { issue in
            guard let element = issue.element else { return false }
            // XCTest audits framework-owned window controls and unlabeled
            // structural containers even though neither is app content.
            let isAppKitElement = element.identifier.hasPrefix("_XCUI:")
                || ([.group, .outline, .touchBar]
                    .contains(element.elementType)
                    && element.identifier.isEmpty
                    && element.label.isEmpty)
            guard !isAppKitElement else { return true }
            XCTFail(
                "\(issue.compactDescription): type=\(element.elementType) "
                    + "identifier=\(element.identifier) "
                    + "label=\(element.label) value=\(element.value ?? "nil")"
            )
            return true
        }
    }

    @MainActor
    private func launchIsolatedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-open-settings",
        ]
        app.launchEnvironment = [
            "TZ": "America/Los_Angeles",
        ]
        app.launch()

        XCTAssertTrue(
            app.windows["settings"].waitForExistence(timeout: 10),
            "Settings window did not open"
        )
        return app
    }

    @MainActor
    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
