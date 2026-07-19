import SwiftUI

@main
@MainActor
struct AgentLimitsWatchApp: App {
    @StateObject private var store: WatchCompanionStore
    @StateObject private var connectivity: WatchConnectivityController

    init() {
        let connectivityEnabled: Bool
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ui-testing-reset") {
            UserDefaults.standard.removeObject(
                forKey: WatchCompanionStore.cacheKey
            )
        }
        connectivityEnabled = !arguments.contains(
            "-ui-testing-disable-connectivity"
        )
        #else
        connectivityEnabled = true
        #endif

        let store = WatchCompanionStore()
        _store = StateObject(wrappedValue: store)
        _connectivity = StateObject(
            wrappedValue: WatchConnectivityController(
                store: store,
                connectivityEnabled: connectivityEnabled
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(store: store)
        }
    }
}
