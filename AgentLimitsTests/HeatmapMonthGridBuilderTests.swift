import XCTest
@testable import AgentLimits

final class HeatmapMonthGridBuilderTests: XCTestCase {
    func testJanuary2022GridInMondayFirstLocale() throws {
        let calendar = makeCalendar(locale: "en_GB")
        let date = try XCTUnwrap(
            calendar.date(from: DateComponents(year: 2022, month: 1, day: 15))
        )

        let grid = HeatmapMonthGridBuilder.build(for: date, calendar: calendar)

        XCTAssertEqual(grid.columnCount, 6)
        XCTAssertEqual(grid.cells.count, 7)
        XCTAssertTrue(grid.cells.allSatisfy { $0.count == 6 })
        XCTAssertEqual(grid.cells[6][0], "2022-01-01")
        XCTAssertEqual(grid.cells[0][1], "2022-01-02")
        XCTAssertEqual(grid.cells[1][5], "2022-01-31")
        XCTAssertEqual(grid.cells.flatMap(\.self).compactMap(\.self).count, 31)
    }

    func testGridIsIndependentOfLocaleWeekRules() throws {
        let sundayCalendar = makeCalendar(locale: "en_US")
        let mondayCalendar = makeCalendar(locale: "en_GB")
        let date = try XCTUnwrap(
            sundayCalendar.date(from: DateComponents(year: 2022, month: 1, day: 15))
        )

        let sundayGrid = HeatmapMonthGridBuilder.build(for: date, calendar: sundayCalendar)
        let mondayGrid = HeatmapMonthGridBuilder.build(for: date, calendar: mondayCalendar)

        XCTAssertEqual(sundayGrid.columnCount, mondayGrid.columnCount)
        XCTAssertEqual(sundayGrid.cells, mondayGrid.cells)
    }

    func testGridBoundsAndContentsAcrossCalendarBoundaries() throws {
        for locale in ["en_GB", "de_DE"] {
            let calendar = makeCalendar(locale: locale)
            for year in 2000...2100 {
                for month in 1...12 {
                    let date = try XCTUnwrap(
                        calendar.date(from: DateComponents(year: year, month: month, day: 15))
                    )
                    let grid = HeatmapMonthGridBuilder.build(for: date, calendar: calendar)
                    let populatedCells = grid.cells.flatMap(\.self).compactMap(\.self)
                    let expectedDayCount = try XCTUnwrap(
                        calendar.range(of: .day, in: .month, for: date)?.count
                    )

                    XCTAssertEqual(grid.cells.count, 7)
                    XCTAssertTrue(grid.cells.allSatisfy { $0.count == grid.columnCount })
                    XCTAssertEqual(populatedCells.count, expectedDayCount)
                    XCTAssertEqual(Set(populatedCells).count, expectedDayCount)
                }
            }
        }
    }

    private func makeCalendar(locale: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: locale)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
