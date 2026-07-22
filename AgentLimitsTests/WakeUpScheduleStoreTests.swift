import Foundation
import XCTest
@testable import AgentLimits

final class WakeUpScheduleStoreTests: XCTestCase {
    private let storageKey = "wake_up_schedules"

    func testDuplicateProviderRecoversToDisabledDefaultRegardlessOfOrder() throws {
        try withTemporaryDefaults { defaults in
            let first = WakeUpSchedule(
                provider: .claudeCode,
                enabledHours: [8],
                isEnabled: true,
                additionalArgs: "--model first"
            )
            let duplicate = WakeUpSchedule(
                provider: .claudeCode,
                enabledHours: [18],
                isEnabled: true,
                additionalArgs: "--model duplicate"
            )
            let unique = WakeUpSchedule(
                provider: .chatgptCodex,
                enabledHours: [9],
                isEnabled: true
            )
            let store = WakeUpScheduleStore(userDefaults: defaults)

            let forwardData = try JSONEncoder().encode([first, unique, duplicate])
            defaults.set(forwardData, forKey: storageKey)
            let forward = store.loadSchedules()

            XCTAssertEqual(forward.count, UsageProvider.allCases.count)
            XCTAssertEqual(
                forward[.claudeCode],
                .defaultSchedule(for: .claudeCode)
            )
            XCTAssertEqual(forward[.chatgptCodex], unique)
            XCTAssertEqual(
                forward[.githubCopilot],
                .defaultSchedule(for: .githubCopilot)
            )
            XCTAssertEqual(defaults.data(forKey: storageKey), forwardData)

            let reverseData = try JSONEncoder().encode([duplicate, unique, first])
            defaults.set(reverseData, forKey: storageKey)
            let reverse = store.loadSchedules()

            XCTAssertEqual(reverse, forward)
            XCTAssertEqual(defaults.data(forKey: storageKey), reverseData)
        }
    }

    func testMissingProvidersAreCompletedWithDisabledDefaults() throws {
        try withTemporaryDefaults { defaults in
            let saved = WakeUpSchedule(
                provider: .chatgptCodex,
                enabledHours: [7, 12],
                isEnabled: true,
                additionalArgs: "--profile work"
            )
            defaults.set(
                try JSONEncoder().encode([saved]),
                forKey: storageKey
            )

            let loaded = WakeUpScheduleStore(userDefaults: defaults)
                .loadSchedules()

            XCTAssertEqual(loaded.count, UsageProvider.allCases.count)
            XCTAssertEqual(loaded[.chatgptCodex], saved)
            XCTAssertEqual(
                loaded[.claudeCode],
                .defaultSchedule(for: .claudeCode)
            )
            XCTAssertEqual(
                loaded[.githubCopilot],
                .defaultSchedule(for: .githubCopilot)
            )
        }
    }

    func testNormalSchedulesRoundTrip() throws {
        try withTemporaryDefaults { defaults in
            let expected: [UsageProvider: WakeUpSchedule] = [
                .chatgptCodex: WakeUpSchedule(
                    provider: .chatgptCodex,
                    enabledHours: [6, 15],
                    isEnabled: true,
                    additionalArgs: "--profile personal"
                ),
                .claudeCode: WakeUpSchedule(
                    provider: .claudeCode,
                    enabledHours: [10],
                    isEnabled: false,
                    additionalArgs: "--model sonnet"
                ),
                .githubCopilot: .defaultSchedule(for: .githubCopilot),
            ]
            let store = WakeUpScheduleStore(userDefaults: defaults)

            store.saveSchedules(expected)

            XCTAssertEqual(store.loadSchedules(), expected)
        }
    }

    private func withTemporaryDefaults(
        _ body: (UserDefaults) throws -> Void
    ) throws {
        let suiteName = "WakeUpScheduleStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}
