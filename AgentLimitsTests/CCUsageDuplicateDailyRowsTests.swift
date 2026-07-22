import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class CCUsageDuplicateDailyRowsTests: XCTestCase {
    func testClaudeDuplicateDatesAreSummedBeforePeriodCalculation() throws {
        let response = CCUsageClaudeResponse(
            daily: [
                .init(date: "2025-07-19", totalTokens: 10, totalCost: 1),
                .init(date: "2025-07-18", totalTokens: 5, totalCost: 4),
                .init(date: "2025-07-19", totalTokens: 20, totalCost: 2)
            ],
            totals: .init(totalTokens: 35, totalCost: 7)
        )

        let snapshot = try parse(response, provider: .claude)

        XCTAssertEqual(snapshot.today, TokenUsagePeriod(costUSD: 3, totalTokens: 30))
        XCTAssertEqual(snapshot.thisWeek, TokenUsagePeriod(costUSD: 7, totalTokens: 35))
        XCTAssertEqual(snapshot.thisMonth, TokenUsagePeriod(costUSD: 7, totalTokens: 35))
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2025-07-18", totalTokens: 5),
            DailyUsageEntry(date: "2025-07-19", totalTokens: 30)
        ])
    }

    func testCodexDuplicateDatesAreSummedBeforePeriodCalculation() throws {
        let response = CCUsageCodexResponse(
            daily: [
                .init(date: "2025-07-19", totalTokens: 8, costUSD: 8),
                .init(date: "2025-07-19", totalTokens: 12, costUSD: 12),
                .init(date: "2025-07-17", totalTokens: 3, costUSD: 3)
            ],
            totals: .init(totalTokens: 23, costUSD: 23)
        )

        let snapshot = try parse(response, provider: .codex)

        XCTAssertEqual(snapshot.today, TokenUsagePeriod(costUSD: 20, totalTokens: 20))
        XCTAssertEqual(snapshot.thisWeek, TokenUsagePeriod(costUSD: 23, totalTokens: 23))
        XCTAssertEqual(snapshot.thisMonth, TokenUsagePeriod(costUSD: 23, totalTokens: 23))
        XCTAssertEqual(snapshot.dailyUsage, [
            DailyUsageEntry(date: "2025-07-17", totalTokens: 3),
            DailyUsageEntry(date: "2025-07-19", totalTokens: 20)
        ])
    }

    func testDuplicateDateOverflowIsRejected() throws {
        let response = CCUsageClaudeResponse(
            daily: [
                .init(date: "2025-06-01", totalTokens: Int.max, totalCost: 1),
                .init(date: "2025-06-01", totalTokens: 1, totalCost: 1)
            ],
            totals: .init(totalTokens: Int.max, totalCost: 2)
        )

        XCTAssertThrowsError(try parse(response, provider: .claude)) { error in
            guard case CCUsageFetcherError.parseError(let message) = error else {
                return XCTFail("Expected parseError, got \(error)")
            }
            XCTAssertTrue(message.contains("numeric bounds"), message)
        }
    }

    private func parse<T: Encodable>(
        _ response: T,
        provider: TokenUsageProvider
    ) throws -> TokenUsageSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2025,
            month: 7,
            day: 19,
            hour: 12
        )))
        return try CCUsageFetcher().parseResponse(
            jsonData: JSONEncoder().encode(response),
            provider: provider,
            now: now,
            calendar: calendar
        )
    }
}
