import Foundation
import XCTest
@testable import AgentLimits

final class ThresholdNotificationStoreTests: XCTestCase {
    private static let storageKey = "threshold_notification_settings"

    func testDuplicateProviderPayloadUsesDefaultsForAmbiguousProvider() throws {
        try withTemporaryStore { store, defaults in
            let firstDuplicate = customizedSettings(
                for: .chatgptCodex,
                warningPercent: 41
            )
            let secondDuplicate = customizedSettings(
                for: .chatgptCodex,
                warningPercent: 42
            )
            let unambiguous = customizedSettings(
                for: .claudeCode,
                warningPercent: 43
            )
            defaults.set(
                try encoded([firstDuplicate, unambiguous, secondDuplicate]),
                forKey: Self.storageKey
            )

            let recovered = store.loadSettings()

            XCTAssertEqual(recovered.count, UsageProvider.allCases.count)
            XCTAssertEqual(
                recovered[.chatgptCodex],
                ProviderThresholdSettings.defaultSettings(for: .chatgptCodex)
            )
            XCTAssertEqual(recovered[.claudeCode], unambiguous)
            XCTAssertEqual(
                recovered[.githubCopilot],
                ProviderThresholdSettings.defaultSettings(for: .githubCopilot)
            )

            defaults.set(
                try encoded([secondDuplicate, unambiguous, firstDuplicate]),
                forKey: Self.storageKey
            )
            XCTAssertEqual(store.loadSettings(), recovered)
        }
    }

    func testMissingProvidersReceiveDefaultsWithoutReplacingSavedProvider() throws {
        try withTemporaryStore { store, defaults in
            let saved = customizedSettings(
                for: .githubCopilot,
                warningPercent: 44
            )
            defaults.set(try encoded([saved]), forKey: Self.storageKey)

            let recovered = store.loadSettings()

            XCTAssertEqual(recovered.count, UsageProvider.allCases.count)
            XCTAssertEqual(recovered[.githubCopilot], saved)
            XCTAssertEqual(
                recovered[.chatgptCodex],
                ProviderThresholdSettings.defaultSettings(for: .chatgptCodex)
            )
            XCTAssertEqual(
                recovered[.claudeCode],
                ProviderThresholdSettings.defaultSettings(for: .claudeCode)
            )
        }
    }

    func testCorruptPayloadReturnsDefaultsForEveryProvider() throws {
        try withTemporaryStore { store, defaults in
            defaults.set(Data("not-json".utf8), forKey: Self.storageKey)

            XCTAssertEqual(store.loadSettings(), defaultSettings())
        }
    }

    func testNormalSettingsRoundTrip() throws {
        try withTemporaryStore { store, _ in
            var expected = defaultSettings()
            expected[.chatgptCodex] = customizedSettings(
                for: .chatgptCodex,
                warningPercent: 45
            )
            expected[.claudeCode] = customizedSettings(
                for: .claudeCode,
                warningPercent: 46
            )
            expected[.githubCopilot] = customizedSettings(
                for: .githubCopilot,
                warningPercent: 47
            )

            store.saveSettings(expected)

            XCTAssertEqual(store.loadSettings(), expected)
        }
    }

    private func withTemporaryStore(
        _ body: (ThresholdNotificationStore, UserDefaults) throws -> Void
    ) throws {
        let suiteName = "ThresholdNotificationStoreTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(ThresholdNotificationStore(userDefaults: defaults), defaults)
    }

    private func encoded(_ settings: [ProviderThresholdSettings]) throws -> Data {
        let encoder = JSONEncoder()
        DateCodec.configureEncoder(encoder)
        return try encoder.encode(settings)
    }

    private func defaultSettings() -> [UsageProvider: ProviderThresholdSettings] {
        UsageProvider.allCases.reduce(into: [:]) { result, provider in
            result[provider] = ProviderThresholdSettings.defaultSettings(for: provider)
        }
    }

    private func customizedSettings(
        for provider: UsageProvider,
        warningPercent: Int
    ) -> ProviderThresholdSettings {
        var settings = ProviderThresholdSettings.defaultSettings(for: provider)
        settings.primaryWindow.warning.thresholdPercent = warningPercent
        settings.primaryWindow.warning.lastNotifiedResetAt = Date(
            timeIntervalSince1970: TimeInterval(1_700_000_000 + warningPercent)
        )
        return settings
    }
}
