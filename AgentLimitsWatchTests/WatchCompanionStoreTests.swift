import Foundation
import XCTest
@testable import AgentLimitsWatch

final class WatchCompanionStoreTests: XCTestCase {
    @MainActor
    func testNoDataAndNoPhoneAreSafeInitialState() {
        let store = WatchCompanionStore(cache: InMemoryCompanionCache())

        XCTAssertFalse(store.hasData)
        XCTAssertFalse(store.isDataStale)
        XCTAssertFalse(store.isPhoneReachable)
        XCTAssertTrue(store.accounts(for: .copilot).isEmpty)
        XCTAssertFalse(store.requestRefresh(accountID: UUID()))
    }

    @MainActor
    func testLoadsValidatedCacheAndMarksItStaleAfterTenMinutes()
        throws {
        let cache = InMemoryCompanionCache()
        let generatedAt = Date(timeIntervalSince1970: 1_000)
        let status = try makeStatus(observedAt: generatedAt)
        let envelope = try WatchCompanionEnvelope(
            generatedAt: generatedAt,
            accounts: [status]
        )
        cache.setCompanionData(
            try envelope.encodedData(),
            forKey: WatchCompanionStore.cacheKey
        )
        var currentDate = generatedAt.addingTimeInterval(599)
        let store = WatchCompanionStore(
            cache: cache,
            now: { currentDate }
        )

        XCTAssertTrue(store.hasData)
        XCTAssertFalse(store.isDataStale)
        XCTAssertEqual(
            store.account(id: status.id)?.availability,
            .available
        )

        currentDate = generatedAt.addingTimeInterval(600)

        XCTAssertTrue(store.isDataStale)
        XCTAssertEqual(store.account(id: status.id)?.availability, .stale)
        XCTAssertEqual(store.account(id: status.id)?.status.open, 3)
    }

    @MainActor
    func testOldObservationIsStaleEvenInsideFreshEnvelope() throws {
        let observedAt = Date(timeIntervalSince1970: 1_000)
        let generatedAt = observedAt.addingTimeInterval(700)
        let status = try makeStatus(observedAt: observedAt)
        let envelope = try WatchCompanionEnvelope(
            generatedAt: generatedAt,
            accounts: [status]
        )
        let store = WatchCompanionStore(
            cache: InMemoryCompanionCache(),
            now: { generatedAt }
        )

        XCTAssertTrue(store.receiveEnvelopeData(try envelope.encodedData()))
        XCTAssertFalse(store.isDataStale)
        XCTAssertEqual(store.account(id: status.id)?.availability, .stale)
    }

    @MainActor
    func testInvalidCacheIsRemovedAndReported() {
        let cache = InMemoryCompanionCache()
        cache.setCompanionData(
            Data("not-json".utf8),
            forKey: WatchCompanionStore.cacheKey
        )

        let store = WatchCompanionStore(cache: cache)

        XCTAssertFalse(store.hasData)
        XCTAssertEqual(store.lastError, .invalidCachedData)
        XCTAssertNil(cache.companionData(forKey: WatchCompanionStore.cacheKey))
    }

    @MainActor
    func testInvalidReceivedDataKeepsLastValidCache() throws {
        let cache = InMemoryCompanionCache()
        let envelope = try makeEnvelope(generatedAt: .init(timeIntervalSince1970: 2))
        let validData = try envelope.encodedData()
        let store = WatchCompanionStore(cache: cache)
        XCTAssertTrue(store.receiveEnvelopeData(validData))

        XCTAssertFalse(store.receiveEnvelopeData(Data("{".utf8)))

        XCTAssertEqual(store.envelope, envelope)
        XCTAssertEqual(store.lastError, .invalidReceivedData)
        XCTAssertEqual(
            cache.companionData(forKey: WatchCompanionStore.cacheKey),
            validData
        )
    }

    @MainActor
    func testDelayedReplyCannotRollBackNewerContext() throws {
        let cache = InMemoryCompanionCache()
        let newer = try makeEnvelope(generatedAt: .init(timeIntervalSince1970: 20))
        let older = try makeEnvelope(generatedAt: .init(timeIntervalSince1970: 10))
        let newerData = try newer.encodedData()
        let store = WatchCompanionStore(cache: cache)

        XCTAssertTrue(store.receiveEnvelopeData(newerData))
        XCTAssertFalse(store.receiveEnvelopeData(try older.encodedData()))

        XCTAssertEqual(store.envelope, newer)
        XCTAssertEqual(
            cache.companionData(forKey: WatchCompanionStore.cacheKey),
            newerData
        )
    }

    @MainActor
    func testFutureTimestampCannotPinCache() throws {
        let currentDate = Date(timeIntervalSince1970: 1_000)
        let store = WatchCompanionStore(
            cache: InMemoryCompanionCache(),
            now: { currentDate }
        )
        let future = try makeEnvelope(
            generatedAt: currentDate.addingTimeInterval(
                WatchCompanionStore.maximumFutureClockSkew + 1
            )
        )
        let current = try makeEnvelope(generatedAt: currentDate)

        XCTAssertFalse(store.receiveEnvelopeData(try future.encodedData()))
        XCTAssertNil(store.envelope)
        XCTAssertEqual(store.lastError, .invalidReceivedData)
        XCTAssertTrue(store.receiveEnvelopeData(try current.encodedData()))
        XCTAssertEqual(store.envelope, current)
    }

    @MainActor
    func testRefreshCallbackReceivesOnlyRegisteredUUIDWhenReachable()
        throws {
        let status = try makeStatus()
        let envelope = try WatchCompanionEnvelope(
            generatedAt: Date(timeIntervalSince1970: 2),
            accounts: [status]
        )
        let store = WatchCompanionStore(cache: InMemoryCompanionCache())
        var requests: [UUID] = []
        store.setRefreshHandler { requests.append($0) }
        XCTAssertTrue(store.receiveEnvelopeData(try envelope.encodedData()))

        XCTAssertFalse(store.requestRefresh(accountID: status.id))
        store.setPhoneReachable(true)
        XCTAssertFalse(store.requestRefresh(accountID: UUID()))
        XCTAssertTrue(store.requestRefresh(accountID: status.id))

        XCTAssertEqual(requests, [status.id])
    }

    @MainActor
    func testRefreshRejectsDisabledAndUnsupportedAccounts() throws {
        let disabled = try makeStatus(isEnabled: false)
        let unsupported = try makeStatus(provider: .codex)
        let envelope = try WatchCompanionEnvelope(
            generatedAt: Date(timeIntervalSince1970: 2),
            accounts: [disabled, unsupported]
        )
        let store = WatchCompanionStore(cache: InMemoryCompanionCache())
        var requests: [UUID] = []
        store.setRefreshHandler { requests.append($0) }
        store.setPhoneReachable(true)
        XCTAssertTrue(store.receiveEnvelopeData(try envelope.encodedData()))

        XCTAssertFalse(store.requestRefresh(accountID: disabled.id))
        XCTAssertFalse(store.requestRefresh(accountID: unsupported.id))
        XCTAssertTrue(requests.isEmpty)
    }

    private func makeEnvelope(
        generatedAt: Date
    ) throws -> WatchCompanionEnvelope {
        try WatchCompanionEnvelope(
            generatedAt: generatedAt,
            accounts: [try makeStatus(observedAt: generatedAt)]
        )
    }

    private func makeStatus(
        provider: WatchCompanionProvider = .copilot,
        isEnabled: Bool = true,
        observedAt: Date = Date(timeIntervalSince1970: 1)
    ) throws -> WatchCompanionAccountStatus {
        try WatchCompanionAccountStatus(
            id: UUID(),
            provider: provider,
            label: "Personal",
            isEnabled: isEnabled,
            availability: .available,
            working: 1,
            waiting: 2,
            open: 3,
            observedAt: observedAt,
            retryAt: nil
        )
    }
}

private final class InMemoryCompanionCache: WatchCompanionCaching {
    private var values: [String: Data] = [:]

    func companionData(forKey key: String) -> Data? {
        values[key]
    }

    func setCompanionData(_ data: Data, forKey key: String) {
        values[key] = data
    }

    func removeCompanionData(forKey key: String) {
        values.removeValue(forKey: key)
    }
}
