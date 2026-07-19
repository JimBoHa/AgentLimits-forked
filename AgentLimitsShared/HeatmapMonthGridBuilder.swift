// MARK: - HeatmapMonthGridBuilder.swift
// Builds a stable Sunday-first month grid for token-usage heatmaps.

import Foundation

struct HeatmapMonthGrid {
    let cells: [[String?]]
    let columnCount: Int
}

enum HeatmapMonthGridBuilder {
    private static let rowCount = 7

    static func build(
        for date: Date,
        calendar sourceCalendar: Calendar = .current
    ) -> HeatmapMonthGrid {
        // Usage entry keys are Gregorian dates. Keep the user's locale and time
        // zone, but do not inherit locale-specific week numbering rules.
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = sourceCalendar.locale
        calendar.timeZone = sourceCalendar.timeZone

        let components = calendar.dateComponents([.year, .month], from: date)
        guard let startOfMonth = calendar.date(from: components),
              let dayRange = calendar.range(of: .day, in: .month, for: startOfMonth) else {
            return HeatmapMonthGrid(
                cells: Array(repeating: [], count: rowCount),
                columnCount: 0
            )
        }

        let firstRow = calendar.component(.weekday, from: startOfMonth) - 1
        let columnCount = (firstRow + dayRange.count + rowCount - 1) / rowCount
        var cells = Array(
            repeating: Array<String?>(repeating: nil, count: columnCount),
            count: rowCount
        )

        let year = calendar.component(.year, from: startOfMonth)
        let month = calendar.component(.month, from: startOfMonth)

        for day in dayRange {
            let offset = firstRow + day - 1
            let row = offset % rowCount
            let column = offset / rowCount
            cells[row][column] = String(format: "%04d-%02d-%02d", year, month, day)
        }

        return HeatmapMonthGrid(cells: cells, columnCount: columnCount)
    }
}
