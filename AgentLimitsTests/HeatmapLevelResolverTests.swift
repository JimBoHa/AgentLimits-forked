import XCTest
@testable import AgentLimits

final class HeatmapLevelResolverTests: XCTestCase {
    func testDuplicateZeroRowsResolveWithoutTrapping() {
        let levels = HeatmapLevelResolver.calculateLevels(from: [
            DailyUsageEntry(date: "2025-07-19", totalTokens: 0),
            DailyUsageEntry(date: "2025-07-19", totalTokens: 0)
        ])

        XCTAssertEqual(levels, ["2025-07-19": .none])
    }

    func testDuplicateNonzeroRowsAreSummedBeforeLevelCalculation() {
        let levels = HeatmapLevelResolver.calculateLevels(from: [
            DailyUsageEntry(date: "2025-07-18", totalTokens: 1),
            DailyUsageEntry(date: "2025-07-19", totalTokens: 2),
            DailyUsageEntry(date: "2025-07-19", totalTokens: 3),
            DailyUsageEntry(date: "2025-07-20", totalTokens: 4)
        ])

        XCTAssertEqual(levels["2025-07-18"], .firstQuartile)
        XCTAssertEqual(levels["2025-07-19"], .fourthQuartile)
        XCTAssertEqual(levels["2025-07-20"], .secondQuartile)
        XCTAssertEqual(levels.count, 3)
    }
}
