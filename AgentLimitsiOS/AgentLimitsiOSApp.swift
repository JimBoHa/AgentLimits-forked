import SwiftUI

@main
@MainActor
struct AgentLimitsiOSApp: App {
    @StateObject private var model: MobileAppModel
    private let watchCompanionBridge: MobileWatchCompanionBridge?

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            try? MobileSessionCredentialStore().deleteAllCredentials()
            UserDefaults.standard.removeObject(
                forKey: MobileAccountStore.persistenceKey
            )
        }
        #endif
        let model = MobileAppModel()
        _model = StateObject(wrappedValue: model)
        watchCompanionBridge = MobileWatchCompanionBridge(
            accountStore: model.accountStore,
            activityController: model.activityController
        )
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
        }
    }
}
