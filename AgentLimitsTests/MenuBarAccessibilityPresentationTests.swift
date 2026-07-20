import XCTest
@testable import AgentLimits

final class MenuBarAccessibilityPresentationTests: XCTestCase {
    func testStatusValueAnnouncesUsageAndSessionCountsWithoutAccountDetails() {
        let accountLabel = "Work account — private@example.com"
        let privateDataRoot = "/private/provider-profile"
        let account = ProviderAccount(
            provider: .githubCopilot,
            label: accountLabel,
            cliDataRoot: privateDataRoot
        )
        let usageSnapshot = UsageSnapshot(
            provider: .githubCopilot,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            primaryWindow: makeWindow(kind: .primary, usedPercent: 25),
            secondaryWindow: nil
        )
        let sessionSnapshot = SessionActivitySnapshot.available(
            account: account,
            counts: SessionActivityCounts(working: 2, waiting: 1),
            observedAt: Date(timeIntervalSince1970: 2_000)
        )

        let value = MenuBarAccessibilityPresentation.statusValue(
            states: [
                MenuBarAccessibilityProviderState(
                    account: account,
                    usageSnapshot: usageSnapshot,
                    sessionSnapshot: sessionSnapshot
                )
            ],
            displayMode: .used
        )

        XCTAssertTrue(value.contains(account.provider.displayName))
        XCTAssertTrue(
            value.contains(UsagePercentFormatter.formatPercentText(25))
        )
        XCTAssertTrue(
            value.contains(
                SessionActivityPresentation.summary(
                    for: account,
                    snapshot: sessionSnapshot
                )
            )
        )
        XCTAssertFalse(value.contains(accountLabel))
        XCTAssertFalse(value.contains(privateDataRoot))
    }

    func testDashboardValueRespectsRemainingModeAndNamesBothWindows() {
        let snapshot = UsageSnapshot(
            provider: .chatgptCodex,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            primaryWindow: makeWindow(kind: .primary, usedPercent: 25),
            secondaryWindow: makeWindow(kind: .secondary, usedPercent: 80)
        )

        let value = MenuBarAccessibilityPresentation.dashboardValue(
            provider: .chatgptCodex,
            snapshot: snapshot,
            displayMode: .remaining
        )

        XCTAssertTrue(value.contains("displayMode.remaining".localized()))
        XCTAssertTrue(value.contains("content.5hours".localized()))
        XCTAssertTrue(value.contains("content.week".localized()))
        XCTAssertTrue(
            value.contains(UsagePercentFormatter.formatPercentText(75))
        )
        XCTAssertTrue(
            value.contains(UsagePercentFormatter.formatPercentText(20))
        )
    }

    func testDashboardMenuItemTitleIsNonemptyAndDescribesProviderState() {
        let snapshot = UsageSnapshot(
            provider: .claudeCode,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            primaryWindow: makeWindow(kind: .primary, usedPercent: 40),
            secondaryWindow: nil
        )

        let title = MenuBarAccessibilityPresentation.dashboardMenuItemTitle(
            provider: .claudeCode,
            snapshot: snapshot,
            displayMode: .used
        )

        XCTAssertFalse(title.isEmpty)
        XCTAssertTrue(title.contains(UsageProvider.claudeCode.displayName))
        XCTAssertTrue(
            title.contains(UsagePercentFormatter.formatPercentText(40))
        )
    }

    func testNoEnabledProvidersHasLocalizedStatus() {
        XCTAssertEqual(
            MenuBarAccessibilityPresentation.statusValue(
                states: [],
                displayMode: .used
            ),
            "accessibility.menuBar.noProviders".localized()
        )
    }

    func testMismatchedUsageSnapshotDoesNotAnnounceAnotherProviderUsage() {
        let account = ProviderAccount(
            provider: .chatgptCodex,
            label: "Personal"
        )
        let mismatchedSnapshot = UsageSnapshot(
            provider: .claudeCode,
            fetchedAt: Date(timeIntervalSince1970: 1_000),
            primaryWindow: makeWindow(kind: .primary, usedPercent: 91),
            secondaryWindow: nil
        )

        let value = MenuBarAccessibilityPresentation.statusValue(
            states: [
                MenuBarAccessibilityProviderState(
                    account: account,
                    usageSnapshot: mismatchedSnapshot,
                    sessionSnapshot: nil
                )
            ],
            displayMode: .used
        )

        XCTAssertTrue(value.contains("status.notFetched".localized()))
        XCTAssertFalse(
            value.contains(UsagePercentFormatter.formatPercentText(91))
        )
        XCTAssertFalse(value.contains("activity.title".localized()))
    }

    func testAccessibilityStringsExistInEveryBundledLocalization() throws {
        let localizationKeys = [
            "accessibility.menuBar.noProviders",
            "activity.manageCredential",
        ]
        let localizations = Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted()
        XCTAssertFalse(localizations.isEmpty, "No localizations bundled")

        for localization in localizations {
            let path = try XCTUnwrap(
                Bundle.main.path(
                    forResource: localization,
                    ofType: "lproj"
                ),
                "Missing localization bundle for \(localization)"
            )
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in localizationKeys {
                let value = bundle.localizedString(
                    forKey: key,
                    value: nil,
                    table: nil
                )
                XCTAssertNotEqual(value, key, "\(localization): \(key)")
                XCTAssertFalse(value.isEmpty, "\(localization): \(key)")
            }
        }
    }

    private func makeWindow(
        kind: UsageWindowKind,
        usedPercent: Double
    ) -> UsageWindow {
        UsageWindow(
            kind: kind,
            usedPercent: usedPercent,
            resetAt: Date(timeIntervalSince1970: 10_000),
            limitWindowSeconds: kind == .primary
                ? UsageLimitDuration.fiveHours
                : UsageLimitDuration.sevenDays
        )
    }
}
