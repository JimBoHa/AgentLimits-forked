import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class MonthStartDateResolverTests: XCTestCase {
    func testNonGregorianPreferencesStillProduceGregorianMonthStart() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            utc.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 12))
        )

        for identifier in [Calendar.Identifier.islamicCivil, .hebrew] {
            var preferredCalendar = Calendar(identifier: identifier)
            preferredCalendar.timeZone = try XCTUnwrap(
                TimeZone(identifier: "America/Los_Angeles")
            )
            XCTAssertEqual(
                MonthStartDateResolver.calculateStartOfMonthString(
                    now: now,
                    calendar: preferredCalendar
                ),
                "20260701"
            )
        }
    }

    func testMonthStartUsesPreferredCalendarTimeZone() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(
            utc.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 1,
                hour: 0,
                minute: 30
            ))
        )
        var losAngeles = Calendar(identifier: .islamicCivil)
        losAngeles.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var tokyo = Calendar(identifier: .hebrew)
        tokyo.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))

        XCTAssertEqual(
            MonthStartDateResolver.calculateStartOfMonthString(
                now: now,
                calendar: losAngeles
            ),
            "20260701"
        )
        XCTAssertEqual(
            MonthStartDateResolver.calculateStartOfMonthString(
                now: now,
                calendar: tokyo
            ),
            "20260801"
        )
    }
}
