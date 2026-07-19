import Foundation
import XCTest
@testable import AgentLimits

final class SessionActivityModelsTests: XCTestCase {
    func testAvailableCountsAndStaleTimestampRemainTruthful() {
        let account = ProviderAccount(
            id: UUID(
                uuidString: "d5000000-0000-0000-0000-00000000000d"
            )!,
            provider: .githubCopilot,
            label: "Work"
        )
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let snapshot = SessionActivitySnapshot.available(
            account: account,
            counts: SessionActivityCounts(working: 2, waiting: 3),
            observedAt: observedAt
        )

        XCTAssertEqual(snapshot.accountID, account.id)
        XCTAssertEqual(snapshot.provider, .githubCopilot)
        XCTAssertEqual(snapshot.scope, .cloudAgentSessions)
        XCTAssertEqual(snapshot.working, 2)
        XCTAssertEqual(snapshot.waiting, 3)
        XCTAssertEqual(snapshot.open, 5)
        XCTAssertEqual(snapshot.availability, .available)

        let stale = snapshot.markingStale()
        XCTAssertEqual(stale.availability, .stale)
        XCTAssertEqual(stale.open, 5)
        XCTAssertEqual(stale.observedAt, observedAt)
    }

    func testUnsupportedSnapshotUsesNilRatherThanInventedZeroCounts() {
        let account = ProviderAccount(
            provider: .chatgptCodex,
            label: "Personal"
        )
        let snapshot = SessionActivitySnapshot.unavailable(
            account: account,
            availability: .unsupported,
            observedAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(snapshot.scope, .localRuntime)
        XCTAssertNil(snapshot.working)
        XCTAssertNil(snapshot.waiting)
        XCTAssertNil(snapshot.open)
        XCTAssertEqual(snapshot.availability, .unsupported)
    }
}
