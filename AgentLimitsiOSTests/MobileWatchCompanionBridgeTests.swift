import Foundation
import WatchConnectivity
import XCTest
@testable import AgentLimitsiOS

final class MobileWatchCompanionBridgeTests: XCTestCase {
    @MainActor
    func testPublishesSanitizedStateAndRefreshesOnlyRequestedAccount()
        async throws {
        let suiteName = "MobileWatchBridgeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountStore = MobileAccountStore(defaults: defaults)
        let account = try XCTUnwrap(
            accountStore.accounts(for: .copilot).first
        )
        let credential = "watch-must-never-receive-this-token"
        let credentials = WatchBridgeCredentialStore()
        credentials.values[account.id] = credential
        let fetcher = WatchBridgeRecordingFetcher(
            counts: .init(working: 2, waiting: 3)
        )
        let activityController = MobileSessionActivityController(
            accountResolver: accountStore,
            credentialStore: credentials,
            fetcher: fetcher,
            now: { Date(timeIntervalSince1970: 12_000) }
        )
        let session = WatchBridgeSession()
        let bridge = MobileWatchCompanionBridge(
            accountStore: accountStore,
            activityController: activityController,
            session: session,
            now: { Date(timeIntervalSince1970: 12_001) }
        )

        _ = try accountStore.updateAccount(
            id: account.id,
            label: "Work Copilot",
            isEnabled: true
        )
        let response = await bridge.response(toRefreshRequest: [
            WatchCompanionTransportKeys.refreshAccountID:
                account.id.uuidString.lowercased()
        ])

        XCTAssertEqual(session.activateCount, 1)
        XCTAssertEqual(response.count, 1)
        let responseData = try XCTUnwrap(
            response[WatchCompanionTransportKeys.envelopeData] as? Data
        )
        let envelope = try WatchCompanionEnvelope.decodeValidated(responseData)
        let status = try XCTUnwrap(
            envelope.accounts.first { $0.id == account.id }
        )
        XCTAssertEqual(status.label, "Work Copilot")
        XCTAssertEqual(status.provider, .copilot)
        XCTAssertEqual(status.availability, .available)
        XCTAssertEqual(status.working, 2)
        XCTAssertEqual(status.waiting, 3)
        XCTAssertEqual(status.open, 5)
        let requestedCredentials = await fetcher.credentials()
        XCTAssertEqual(requestedCredentials, [credential])
        XCTAssertNil(responseData.range(of: Data(credential.utf8)))

        let context = try XCTUnwrap(session.contexts.last)
        XCTAssertEqual(context.count, 1)
        let contextData = try XCTUnwrap(
            context[WatchCompanionTransportKeys.envelopeData] as? Data
        )
        _ = try WatchCompanionEnvelope.decodeValidated(contextData)
        XCTAssertNil(contextData.range(of: Data(credential.utf8)))
        withExtendedLifetime(bridge) {}
    }

    @MainActor
    func testRejectsNonCanonicalUnknownDisabledAndUnsupportedRequests()
        async throws {
        let suiteName = "MobileWatchBridgeTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountStore = MobileAccountStore(defaults: defaults)
        let enabled = try XCTUnwrap(
            accountStore.accounts(for: .copilot).first
        )
        let disabled = try accountStore.addAccount(
            provider: .copilot,
            label: "Disabled"
        )
        _ = try accountStore.updateAccount(
            id: disabled.id,
            label: disabled.label,
            isEnabled: false
        )
        let codex = try XCTUnwrap(accountStore.accounts(for: .codex).first)
        let credentials = WatchBridgeCredentialStore()
        credentials.values[enabled.id] = "enabled-token"
        credentials.values[disabled.id] = "disabled-token"
        let fetcher = WatchBridgeRecordingFetcher(
            counts: .init(working: 1, waiting: 0)
        )
        let activityController = MobileSessionActivityController(
            accountResolver: accountStore,
            credentialStore: credentials,
            fetcher: fetcher
        )
        let bridge = MobileWatchCompanionBridge(
            accountStore: accountStore,
            activityController: activityController,
            session: WatchBridgeSession()
        )

        let malformedRequests: [[String: Any]] = [
            [
                WatchCompanionTransportKeys.refreshAccountID:
                    "\(enabled.id.uuidString.lowercased()) "
            ],
            [
                WatchCompanionTransportKeys.refreshAccountID:
                    enabled.id.uuidString.lowercased(),
                "unexpected": true
            ],
            [
                WatchCompanionTransportKeys.refreshAccountID:
                    UUID().uuidString.lowercased()
            ],
            [
                WatchCompanionTransportKeys.refreshAccountID:
                    disabled.id.uuidString.lowercased()
            ],
            [
                WatchCompanionTransportKeys.refreshAccountID:
                    codex.id.uuidString.lowercased()
            ]
        ]

        for request in malformedRequests {
            let response = await bridge.response(toRefreshRequest: request)
            XCTAssertTrue(response.isEmpty)
        }

        let requestedCredentials = await fetcher.credentials()
        XCTAssertEqual(requestedCredentials, [])
        withExtendedLifetime(bridge) {}
    }
}

@MainActor
private final class WatchBridgeSession: MobileWatchCompanionSessioning {
    weak var delegate: (any WCSessionDelegate)?
    var activationState: WCSessionActivationState = .activated
    var isPaired = true
    var isWatchAppInstalled = true
    private(set) var activateCount = 0
    private(set) var contexts: [[String: Any]] = []

    func activate() {
        activateCount += 1
    }

    func updateApplicationContext(
        _ applicationContext: [String: Any]
    ) throws {
        contexts.append(applicationContext)
    }
}

@MainActor
private final class WatchBridgeCredentialStore:
    MobileSessionCredentialStoring {
    var values: [UUID: String] = [:]

    func credential(for accountID: UUID) throws -> String? {
        values[accountID]
    }

    func saveCredential(_ credential: String, for accountID: UUID) throws {
        values[accountID] = credential
    }

    func deleteCredential(for accountID: UUID) throws {
        values.removeValue(forKey: accountID)
    }

    func deleteAllCredentials() throws {
        values.removeAll()
    }
}

private actor WatchBridgeRecordingFetcher: GitHubAgentTaskFetching {
    private let counts: SessionActivityCounts
    private var requestedCredentials: [String] = []

    init(counts: SessionActivityCounts) {
        self.counts = counts
    }

    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        requestedCredentials.append(credential)
        return counts
    }

    func credentials() -> [String] {
        requestedCredentials
    }
}
