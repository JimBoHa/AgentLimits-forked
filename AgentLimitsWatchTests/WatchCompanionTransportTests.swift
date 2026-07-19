import Foundation
import XCTest
@testable import AgentLimitsWatch

final class WatchCompanionTransportTests: XCTestCase {
    func testRoundTripPreservesExactPerAccountActivity() throws {
        let generatedAt = Date(timeIntervalSince1970: 10_000)
        let account = try makeStatus(
            working: 3,
            waiting: 2,
            open: 5,
            observedAt: generatedAt
        )
        let envelope = try WatchCompanionEnvelope(
            generatedAt: generatedAt,
            accounts: [account]
        )

        let data = try envelope.encodedData()
        let decoded = try WatchCompanionEnvelope.decodeValidated(data)

        XCTAssertEqual(decoded, envelope)
        XCTAssertEqual(decoded.accounts.first?.open, 5)
        XCTAssertLessThanOrEqual(
            data.count,
            WatchCompanionEnvelope.maximumPayloadBytes
        )
    }

    func testDecodeRejectsPayloadBeforeParsingWhenOverByteLimit() {
        let data = Data(
            repeating: 0x20,
            count: WatchCompanionEnvelope.maximumPayloadBytes + 1
        )

        XCTAssertThrowsError(
            try WatchCompanionEnvelope.decodeValidated(data)
        ) { error in
            XCTAssertEqual(
                error as? WatchCompanionTransportError,
                .payloadTooLarge(data.count)
            )
        }
    }

    func testEnvelopeRejectsMoreThanNinetySixAccounts() throws {
        let accounts = try (0...WatchCompanionEnvelope.maximumAccountCount)
            .map { index in
                try makeStatus(
                    id: UUID(),
                    label: "Account \(index)",
                    availability: .unsupported
                )
            }

        XCTAssertThrowsError(
            try WatchCompanionEnvelope(
                generatedAt: Date(timeIntervalSince1970: 1),
                accounts: accounts
            )
        ) { error in
            XCTAssertEqual(
                error as? WatchCompanionTransportError,
                .tooManyAccounts(accounts.count)
            )
        }
    }

    func testEnvelopeRejectsDuplicateAccountIdentity() throws {
        let id = UUID()
        let first = try makeStatus(id: id, label: "Personal")
        let duplicate = try makeStatus(id: id, label: "Work")

        XCTAssertThrowsError(
            try WatchCompanionEnvelope(
                generatedAt: Date(timeIntervalSince1970: 1),
                accounts: [first, duplicate]
            )
        ) { error in
            XCTAssertEqual(
                error as? WatchCompanionTransportError,
                .duplicateAccountID(id)
            )
        }
    }

    func testStatusRejectsInventedOrPartialCounts() {
        let id = UUID()

        XCTAssertThrowsError(
            try makeStatus(
                id: id,
                working: 2,
                waiting: 1,
                open: 0,
                observedAt: Date(timeIntervalSince1970: 1)
            )
        ) { error in
            XCTAssertEqual(
                error as? WatchCompanionTransportError,
                .inconsistentStatus(id)
            )
        }
    }

    func testStatusRejectsBlankPaddedAndOversizedLabels() {
        for label in [
            " ",
            " Padded",
            String(repeating: "a", count: 81)
        ] {
            let id = UUID()
            XCTAssertThrowsError(
                try makeStatus(id: id, label: label)
            ) { error in
                XCTAssertEqual(
                    error as? WatchCompanionTransportError,
                    .invalidLabel(id)
                )
            }
        }
    }

    func testDecodeRevalidatesWireCountsAndVersion() throws {
        let account = try makeStatus(
            working: 1,
            waiting: 1,
            open: 2,
            observedAt: Date(timeIntervalSince1970: 1)
        )
        let envelope = try WatchCompanionEnvelope(
            generatedAt: Date(timeIntervalSince1970: 2),
            accounts: [account]
        )
        let validData = try envelope.encodedData()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )
        var accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        accounts[0]["open"] = 99
        object["accounts"] = accounts

        let invalidCounts = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try WatchCompanionEnvelope.decodeValidated(invalidCounts)
        )

        object["accounts"] = try XCTUnwrap(
            JSONSerialization.jsonObject(with: validData) as? [String: Any]
        )["accounts"]
        object["version"] = WatchCompanionEnvelope.currentVersion + 1
        let futureVersion = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try WatchCompanionEnvelope.decodeValidated(futureVersion)
        )
    }

    func testRateLimitRequiresRetryTimestampAndAllOrNoCounts() throws {
        let retryAt = Date(timeIntervalSince1970: 100)
        XCTAssertNoThrow(
            try makeStatus(
                availability: .rateLimited,
                working: nil,
                waiting: nil,
                open: nil,
                observedAt: nil,
                retryAt: retryAt
            )
        )
        XCTAssertNoThrow(
            try makeStatus(
                availability: .rateLimited,
                working: 1,
                waiting: 0,
                open: 1,
                observedAt: Date(timeIntervalSince1970: 50),
                retryAt: retryAt
            )
        )
        XCTAssertThrowsError(
            try makeStatus(availability: .rateLimited)
        )
    }

    func testEnvelopeRejectsObservationFarAfterGeneration() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_000)
        let status = try makeStatus(
            observedAt: generatedAt.addingTimeInterval(
                WatchCompanionEnvelope.maximumObservationClockSkew + 1
            )
        )

        XCTAssertThrowsError(
            try WatchCompanionEnvelope(
                generatedAt: generatedAt,
                accounts: [status]
            )
        )
    }

    private func makeStatus(
        id: UUID = UUID(),
        label: String = "Personal",
        availability: WatchCompanionAvailability = .available,
        working: Int? = 1,
        waiting: Int? = 2,
        open: Int? = 3,
        observedAt: Date? = Date(timeIntervalSince1970: 1),
        retryAt: Date? = nil
    ) throws -> WatchCompanionAccountStatus {
        let hasCounts = availability == .available || availability == .stale
        return try WatchCompanionAccountStatus(
            id: id,
            provider: .copilot,
            label: label,
            isEnabled: true,
            availability: availability,
            working: hasCounts || availability == .rateLimited ? working : nil,
            waiting: hasCounts || availability == .rateLimited ? waiting : nil,
            open: hasCounts || availability == .rateLimited ? open : nil,
            observedAt: hasCounts || availability == .rateLimited
                ? observedAt
                : nil,
            retryAt: retryAt
        )
    }
}
