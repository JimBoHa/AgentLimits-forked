import SwiftUI

@main
@MainActor
struct AgentLimitsiOSApp: App {
    @StateObject private var model: MobileAppModel
    private let watchCompanionBridge: MobileWatchCompanionBridge?

    init() {
        let runtime = MobileAppRuntime.make()
        _model = StateObject(wrappedValue: runtime.model)
        watchCompanionBridge = runtime.watchConnectivityEnabled
            ? MobileWatchCompanionBridge(
                accountStore: runtime.model.accountStore,
                activityController: runtime.model.activityController
            )
            : nil
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
        }
    }
}
