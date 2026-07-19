import Combine
import Foundation

protocol WatchCompanionCaching: AnyObject {
    func companionData(forKey key: String) -> Data?
    func setCompanionData(_ data: Data, forKey key: String)
    func removeCompanionData(forKey key: String)
}

extension UserDefaults: WatchCompanionCaching {
    func companionData(forKey key: String) -> Data? {
        data(forKey: key)
    }

    func setCompanionData(_ data: Data, forKey key: String) {
        set(data, forKey: key)
    }

    func removeCompanionData(forKey key: String) {
        removeObject(forKey: key)
    }
}

nonisolated enum WatchCompanionStoreError: String, LocalizedError, Equatable {
    case invalidCachedData
    case invalidReceivedData

    var errorDescription: String? {
        switch self {
        case .invalidCachedData:
            return "Saved companion data was invalid and was removed."
        case .invalidReceivedData:
            return "The iPhone sent invalid companion data. Last valid data was kept."
        }
    }
}

nonisolated struct WatchCompanionAccountPresentation:
    Equatable,
    Identifiable,
    Sendable {
    let status: WatchCompanionAccountStatus
    let availability: WatchCompanionAvailability

    var id: UUID { status.id }
}

@MainActor
final class WatchCompanionStore: ObservableObject {
    static let cacheKey = "com.jimboha.agentlimits.watch.envelope.v1"
    static let defaultFreshnessInterval: TimeInterval = 10 * 60
    static let maximumFutureClockSkew: TimeInterval = 5 * 60

    @Published private(set) var envelope: WatchCompanionEnvelope?
    @Published private(set) var isPhoneReachable = false
    @Published private(set) var lastError: WatchCompanionStoreError?

    private let cache: any WatchCompanionCaching
    private let now: () -> Date
    private let freshnessInterval: TimeInterval
    private var refreshHandler: ((UUID) -> Void)?

    init(
        cache: any WatchCompanionCaching = UserDefaults.standard,
        now: @escaping () -> Date = Date.init,
        freshnessInterval: TimeInterval = defaultFreshnessInterval
    ) {
        precondition(
            freshnessInterval.isFinite && freshnessInterval > 0,
            "Companion freshness interval must be positive and finite"
        )
        self.cache = cache
        self.now = now
        self.freshnessInterval = freshnessInterval

        guard let cachedData = cache.companionData(forKey: Self.cacheKey) else {
            return
        }
        do {
            let decoded = try WatchCompanionEnvelope.decodeValidated(cachedData)
            guard Self.hasAcceptableGenerationDate(decoded, now: now()) else {
                throw WatchCompanionTransportError.invalidGeneratedAt
            }
            envelope = decoded
        } catch {
            cache.removeCompanionData(forKey: Self.cacheKey)
            lastError = .invalidCachedData
        }
    }

    var hasData: Bool { envelope != nil }

    var isDataStale: Bool {
        isDataStale(at: now())
    }

    func isDataStale(at date: Date) -> Bool {
        guard let generatedAt = envelope?.generatedAt else { return false }
        return age(of: generatedAt, at: date) >= freshnessInterval
    }

    func accounts(
        for provider: WatchCompanionProvider,
        at date: Date? = nil
    ) -> [WatchCompanionAccountPresentation] {
        let evaluationDate = date ?? now()
        return envelope?.accounts
            .filter { $0.provider == provider }
            .map {
                WatchCompanionAccountPresentation(
                    status: $0,
                    availability: effectiveAvailability(
                        for: $0,
                        at: evaluationDate
                    )
                )
            } ?? []
    }

    func account(
        id: UUID,
        at date: Date? = nil
    ) -> WatchCompanionAccountPresentation? {
        guard let status = envelope?.accounts.first(where: { $0.id == id }) else {
            return nil
        }
        return WatchCompanionAccountPresentation(
            status: status,
            availability: effectiveAvailability(
                for: status,
                at: date ?? now()
            )
        )
    }

    @discardableResult
    func receiveEnvelopeData(_ data: Data) -> Bool {
        let decoded: WatchCompanionEnvelope
        do {
            decoded = try WatchCompanionEnvelope.decodeValidated(data)
        } catch {
            lastError = .invalidReceivedData
            return false
        }
        guard Self.hasAcceptableGenerationDate(decoded, now: now()) else {
            lastError = .invalidReceivedData
            return false
        }

        // A delayed reply must not roll back a newer application context.
        if let current = envelope, decoded.generatedAt < current.generatedAt {
            return false
        }

        cache.setCompanionData(data, forKey: Self.cacheKey)
        envelope = decoded
        lastError = nil
        return true
    }

    func setPhoneReachable(_ isReachable: Bool) {
        isPhoneReachable = isReachable
    }

    func setRefreshHandler(_ handler: @escaping (UUID) -> Void) {
        refreshHandler = handler
    }

    /// Sends only account identity. Credentials, labels, and counts never leave
    /// this store through a refresh request.
    @discardableResult
    func requestRefresh(accountID: UUID) -> Bool {
        guard isPhoneReachable,
              envelope?.accounts.contains(where: {
                  $0.id == accountID
                      && $0.provider == .copilot
                      && $0.isEnabled
              }) == true,
              let refreshHandler else {
            return false
        }
        refreshHandler(accountID)
        return true
    }

    func clearError() {
        lastError = nil
    }

    func reportInvalidReceivedData() {
        lastError = .invalidReceivedData
    }

    #if DEBUG
    func clearCachedDataForUITesting() {
        cache.removeCompanionData(forKey: Self.cacheKey)
        envelope = nil
        lastError = nil
    }
    #endif

    private func effectiveAvailability(
        for status: WatchCompanionAccountStatus,
        at date: Date
    ) -> WatchCompanionAvailability {
        guard status.availability == .available else {
            return status.availability
        }
        let observedIsStale = status.observedAt.map {
            age(of: $0, at: date) >= freshnessInterval
        } ?? true
        return isDataStale(at: date) || observedIsStale
            ? .stale
            : .available
    }

    private func age(of timestamp: Date, at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(timestamp))
    }

    private static func hasAcceptableGenerationDate(
        _ envelope: WatchCompanionEnvelope,
        now: Date
    ) -> Bool {
        envelope.generatedAt.timeIntervalSince(now) <= maximumFutureClockSkew
    }
}
