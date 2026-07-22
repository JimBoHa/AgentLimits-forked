// MARK: - HeatmapLevelResolver.swift
// Quartile-based level calculation for heatmap visualization.

import Foundation

/// Resolves heatmap levels from daily usage data using quartile calculation.
enum HeatmapLevelResolver {
    /// Calculates one heatmap level per date. Duplicate dates are summed so a
    /// corrupt persisted snapshot cannot trap during widget rendering.
    static func calculateLevels(
        from dailyUsage: [DailyUsageEntry]
    ) -> [String: HeatmapLevel] {
        let tokensByDate = coalescedTokenTotals(dailyUsage)
        let nonZeroTokens = tokensByDate.values
            .filter { $0 > 0 }
            .sorted()

        guard !nonZeroTokens.isEmpty else {
            return tokensByDate.mapValues { _ in .none }
        }

        let q1 = percentile(nonZeroTokens, at: 0.25)
        let q2 = percentile(nonZeroTokens, at: 0.50)
        let q3 = percentile(nonZeroTokens, at: 0.75)

        return tokensByDate.mapValues {
            levelForTokens($0, q1: q1, q2: q2, q3: q3)
        }
    }

    private static func coalescedTokenTotals(
        _ dailyUsage: [DailyUsageEntry]
    ) -> [String: Int] {
        var tokensByDate: [String: Int] = [:]
        for entry in dailyUsage {
            let nonnegativeTokens = max(0, entry.totalTokens)
            let currentTokens = tokensByDate[entry.date, default: 0]
            let (totalTokens, overflow) = currentTokens
                .addingReportingOverflow(nonnegativeTokens)
            tokensByDate[entry.date] = overflow ? Int.max : totalTokens
        }
        return tokensByDate
    }

    private static func percentile(_ sorted: [Int], at p: Double) -> Int {
        guard !sorted.isEmpty else { return 0 }
        let index = Int(Double(sorted.count - 1) * p)
        return sorted[index]
    }

    private static func levelForTokens(
        _ tokens: Int,
        q1: Int,
        q2: Int,
        q3: Int
    ) -> HeatmapLevel {
        if tokens == 0 { return .none }
        if tokens <= q1 { return .firstQuartile }
        if tokens <= q2 { return .secondQuartile }
        if tokens <= q3 { return .thirdQuartile }
        return .fourthQuartile
    }
}
