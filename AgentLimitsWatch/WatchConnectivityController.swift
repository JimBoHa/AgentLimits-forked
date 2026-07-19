import Combine
import Foundation
import WatchConnectivity

@MainActor
final class WatchConnectivityController: NSObject, ObservableObject {
    @Published private(set) var activationState: WCSessionActivationState =
        .notActivated

    private let store: WatchCompanionStore
    private let session: WCSession?

    init(
        store: WatchCompanionStore,
        connectivityEnabled: Bool = true
    ) {
        self.store = store
        self.session = connectivityEnabled && WCSession.isSupported()
            ? WCSession.default
            : nil
        super.init()

        store.setRefreshHandler { [weak self] accountID in
            self?.sendRefreshRequest(accountID: accountID)
        }

        guard let session else {
            store.setPhoneReachable(false)
            return
        }
        session.delegate = self
        session.activate()
    }

    private func sendRefreshRequest(accountID: UUID) {
        guard let session, session.activationState == .activated,
              session.isReachable else {
            store.setPhoneReachable(false)
            return
        }

        let message: [String: Any] = [
            WatchCompanionTransportKeys.refreshAccountID:
                accountID.uuidString.lowercased()
        ]
        session.sendMessage(message) { [weak self] reply in
            let data = Self.strictEnvelopeData(from: reply)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let data {
                    self.store.receiveEnvelopeData(data)
                } else {
                    self.store.reportInvalidReceivedData()
                }
            }
        } errorHandler: { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.store.setPhoneReachable(
                    self.session?.isReachable == true
                )
            }
        }
    }

    nonisolated private static func strictEnvelopeData(
        from payload: [String: Any]
    ) -> Data? {
        guard payload.count == 1 else { return nil }
        return payload[WatchCompanionTransportKeys.envelopeData] as? Data
    }

    private func handleApplicationContext(
        data: Data?,
        hasValidShape: Bool
    ) {
        guard hasValidShape, let data else {
            store.reportInvalidReceivedData()
            return
        }
        store.receiveEnvelopeData(data)
    }
}

extension WatchConnectivityController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: (any Error)?
    ) {
        let context = session.receivedApplicationContext
        let contextIsEmpty = context.isEmpty
        let contextData = Self.strictEnvelopeData(from: context)
        let contextHasValidShape = contextIsEmpty || contextData != nil
        let isReachable = error == nil && session.isReachable

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.activationState = activationState
            self.store.setPhoneReachable(isReachable)
            if !contextIsEmpty {
                self.handleApplicationContext(
                    data: contextData,
                    hasValidShape: contextHasValidShape
                )
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let isReachable = session.isReachable
        Task { @MainActor [weak self] in
            self?.store.setPhoneReachable(isReachable)
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let data = Self.strictEnvelopeData(from: applicationContext)
        let hasValidShape = data != nil
        Task { @MainActor [weak self] in
            self?.handleApplicationContext(
                data: data,
                hasValidShape: hasValidShape
            )
        }
    }
}
