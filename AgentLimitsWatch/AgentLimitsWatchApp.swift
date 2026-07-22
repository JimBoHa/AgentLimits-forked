import SwiftUI

@MainActor
struct WatchAppRuntime {
    let store: WatchCompanionStore
    let connectivityEnabled: Bool
    let appStoreScreenshotMode: Bool

    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> WatchAppRuntime {
        #if DEBUG
        if arguments.contains(AppStoreScreenshotFixture.launchArgument) {
            return makeAppStoreScreenshotRuntime()
        }
        if arguments.contains("-ui-testing-reset") {
            UserDefaults.standard.removeObject(
                forKey: WatchCompanionStore.cacheKey
            )
        }
        return WatchAppRuntime(
            store: WatchCompanionStore(),
            connectivityEnabled: !arguments.contains(
                "-ui-testing-disable-connectivity"
            ),
            appStoreScreenshotMode: false
        )
        #else
        return WatchAppRuntime(
            store: WatchCompanionStore(),
            connectivityEnabled: true,
            appStoreScreenshotMode: false
        )
        #endif
    }

    #if DEBUG
    private static func makeAppStoreScreenshotRuntime() -> WatchAppRuntime {
        let generatedAt = Date()
        let store = WatchCompanionStore(
            cache: WatchAppStoreScreenshotCache(),
            now: { generatedAt }
        )
        do {
            let envelope = try AppStoreScreenshotFixture.makeWatchEnvelope(
                generatedAt: generatedAt
            )
            guard store.receiveEnvelopeData(try envelope.encodedData()) else {
                preconditionFailure("Could not load screenshot companion data")
            }
        } catch {
            preconditionFailure(
                "Could not create screenshot companion data: \(error)"
            )
        }
        store.setPhoneReachable(true)
        store.setRefreshHandler { _ in }
        return WatchAppRuntime(
            store: store,
            connectivityEnabled: false,
            appStoreScreenshotMode: true
        )
    }
    #endif
}

@main
@MainActor
struct AgentLimitsWatchApp: App {
    @StateObject private var store: WatchCompanionStore
    @StateObject private var connectivity: WatchConnectivityController
    private let appStoreScreenshotMode: Bool

    init() {
        let runtime = WatchAppRuntime.make()
        let connectivity = WatchConnectivityController(
            store: runtime.store,
            connectivityEnabled: runtime.connectivityEnabled
        )
        #if DEBUG
        if runtime.appStoreScreenshotMode {
            runtime.store.setPhoneReachable(true)
            runtime.store.setRefreshHandler { _ in }
        }
        #endif
        _store = StateObject(wrappedValue: runtime.store)
        _connectivity = StateObject(
            wrappedValue: connectivity
        )
        appStoreScreenshotMode = runtime.appStoreScreenshotMode
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView(
                store: store,
                appStoreScreenshotMode: appStoreScreenshotMode
            )
        }
    }
}

#if DEBUG
private final class WatchAppStoreScreenshotCache: WatchCompanionCaching {
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
#endif
