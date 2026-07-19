import Foundation
import XCTest
@testable import AgentLimits

final class CCUsageFutureDateTests: XCTestCase {
    func testFutureAndMalformedEntriesDoNotInflateAggregates() throws {
        let calendar = Calendar.current
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 15,
            hour: 12
        )))
        let response = CCUsageClaudeResponse(
            daily: [
                .init(date: "2026-06-30", totalTokens: 40, totalCost: 4),
                .init(date: "2026-07-14", totalTokens: 20, totalCost: 2),
                .init(date: "2026-07-15", totalTokens: 10, totalCost: 1),
                .init(date: "2026-07-16", totalTokens: 900, totalCost: 90),
                .init(date: "not-a-date", totalTokens: 800, totalCost: 80)
            ],
            totals: .init(totalTokens: 1_770, totalCost: 177)
        )
        let data = try JSONEncoder().encode(response)

        let snapshot = try CCUsageFetcher().parseResponse(
            jsonData: data,
            provider: .claude,
            now: now
        )

        XCTAssertEqual(snapshot.today.totalTokens, 10)
        XCTAssertEqual(snapshot.today.costUSD, 1)
        XCTAssertEqual(snapshot.thisWeek.totalTokens, 30)
        XCTAssertEqual(snapshot.thisWeek.costUSD, 3)
        XCTAssertEqual(snapshot.thisMonth.totalTokens, 30)
        XCTAssertEqual(snapshot.thisMonth.costUSD, 3)
        XCTAssertEqual(snapshot.dailyUsage.map(\.date), [
            "2026-06-30",
            "2026-07-14",
            "2026-07-15"
        ])
        XCTAssertEqual(snapshot.fetchedAt, now)
    }
}
