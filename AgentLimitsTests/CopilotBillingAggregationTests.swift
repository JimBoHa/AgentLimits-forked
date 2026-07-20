import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class CopilotBillingAggregationTests: XCTestCase {
    func testPeriodsAcceptBothTimestampFormatsAndRejectInvalidRows() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-15T12:00:00Z"))
        let response = CopilotBillingResponse(usage: [
            entry(cost: 1, requests: 1, at: "2026-07-15T10:00:00.123Z"),
            entry(cost: 2, requests: 2, at: "2026-07-14T10:00:00Z"),
            entry(cost: 4, requests: 4, at: "2026-06-30T10:00:00Z"),
            entry(cost: 8, requests: 8, at: "2026-07-16T10:00:00Z"),
            entry(cost: 16, requests: 16, at: "not-a-timestamp"),
            entry(
                cost: 32,
                requests: 32,
                at: "2026-07-15T09:00:00Z",
                sku: "copilot_other"
            )
        ])

        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: response,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.today, TokenUsagePeriod(costUSD: 1, totalTokens: 1))
        XCTAssertEqual(snapshot.thisWeek, TokenUsagePeriod(costUSD: 3, totalTokens: 3))
        XCTAssertEqual(snapshot.thisMonth, TokenUsagePeriod(costUSD: 3, totalTokens: 3))
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2026-07-14", totalTokens: 2),
            DailyUsageEntry(date: "2026-07-15", totalTokens: 1)
        ])
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testWeekCanIncludePriorMonthWhileMonthAndHeatmapDoNot() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-01T12:00:00Z"))
        let response = CopilotBillingResponse(usage: [
            entry(cost: 2, requests: 2, at: "2026-06-28T10:00:00Z"),
            entry(cost: 3, requests: 3, at: "2026-06-30T10:00:00Z"),
            entry(cost: 5, requests: 5, at: "2026-07-01T10:00:00Z")
        ])

        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: response,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.today.totalTokens, 5)
        XCTAssertEqual(snapshot.thisWeek.totalTokens, 10)
        XCTAssertEqual(snapshot.thisMonth.totalTokens, 5)
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2026-07-01", totalTokens: 5)
        ])
    }

    func testDailyGroupingUsesTheRequestedCalendarTimeZone() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-15T12:00:00Z"))
        let response = CopilotBillingResponse(usage: [
            entry(cost: 2, requests: 2, at: "2026-07-15T06:00:00Z"),
            entry(cost: 3, requests: 3, at: "2026-07-15T08:00:00Z")
        ])

        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: response,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.today.totalTokens, 3)
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2026-07-14", totalTokens: 2),
            DailyUsageEntry(date: "2026-07-15", totalTokens: 3)
        ])
    }

    func testMonthlyBillingUsesGitHubUTCResetBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-01T01:00:00Z"))
        let response = CopilotBillingResponse(usage: [
            entry(cost: 2, requests: 2, at: "2026-06-30T23:00:00Z"),
            entry(cost: 3, requests: 3, at: "2026-07-01T00:30:00Z")
        ])

        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: response,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.today.totalTokens, 5)
        XCTAssertEqual(snapshot.thisMonth.totalTokens, 3)
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2026-06-30", totalTokens: 5)
        ])
    }

    func testNonGregorianUserCalendarStillProducesGregorianISODateKeys() throws {
        var calendar = Calendar(identifier: .buddhist)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-15T12:00:00Z"))
        let response = CopilotBillingResponse(usage: [
            entry(cost: 2, requests: 2, at: "2026-07-14T10:00:00Z"),
            entry(cost: 3, requests: 3, at: "2026-07-15T10:00:00Z")
        ])

        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: response,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.today.totalTokens, 3)
        XCTAssertEqual(snapshot.thisMonth.totalTokens, 5)
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2026-07-14", totalTokens: 2),
            DailyUsageEntry(date: "2026-07-15", totalTokens: 3)
        ])
    }

    func testImpossibleGregorianDateIsRejectedInsteadOfNormalized() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-03-02T12:00:00Z"))
        let response = CopilotBillingResponse(usage: [
            entry(cost: 99, requests: 99, at: "2026-02-30T10:00:00Z"),
            entry(cost: 2, requests: 2, at: "2026-03-02T10:00:00Z")
        ])

        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: response,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.today, TokenUsagePeriod(costUSD: 2, totalTokens: 2))
        XCTAssertEqual(snapshot.thisMonth, TokenUsagePeriod(costUSD: 2, totalTokens: 2))
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2026-03-02", totalTokens: 2)
        ])
    }

    func testInvalidTimesAndTrailingBytesAreRejected() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-03-02T12:00:00Z"))
        let response = CopilotBillingResponse(usage: [
            entry(cost: 10, requests: 10, at: "2026-03-01T25:00:00Z"),
            entry(cost: 20, requests: 20, at: "2026-03-01T23:60:00Z"),
            entry(cost: 40, requests: 40, at: "2026-03-02T10:00:00Zjunk"),
            entry(cost: 2, requests: 2, at: "2026-03-02T10:00:00.123Z")
        ])

        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: response,
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(snapshot.today, TokenUsagePeriod(costUSD: 2, totalTokens: 2))
        XCTAssertEqual(snapshot.thisMonth, TokenUsagePeriod(costUSD: 2, totalTokens: 2))
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2026-03-02", totalTokens: 2)
        ])
    }

    func testFractionalQuantitiesAggregateBeforeTruncation() throws {
        let calendar = utcCalendar()
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-15T12:00:00Z"))
        let response = CopilotBillingResponse(usage: [
            entry(cost: 0.25, requests: 0.6, at: "2026-07-15T10:00:00Z"),
            entry(cost: 0.5, requests: 0.6, at: "2026-07-15T11:00:00Z")
        ])

        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: response,
            now: now,
            calendar: calendar
        )

        let expected = TokenUsagePeriod(costUSD: 0.75, totalTokens: 1)
        XCTAssertEqual(snapshot.today, expected)
        XCTAssertEqual(snapshot.thisWeek, expected)
        XCTAssertEqual(snapshot.thisMonth, expected)
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2026-07-15", totalTokens: 1)
        ])
    }

    func testInvalidPerRowNumericValuesAreRejected() throws {
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-15T12:00:00Z"))
        let timestamp = "2026-07-15T10:00:00Z"
        let cases: [(
            label: String,
            entry: CopilotBillingEntry,
            expected: CopilotBillingValidationError
        )] = [
            ("NaN cost", entry(cost: .nan, requests: 1, at: timestamp), .invalidCost),
            ("infinite cost", entry(cost: .infinity, requests: 1, at: timestamp), .invalidCost),
            ("negative infinite cost", entry(cost: -.infinity, requests: 1, at: timestamp), .invalidCost),
            ("negative cost", entry(cost: -0.01, requests: 1, at: timestamp), .invalidCost),
            ("NaN quantity", entry(cost: 1, requests: .nan, at: timestamp), .invalidQuantity),
            ("infinite quantity", entry(cost: 1, requests: .infinity, at: timestamp), .invalidQuantity),
            ("negative infinite quantity", entry(cost: 1, requests: -.infinity, at: timestamp), .invalidQuantity),
            ("negative quantity", entry(cost: 1, requests: -0.01, at: timestamp), .invalidQuantity),
            ("Int boundary", entry(cost: 1, requests: Double(Int.max), at: timestamp), .invalidQuantity),
            ("1e308 quantity", entry(cost: 1, requests: 1e308, at: timestamp), .invalidQuantity)
        ]

        for testCase in cases {
            XCTAssertThrowsError(
                try CopilotBillingFetcher().buildSnapshot(
                    from: .init(usage: [testCase.entry]),
                    now: now,
                    calendar: utcCalendar()
                ),
                testCase.label
            ) {
                XCTAssertEqual(
                    $0 as? CopilotBillingValidationError,
                    testCase.expected,
                    testCase.label
                )
            }
        }
    }

    func testLargeFiniteCostRemainsValid() throws {
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-15T12:00:00Z"))
        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: .init(usage: [
                entry(
                    cost: 1e308,
                    requests: 1,
                    at: "2026-07-15T10:00:00Z"
                )
            ]),
            now: now,
            calendar: utcCalendar()
        )

        XCTAssertEqual(snapshot.today.costUSD, 1e308)
        XCTAssertEqual(snapshot.today.totalTokens, 1)
    }

    func testCheckedAggregatesRejectCostAndQuantityOverflow() throws {
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-15T12:00:00Z"))
        let timestamp = "2026-07-15T10:00:00Z"
        let largestValidQuantity = Double(Int.max).nextDown
        XCTAssertNotNil(Int(exactly: largestValidQuantity))

        let responses = [
            CopilotBillingResponse(usage: [
                entry(cost: 1e308, requests: 1, at: timestamp),
                entry(cost: 1e308, requests: 1, at: timestamp)
            ]),
            CopilotBillingResponse(usage: [
                entry(cost: 1, requests: largestValidQuantity, at: timestamp),
                entry(cost: 1, requests: largestValidQuantity, at: timestamp)
            ])
        ]

        for response in responses {
            XCTAssertThrowsError(
                try CopilotBillingFetcher().buildSnapshot(
                    from: response,
                    now: now,
                    calendar: utcCalendar()
                )
            ) {
                XCTAssertEqual(
                    $0 as? CopilotBillingValidationError,
                    .aggregateOverflow
                )
            }
        }
    }

    func testBuildSnapshotRowCapIsInclusive() throws {
        let now = try XCTUnwrap(Self.iso8601.date(from: "2026-07-15T12:00:00Z"))
        let repeatedEntry = entry(
            cost: 1,
            requests: 1,
            at: "2026-07-15T10:00:00Z"
        )
        var rows = Array(
            repeating: repeatedEntry,
            count: CopilotBillingResponse.maximumUsageRows
        )

        let snapshot = try CopilotBillingFetcher().buildSnapshot(
            from: .init(usage: rows),
            now: now,
            calendar: utcCalendar()
        )
        XCTAssertEqual(
            snapshot.today.totalTokens,
            CopilotBillingResponse.maximumUsageRows
        )

        rows.append(repeatedEntry)
        XCTAssertThrowsError(
            try CopilotBillingFetcher().buildSnapshot(
                from: .init(usage: rows),
                now: now,
                calendar: utcCalendar()
            )
        ) {
            XCTAssertEqual(
                $0 as? CopilotBillingValidationError,
                .tooManyRows
            )
        }
    }

    func testDecoderRowCapIsInclusive() throws {
        let decoder = JSONDecoder()
        let exactCap = try decoder.decode(
            CopilotBillingResponse.self,
            from: responseData(
                rowCount: CopilotBillingResponse.maximumUsageRows
            )
        )
        XCTAssertEqual(
            exactCap.usage.count,
            CopilotBillingResponse.maximumUsageRows
        )

        XCTAssertThrowsError(
            try decoder.decode(
                CopilotBillingResponse.self,
                from: responseData(
                    rowCount: CopilotBillingResponse.maximumUsageRows + 1
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? CopilotBillingValidationError,
                .tooManyRows
            )
        }
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func entry(
        cost: Double,
        requests: Double,
        at timestamp: String,
        sku: String = "copilot_premium_request"
    ) -> CopilotBillingEntry {
        CopilotBillingEntry(
            grossAmount: cost,
            quantity: requests,
            usageAt: timestamp,
            sku: sku
        )
    }

    private func responseData(rowCount: Int) -> Data {
        let row = """
        {"grossAmount":0,"quantity":0,"usageAt":"2026-07-15T10:00:00Z","sku":"copilot_other"}
        """
        let rows = Array(repeating: row, count: rowCount).joined(separator: ",")
        return Data("{\"usage\":[\(rows)]}".utf8)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
