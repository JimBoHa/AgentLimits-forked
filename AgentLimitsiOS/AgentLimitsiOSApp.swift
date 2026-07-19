import SwiftUI

@main
@MainActor
struct AgentLimitsiOSApp: App {
    @StateObject private var model: MobileAppModel

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ui-testing-reset") {
            try? MobileSessionCredentialStore().deleteAllCredentials()
            UserDefaults.standard.removeObject(
                forKey: MobileAccountStore.persistenceKey
            )
        }
        #endif
        _model = StateObject(wrappedValue: MobileAppModel())
    }

    var body: some Scene {
        WindowGroup {
            MobileRootView(model: model)
        }
    }
}
