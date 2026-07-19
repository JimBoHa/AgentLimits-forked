import Foundation
import XCTest
@testable import AgentLimits

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

        let snapshot = CopilotBillingFetcher().buildSnapshot(
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

        let snapshot = CopilotBillingFetcher().buildSnapshot(
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

        let snapshot = CopilotBillingFetcher().buildSnapshot(
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

        let snapshot = CopilotBillingFetcher().buildSnapshot(
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

        let snapshot = CopilotBillingFetcher().buildSnapshot(
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

        let snapshot = CopilotBillingFetcher().buildSnapshot(
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

        let snapshot = CopilotBillingFetcher().buildSnapshot(
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

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
