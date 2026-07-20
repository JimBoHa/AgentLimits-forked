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
    func testCanAddSelectAndRemoveSecondProviderAccount() {
        let app = launchIsolatedApp()
        let workAccountLabel = "Mac UI Work"

        let claudeProvider = element(
            "mac.usage.provider.claudeCode",
            in: app
        )
        XCTAssertTrue(
            waitForHittable(claudeProvider, timeout: 5),
            "Claude provider segment is missing or off-screen"
        )
        claudeProvider.click()

        let accountPicker = element("mac.usage.accountPicker", in: app)
        XCTAssertTrue(
            waitForValue("Claude Code", of: accountPicker, timeout: 5),
            "Claude account did not become selected"
        )

        let copilotProvider = element(
            "mac.usage.provider.githubCopilot",
            in: app
        )
        XCTAssertTrue(
            waitForHittable(copilotProvider, timeout: 5),
            "Copilot provider segment is missing or off-screen"
        )
        copilotProvider.click()

        XCTAssertTrue(
            waitForValue("Copilot", of: accountPicker, timeout: 5),
            "Copilot account did not become selected"
        )

        element("mac.usage.manageAccounts", in: app).click()
        XCTAssertTrue(
            element("mac.accounts.root", in: app)
                .waitForExistence(timeout: 5),
            "Account manager did not open"
        )

        let addAccount = element("mac.accounts.add", in: app)
        XCTAssertTrue(
            waitForHittable(addAccount, timeout: 5),
            "Account manager controls lost their accessibility identifiers"
        )
        addAccount.click()
        XCTAssertTrue(
            element("mac.accounts.editor.root", in: app)
                .waitForExistence(timeout: 5),
            "Account editor did not open"
        )

        let labelField = element("mac.accounts.editor.label", in: app)
        XCTAssertTrue(labelField.waitForExistence(timeout: 5))
        labelField.click()
        labelField.typeText(workAccountLabel)
        element("mac.accounts.editor.save", in: app).click()

        let selectedWorkAccount = accountSelectedMarker(
            workAccountLabel,
            in: app
        )
        XCTAssertTrue(
            selectedWorkAccount.waitForExistence(timeout: 5),
            "New account was not added and selected"
        )

        element("mac.accounts.close", in: app).click()
        XCTAssertTrue(
            element("mac.accounts.root", in: app)
                .waitForNonExistence(timeout: 5),
            "Account manager did not close"
        )
        XCTAssertTrue(
            waitForValue(workAccountLabel, of: accountPicker, timeout: 5),
            "New account did not reach Usage settings"
        )

        selectAccount("Copilot", from: accountPicker, in: app)
        selectAccount(workAccountLabel, from: accountPicker, in: app)

        element("mac.usage.manageAccounts", in: app).click()
        XCTAssertTrue(
            element("mac.accounts.root", in: app)
                .waitForExistence(timeout: 5),
            "Account manager did not reopen"
        )
        XCTAssertTrue(
            selectedWorkAccount.waitForExistence(timeout: 5),
            "Picker selection did not reach account manager"
        )

        let removeWorkAccount = accountButton(
            identifierPrefix: "mac.accounts.remove.",
            label: "Remove Account — \(workAccountLabel)",
            in: app
        )
        XCTAssertTrue(removeWorkAccount.waitForExistence(timeout: 5))
        removeWorkAccount.click()

        let confirmRemoval = element("mac.accounts.confirmRemove", in: app)
        XCTAssertTrue(
            confirmRemoval.waitForExistence(timeout: 5),
            "Account removal confirmation did not appear"
        )
        confirmRemoval.click()

        XCTAssertTrue(
            app.staticTexts[workAccountLabel]
                .waitForNonExistence(timeout: 15),
            "Removed account remained visible"
        )
        XCTAssertTrue(
            accountSelectedMarker("Copilot", in: app)
                .waitForExistence(timeout: 5),
            "Selection did not return to the remaining account"
        )

        element("mac.accounts.close", in: app).click()
        XCTAssertTrue(
            element("mac.accounts.root", in: app)
                .waitForNonExistence(timeout: 5),
            "Account manager did not close"
        )
        XCTAssertTrue(
            waitForValue("Copilot", of: accountPicker, timeout: 5),
            "Removed account remained selected in Usage settings"
        )
    }

    @MainActor
    func testClearDataCompletesWithoutError() {
        let app = launchIsolatedApp()
        let clearData = element("mac.usage.clearData", in: app)

        XCTAssertTrue(clearData.waitForExistence(timeout: 5))
        XCTAssertTrue(
            waitForValue("completed-0", of: clearData, timeout: 5),
            "Clear Data test state was not initialized"
        )
        clearData.click()

        let confirmClear = element("mac.usage.confirmClearData", in: app)
        XCTAssertTrue(
            confirmClear.waitForExistence(timeout: 5),
            "Clear Data confirmation did not appear"
        )
        confirmClear.click()

        XCTAssertTrue(
            waitForValue("completed-1", of: clearData, timeout: 20),
            "Clear Data did not finish successfully"
        )
        XCTAssertTrue(clearData.isEnabled)
        XCTAssertFalse(app.alerts["Clear Data"].exists)
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

    @MainActor
    private func accountButton(
        identifierPrefix: String,
        label: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND label == %@",
                identifierPrefix,
                label
            )
        ).firstMatch
    }

    @MainActor
    private func accountSelectedMarker(
        _ accountLabel: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        let selectedLabel = "Selected — \(accountLabel)"
        return app.staticTexts.matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@ AND (label == %@ OR value == %@)",
                "mac.accounts.selected.",
                selectedLabel,
                selectedLabel
            )
        ).firstMatch
    }

    @MainActor
    private func selectAccount(
        _ accountLabel: String,
        from picker: XCUIElement,
        in app: XCUIApplication
    ) {
        picker.click()
        let menuItem = app.menuItems[accountLabel]
        XCTAssertTrue(
            waitForHittable(menuItem, timeout: 5),
            "Account picker option is missing: \(accountLabel)"
        )
        menuItem.click()
        XCTAssertTrue(
            waitForValue(accountLabel, of: picker, timeout: 5),
            "Account picker did not select: \(accountLabel)"
        )
    }

    @MainActor
    private func waitForValue(
        _ value: String,
        of element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout)
            == .completed
    }

    @MainActor
    private func waitForHittable(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: element
        )
        return XCTWaiter().wait(for: [expectation], timeout: timeout)
            == .completed
    }
}
