import XCTest
@testable import AgentLimits

final class UsageModelsTests: XCTestCase {
    func testDisplayModeClampsUsagePercentages() {
        XCTAssertEqual(UsageDisplayModeRaw.used.makeDisplayPercent(from: -10), 0)
        XCTAssertEqual(UsageDisplayModeRaw.used.makeDisplayPercent(from: 140), 100)
        XCTAssertEqual(UsageDisplayModeRaw.remaining.makeDisplayPercent(from: 25), 75)
    }

    func testMonthlyWindowDetectionRequiresLongPrimaryWindow() {
        let monthlyWindow = UsageWindow(
            kind: .primary,
            usedPercent: 10,
            resetAt: Date().addingTimeInterval(86_400),
            limitWindowSeconds: UsageLimitDuration.thirtyDays
        )
        let snapshot = UsageSnapshot(
            provider: .chatgptCodex,
            fetchedAt: Date(),
            primaryWindow: monthlyWindow,
            secondaryWindow: nil
        )

        XCTAssertTrue(snapshot.isSingleMonthlyWindow)

        let shortWindowSnapshot = UsageSnapshot(
            provider: .chatgptCodex,
            fetchedAt: Date(),
            primaryWindow: UsageWindow(
                kind: .primary,
                usedPercent: 10,
                resetAt: Date().addingTimeInterval(86_400),
                limitWindowSeconds: UsageLimitDuration.fiveHours
            ),
            secondaryWindow: nil
        )
        XCTAssertFalse(shortWindowSnapshot.isSingleMonthlyWindow)

        let twoWindowSnapshot = UsageSnapshot(
            provider: .chatgptCodex,
            fetchedAt: Date(),
            primaryWindow: monthlyWindow,
            secondaryWindow: UsageWindow(
                kind: .secondary,
                usedPercent: 20,
                resetAt: Date().addingTimeInterval(86_400),
                limitWindowSeconds: UsageLimitDuration.sevenDays
            )
        )
        XCTAssertFalse(twoWindowSnapshot.isSingleMonthlyWindow)
    }
}
