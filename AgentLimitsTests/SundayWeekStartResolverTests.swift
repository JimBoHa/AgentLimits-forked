import XCTest
@testable import AgentLimits

final class SundayWeekStartResolverTests: XCTestCase {
    func testMidweekDatesResolveToPriorSundayAcrossLocales() throws {
        for locale in ["en_US", "de_DE", "en_GB"] {
            let calendar = makeCalendar(locale: locale, timeZone: utc)
            let date = try makeDate(2025, 7, 16, hour: 12, calendar: calendar)

            assertDate(
                SundayWeekStartResolver.resolve(for: date, calendar: calendar),
                equals: DateComponents(year: 2025, month: 7, day: 13, hour: 0),
                calendar: calendar
            )
        }
    }

    func testWeekBoundaryCrossesYearWithoutLocaleWeekRules() throws {
        let cases = [
            (DateComponents(year: 2021, month: 1, day: 1),
             DateComponents(year: 2020, month: 12, day: 27, hour: 0)),
            (DateComponents(year: 2024, month: 1, day: 1),
             DateComponents(year: 2023, month: 12, day: 31, hour: 0))
        ]

        for locale in ["de_DE", "en_GB"] {
            let calendar = makeCalendar(locale: locale, timeZone: utc)
            for (input, expected) in cases {
                let date = try XCTUnwrap(calendar.date(from: input))
                assertDate(
                    SundayWeekStartResolver.resolve(for: date, calendar: calendar),
                    equals: expected,
                    calendar: calendar
                )
            }
        }
    }

    func testSundayResolvesToItsOwnMidnight() throws {
        let calendar = makeCalendar(locale: "en_GB", timeZone: utc)
        let date = try makeDate(2025, 7, 13, hour: 14, calendar: calendar)

        assertDate(
            SundayWeekStartResolver.resolve(for: date, calendar: calendar),
            equals: DateComponents(year: 2025, month: 7, day: 13, hour: 0),
            calendar: calendar
        )
    }

    func testDaySubtractionPreservesMidnightAcrossDaylightSavingTransitions() throws {
        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let calendar = makeCalendar(locale: "en_US", timeZone: losAngeles)
        let cases = [
            ((2025, 3, 11), DateComponents(year: 2025, month: 3, day: 9, hour: 0)),
            ((2025, 11, 4), DateComponents(year: 2025, month: 11, day: 2, hour: 0))
        ]

        for (input, expected) in cases {
            let date = try makeDate(input.0, input.1, input.2, hour: 12, calendar: calendar)
            assertDate(
                SundayWeekStartResolver.resolve(for: date, calendar: calendar),
                equals: expected,
                calendar: calendar
            )
        }
    }

    private var utc: TimeZone {
        TimeZone(secondsFromGMT: 0)!
    }

    private func makeCalendar(locale: String, timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: locale)
        calendar.timeZone = timeZone
        return calendar
    }

    private func makeDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        hour: Int,
        calendar: Calendar
    ) throws -> Date {
        try XCTUnwrap(
            calendar.date(
                from: DateComponents(year: year, month: month, day: day, hour: hour)
            )
        )
    }

    private func assertDate(
        _ date: Date,
        equals expected: DateComponents,
        calendar: Calendar,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        XCTAssertEqual(actual.year, expected.year, file: file, line: line)
        XCTAssertEqual(actual.month, expected.month, file: file, line: line)
        XCTAssertEqual(actual.day, expected.day, file: file, line: line)
        XCTAssertEqual(actual.hour, expected.hour, file: file, line: line)
        XCTAssertEqual(actual.minute, 0, file: file, line: line)
        XCTAssertEqual(actual.second, 0, file: file, line: line)
    }
}
