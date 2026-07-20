import XCTest
@testable import AgentLimits

final class CopilotUsageResponseTests: XCTestCase {
    func testBillingWindowUsesUTCResetMonth() throws {
        let snapshot = try makeResponse(resetDate: "2026-08-01")
            .toSnapshot(fetchedAt: Date())
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
            let snapshot = try makeResponse(resetDate: testCase.resetDate)
                .toSnapshot(fetchedAt: Date())
            let window = try XCTUnwrap(snapshot.primaryWindow)
            XCTAssertEqual(
                window.limitWindowSeconds,
                TimeInterval(testCase.expectedDays * 24 * 60 * 60),
                testCase.resetDate
            )
        }
    }

    func testQuotaCountsPreserveNormalBonusAndOverageSemantics() throws {
        let cases: [(
            limit: Int,
            remaining: Int,
            overagesEnabled: Bool,
            expectedUsed: Int
        )] = [
            (300, 225, false, 75),
            // An entitlement increase can leave more remaining than the
            // nominal limit. Existing behavior reports zero consumed.
            (300, 400, false, 0),
            // Paid overages may consume beyond the included allowance.
            (300, -25, true, 325),
            (Int.max, Int.max, false, 0),
            (Int.max, 0, false, Int.max),
            (0, Int.max, false, 0),
            (0, -Int.max, true, Int.max)
        ]

        for testCase in cases {
            let response = makeResponse(
                limit: testCase.limit,
                remaining: testCase.remaining,
                overagesEnabled: testCase.overagesEnabled
            )
            let window = try XCTUnwrap(
                try response.toSnapshot(fetchedAt: Date()).primaryWindow
            )

            XCTAssertEqual(window.limitCount, testCase.limit)
            XCTAssertEqual(
                window.usedCount,
                testCase.expectedUsed,
                "limit=\(testCase.limit), remaining=\(testCase.remaining)"
            )
        }
    }

    func testInvalidAndOverflowingQuotaCountsAreRejected() {
        let invalidResponses = [
            makeResponse(limit: -1, remaining: 0, overagesEnabled: false),
            makeResponse(limit: Int.min, remaining: 0, overagesEnabled: false),
            makeResponse(limit: 300, remaining: -1, overagesEnabled: false),
            makeResponse(limit: 300, remaining: -1, overagesEnabled: nil),
            makeResponse(
                limit: Int.max,
                remaining: -1,
                overagesEnabled: true
            ),
            makeResponse(
                limit: 0,
                remaining: Int.min,
                overagesEnabled: true
            ),
            // Counts are validated even if the percentage is absent and no
            // usage window could otherwise be constructed.
            makeResponse(
                limit: Int.max,
                remaining: -1,
                remainingPercentage: nil,
                overagesEnabled: true
            )
        ]

        for response in invalidResponses {
            XCTAssertThrowsError(try response.toSnapshot(fetchedAt: Date())) {
                XCTAssertEqual(
                    $0 as? CopilotUsageResponseError,
                    .invalidQuota
                )
            }
        }
    }

    func testNonFiniteRemainingPercentageIsRejected() {
        for percentage in [Double.nan, .infinity, -.infinity] {
            let response = makeResponse(
                remainingPercentage: percentage
            )

            XCTAssertThrowsError(try response.toSnapshot(fetchedAt: Date())) {
                XCTAssertEqual(
                    $0 as? CopilotUsageResponseError,
                    .invalidQuota
                )
            }
        }
    }

    func testFiniteRemainingPercentageRetainsClampingSemantics() throws {
        let cases: [(remaining: Double, expectedUsed: Double)] = [
            (150, 0),
            (75, 25),
            (-25, 100)
        ]

        for testCase in cases {
            let snapshot = try makeResponse(
                remainingPercentage: testCase.remaining
            ).toSnapshot(fetchedAt: Date())
            let window = try XCTUnwrap(snapshot.primaryWindow)

            XCTAssertEqual(window.usedPercent, testCase.expectedUsed)
        }
    }

    func testOptionalCountFieldsRemainOptional() throws {
        let missingLimit = try makeResponse(limit: nil, remaining: 10)
            .toSnapshot(fetchedAt: Date()).primaryWindow
        XCTAssertNil(missingLimit?.limitCount)
        XCTAssertNil(missingLimit?.usedCount)

        let missingRemaining = try makeResponse(limit: 300, remaining: nil)
            .toSnapshot(fetchedAt: Date()).primaryWindow
        XCTAssertEqual(missingRemaining?.limitCount, 300)
        XCTAssertNil(missingRemaining?.usedCount)

        let missingPercentage = try makeResponse(remainingPercentage: nil)
            .toSnapshot(fetchedAt: Date())
        XCTAssertNil(missingPercentage.primaryWindow)
    }

    private func makeResponse(
        resetDate: String = "2026-08-01",
        limit: Int? = 300,
        remaining: Int? = 225,
        remainingPercentage: Double? = 75,
        overagesEnabled: Bool? = false
    ) -> CopilotUsageResponse {
        CopilotUsageResponse(
            licenseType: nil,
            plan: nil,
            quotas: CopilotUsageResponse.Quotas(
                limits: .init(premiumInteractions: limit),
                remaining: .init(
                    premiumInteractions: remaining,
                    premiumInteractionsPercentage: remainingPercentage
                ),
                resetDate: resetDate,
                overagesEnabled: overagesEnabled
            )
        )
    }

    private func utcDate(year: Int, month: Int, day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))
    }
}
