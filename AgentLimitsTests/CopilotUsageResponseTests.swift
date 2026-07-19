import XCTest
@testable import AgentLimits

final class CopilotUsageResponseTests: XCTestCase {
    func testBillingWindowUsesUTCResetMonth() throws {
        XCTAssertEqual(TimeZone.current.identifier, "America/Los_Angeles")
        let snapshot = makeResponse(resetDate: "2026-08-01").toSnapshot(fetchedAt: Date())
        let window = try XCTUnwrap(snapshot.primaryWindow)

        XCTAssertEqual(window.resetAt, utcDate(year: 2026, month: 8, day: 1))
        XCTAssertEqual(window.limitWindowSeconds, 31 * 24 * 60 * 60)
    }

    func testBillingWindowHandlesLeapAndYearBoundaries() throws {
        let cases: [(resetDate: String, expectedDays: Int)] = [
            ("2024-03-01", 29),
            ("2025-03-01", 28),
            ("2026-01-01", 31)
        ]

        for testCase in cases {
            let snapshot = makeResponse(resetDate: testCase.resetDate)
                .toSnapshot(fetchedAt: Date())
            let window = try XCTUnwrap(snapshot.primaryWindow)
            XCTAssertEqual(
                window.limitWindowSeconds,
                TimeInterval(testCase.expectedDays * 24 * 60 * 60),
                testCase.resetDate
            )
        }
    }

    private func makeResponse(resetDate: String) -> CopilotUsageResponse {
        CopilotUsageResponse(
            licenseType: nil,
            plan: nil,
            quotas: CopilotUsageResponse.Quotas(
                limits: .init(premiumInteractions: 300),
                remaining: .init(
                    premiumInteractions: 225,
                    premiumInteractionsPercentage: 75
                ),
                resetDate: resetDate,
                overagesEnabled: false
            )
        )
    }

    private func utcDate(year: Int, month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
