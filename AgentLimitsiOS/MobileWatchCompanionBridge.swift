import Combine
import Foundation
@preconcurrency import WatchConnectivity

@MainActor
protocol MobileWatchCompanionSessioning: AnyObject {
    var delegate: (any WCSessionDelegate)? { get set }
    var activationState: WCSessionActivationState { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }

    func activate()
    func updateApplicationContext(
        _ applicationContext: [String: Any]
    ) throws
}

extension WCSession: MobileWatchCompanionSessioning {}

nonisolated private final class MobileWatchReplyHandlerBox:
    @unchecked Sendable {
    private let handler: ([String: Any]) -> Void

    init(_ handler: @escaping ([String: Any]) -> Void) {
        self.handler = handler
    }

    func callAsFunction(_ response: [String: Any]) {
        handler(response)
    }
}

@MainActor
final class MobileWatchCompanionBridge: NSObject {
    private struct SanitizedAccountState: Equatable {
        let id: UUID
        let provider: MobileProvider
        let label: String
        let isEnabled: Bool
        let availability: MobileSessionAvailability
        let working: Int?
        let waiting: Int?
        let open: Int?
        let observedAt: Date?
        let retryAt: Date?

        func watchStatus() throws -> WatchCompanionAccountStatus {
            try WatchCompanionAccountStatus(
                id: id,
                provider: provider.watchCompanionProvider,
                label: label,
                isEnabled: isEnabled,
                availability: availability.watchCompanionAvailability,
                working: working,
                waiting: waiting,
                open: open,
                observedAt: observedAt,
                retryAt: retryAt
            )
        }
    }

    private struct PendingContext {
        let state: [SanitizedAccountState]
        let data: Data
    }

    private let accountStore: MobileAccountStore
    private let activityController: MobileSessionActivityController
    private let session: any MobileWatchCompanionSessioning
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []
    private var pendingContext: PendingContext?
    private var lastSentState: [SanitizedAccountState]?
    private var lastSentData: Data?

    private(set) var lastTransportErrorDescription: String?

    convenience init?(
        accountStore: MobileAccountStore,
        activityController: MobileSessionActivityController,
        now: @escaping () -> Date = Date.init
    ) {
        guard WCSession.isSupported() else { return nil }
        self.init(
            accountStore: accountStore,
            activityController: activityController,
            session: WCSession.default,
            now: now
        )
    }

    init(
        accountStore: MobileAccountStore,
        activityController: MobileSessionActivityController,
        session: any MobileWatchCompanionSessioning,
        now: @escaping () -> Date = Date.init
    ) {
        self.accountStore = accountStore
        self.activityController = activityController
        self.session = session
        self.now = now
        super.init()

        session.delegate = self
        observeSanitizedState()
        session.activate()
    }

    private func observeSanitizedState() {
        Publishers.CombineLatest(
            accountStore.$accounts,
            activityController.$snapshotsByAccountID
        )
        .sink { [weak self] _, _ in
            self?.publishCurrentState()
        }
        .store(in: &cancellables)
    }

    @discardableResult
    private func publishCurrentState(force: Bool = false) -> Data? {
        let state = sanitizedState()

        if !force {
            if pendingContext?.state == state {
                attemptPendingContextDelivery()
                return pendingContext?.data ?? lastSentData
            }
            if pendingContext == nil, lastSentState == state {
                return lastSentData
            }
        }

        do {
            guard state.count <= WatchCompanionEnvelope.maximumAccountCount else {
                throw MobileWatchCompanionBridgeError.tooManyAccounts
            }
            let statuses = try state.map { try $0.watchStatus() }
            let envelope = try WatchCompanionEnvelope(
                generatedAt: now(),
                accounts: statuses
            )
            let data = try envelope.encodedData()
            pendingContext = PendingContext(state: state, data: data)
            attemptPendingContextDelivery()
            return data
        } catch {
            pendingContext = nil
            lastTransportErrorDescription = error.localizedDescription
            return nil
        }
    }

    private func sanitizedState() -> [SanitizedAccountState] {
        accountStore.accounts.map { account in
            let snapshot = activityController.snapshot(for: account)
            return SanitizedAccountState(
                id: account.id,
                provider: account.provider,
                label: account.label,
                isEnabled: account.isEnabled,
                availability: snapshot.availability,
                working: snapshot.working,
                waiting: snapshot.waiting,
                open: snapshot.open,
                observedAt: snapshot.observedAt,
                retryAt: snapshot.retryAt
            )
        }
    }

    private func attemptPendingContextDelivery() {
        guard let pendingContext,
              session.activationState == .activated,
              session.isPaired,
              session.isWatchAppInstalled else {
            return
        }

        do {
            try session.updateApplicationContext([
                WatchCompanionTransportKeys.envelopeData:
                    pendingContext.data
            ])
            lastSentState = pendingContext.state
            lastSentData = pendingContext.data
            self.pendingContext = nil
            lastTransportErrorDescription = nil
        } catch {
            lastTransportErrorDescription = error.localizedDescription
        }
    }

    func response(toRefreshRequest message: [String: Any]) async
        -> [String: Any] {
        guard let accountID = Self.refreshAccountID(from: message),
              let account = accountStore.account(id: accountID),
              account.isEnabled,
              account.provider.supportsCurrentSessions else {
            return [:]
        }

        await activityController.refresh(
            accountID: accountID,
            reason: .manual
        )
        guard let data = publishCurrentState(force: true) else { return [:] }
        return [WatchCompanionTransportKeys.envelopeData: data]
    }

    nonisolated private static func refreshAccountID(
        from message: [String: Any]
    ) -> UUID? {
        guard message.count == 1,
              let rawID = message[
                WatchCompanionTransportKeys.refreshAccountID
              ] as? String,
              let accountID = UUID(uuidString: rawID),
              rawID == accountID.uuidString.lowercased() else {
            return nil
        }
        return accountID
    }

    private func activationCompleted(errorDescription: String?) {
        if let errorDescription {
            lastTransportErrorDescription = errorDescription
            return
        }
        attemptPendingContextDelivery()
    }
}

extension MobileWatchCompanionBridge: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let errorDescription = error?.localizedDescription
        Task { @MainActor [weak self] in
            self?.activationCompleted(errorDescription: errorDescription)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.attemptPendingContextDelivery()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let reply = MobileWatchReplyHandlerBox(replyHandler)
        guard let accountID = Self.refreshAccountID(from: message) else {
            reply([:])
            return
        }
        let validatedMessage: [String: Any] = [
            WatchCompanionTransportKeys.refreshAccountID:
                accountID.uuidString.lowercased()
        ]
        Task { @MainActor [weak self] in
            guard let self else {
                reply([:])
                return
            }
            reply(await self.response(toRefreshRequest: validatedMessage))
        }
    }
}

nonisolated private enum MobileWatchCompanionBridgeError: LocalizedError {
    case tooManyAccounts

    var errorDescription: String? {
        switch self {
        case .tooManyAccounts:
            return "The watch snapshot exceeds the account limit."
        }
    }
}

nonisolated private extension MobileProvider {
    var watchCompanionProvider: WatchCompanionProvider {
        switch self {
        case .codex:
            return .codex
        case .claude:
            return .claude
        case .copilot:
            return .copilot
        }
    }
}

nonisolated private extension MobileSessionAvailability {
    var watchCompanionAvailability: WatchCompanionAvailability {
        switch self {
        case .notChecked:
            return .notChecked
        case .available:
            return .available
        case .stale:
            return .stale
        case .unsupported:
            return .unsupported
        case .authenticationRequired:
            return .authenticationRequired
        case .insufficientPermissions:
            return .insufficientPermissions
        case .rateLimited:
            return .rateLimited
        case .unavailable:
            return .unavailable
        }
    }
}
