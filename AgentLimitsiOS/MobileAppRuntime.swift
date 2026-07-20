import Foundation

@MainActor
struct MobileAppRuntime {
    let model: MobileAppModel
    let watchConnectivityEnabled: Bool

    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> MobileAppRuntime {
        #if DEBUG
        if isUITesting(arguments: arguments) {
            return MobileUITestRuntime.make()
        }
        #endif

        return MobileAppRuntime(
            model: MobileAppModel(),
            watchConnectivityEnabled: true
        )
    }

    #if DEBUG
    static func isUITesting(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains(MobileUITestRuntime.launchArgument)
    }
    #endif
}

#if DEBUG
/// UI automation must never inherit production account state or exercise
/// credential, network, or companion-device services.
@MainActor
private enum MobileUITestRuntime {
    static let launchArgument = "-ui-testing-reset"
    private static let defaultsSuiteName =
        "com.jimboha.agentlimits.ios.ui-testing"
    private static let accountPersistenceKey =
        "mobile_provider_accounts_ui_testing_v1"

    static func make() -> MobileAppRuntime {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            preconditionFailure("Could not create isolated UI-test defaults")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let credentialStore = MobileUITestCredentialStore()
        let accountStore = MobileAccountStore(
            defaults: defaults,
            key: accountPersistenceKey,
            purgeOrphanedCredentials: {
                try credentialStore.deleteAllCredentials()
            },
            deleteCredential: { accountID in
                try credentialStore.deleteCredential(for: accountID)
            }
        )
        return MobileAppRuntime(
            model: MobileAppModel(
                accountStore: accountStore,
                credentialStore: credentialStore,
                fetcher: MobileUITestGitHubAgentTaskFetcher()
            ),
            watchConnectivityEnabled: false
        )
    }
}

@MainActor
private final class MobileUITestCredentialStore:
    MobileSessionCredentialStoring {
    private var credentialsByAccountID: [UUID: String] = [:]

    func credential(for accountID: UUID) throws -> String? {
        credentialsByAccountID[accountID]
    }

    func saveCredential(
        _ credential: String,
        for accountID: UUID
    ) throws {
        credentialsByAccountID[accountID] = credential
    }

    func deleteCredential(for accountID: UUID) throws {
        credentialsByAccountID.removeValue(forKey: accountID)
    }

    func deleteAllCredentials() throws {
        credentialsByAccountID.removeAll()
    }
}

nonisolated private struct MobileUITestGitHubAgentTaskFetcher:
    GitHubAgentTaskFetching {
    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        throw GitHubAgentTaskFetcherError.transport
    }
}
#endif
