import Foundation

@MainActor
struct MobileAppRuntime {
    let model: MobileAppModel
    let watchConnectivityEnabled: Bool

    static func make(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> MobileAppRuntime {
        #if DEBUG
        if isAppStoreScreenshotTesting(arguments: arguments) {
            return MobileAppStoreScreenshotRuntime.make()
        }
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

    static func isAppStoreScreenshotTesting(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) -> Bool {
        arguments.contains(AppStoreScreenshotFixture.launchArgument)
    }
    #endif
}

#if DEBUG
@MainActor
private enum MobileAppStoreScreenshotRuntime {
    private struct AccountPayload: Encodable {
        let version = 1
        let accounts: [MobileProviderAccount]
        let pendingCredentialDeletionIDs: [UUID]? = nil
    }

    private static let defaultsSuiteName =
        "com.jimboha.agentlimits.ios.app-store-screenshot"
    private static let accountPersistenceKey =
        "mobile_provider_accounts_app_store_screenshot_v1"
    private static let createdAt = Date(timeIntervalSince1970: 1_767_225_600)

    static func make() -> MobileAppRuntime {
        guard let defaults = UserDefaults(suiteName: defaultsSuiteName) else {
            preconditionFailure("Could not create isolated screenshot defaults")
        }
        defaults.removePersistentDomain(forName: defaultsSuiteName)

        let accounts = makeAccounts()
        let payload = AccountPayload(accounts: accounts)
        guard let accountData = try? JSONEncoder().encode(payload) else {
            preconditionFailure("Could not encode screenshot accounts")
        }
        defaults.set(accountData, forKey: accountPersistenceKey)
        guard defaults.data(forKey: accountPersistenceKey) == accountData else {
            preconditionFailure("Could not persist isolated screenshot accounts")
        }

        let credentialStore = MobileInMemoryCredentialStore(
            credentialsByAccountID: [
                AppStoreScreenshotFixture.personalCopilotID:
                    AppStoreScreenshotFixture
                        .personalCopilotCredentialMarker,
                AppStoreScreenshotFixture.workCopilotID:
                    AppStoreScreenshotFixture.workCopilotCredentialMarker
            ]
        )
        let accountStore = MobileAccountStore(
            defaults: defaults,
            key: accountPersistenceKey,
            now: { createdAt },
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
                fetcher: MobileAppStoreScreenshotFetcher()
            ),
            watchConnectivityEnabled: false
        )
    }

    private static func makeAccounts() -> [MobileProviderAccount] {
        [
            MobileProviderAccount(
                id: AppStoreScreenshotFixture.personalCodexID,
                provider: .codex,
                label: AppStoreScreenshotFixture.personalCodexLabel,
                createdAt: createdAt
            ),
            MobileProviderAccount(
                id: AppStoreScreenshotFixture.personalClaudeID,
                provider: .claude,
                label: AppStoreScreenshotFixture.personalClaudeLabel,
                createdAt: createdAt.addingTimeInterval(1)
            ),
            MobileProviderAccount(
                id: AppStoreScreenshotFixture.personalCopilotID,
                provider: .copilot,
                label: AppStoreScreenshotFixture.personalCopilotLabel,
                createdAt: createdAt.addingTimeInterval(2)
            ),
            MobileProviderAccount(
                id: AppStoreScreenshotFixture.workCopilotID,
                provider: .copilot,
                label: AppStoreScreenshotFixture.workCopilotLabel,
                createdAt: createdAt.addingTimeInterval(3)
            )
        ]
    }
}

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

        let credentialStore = MobileInMemoryCredentialStore()
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
private final class MobileInMemoryCredentialStore:
    MobileSessionCredentialStoring {
    private var credentialsByAccountID: [UUID: String]

    init(credentialsByAccountID: [UUID: String] = [:]) {
        self.credentialsByAccountID = credentialsByAccountID
    }

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

nonisolated private struct MobileAppStoreScreenshotFetcher:
    GitHubAgentTaskFetching {
    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        switch credential {
        case AppStoreScreenshotFixture.personalCopilotCredentialMarker:
            return SessionActivityCounts(
                working: AppStoreScreenshotFixture.personalCopilotWorking,
                waiting: AppStoreScreenshotFixture.personalCopilotWaiting
            )
        case AppStoreScreenshotFixture.workCopilotCredentialMarker:
            return SessionActivityCounts(
                working: AppStoreScreenshotFixture.workCopilotWorking,
                waiting: AppStoreScreenshotFixture.workCopilotWaiting
            )
        default:
            throw GitHubAgentTaskFetcherError.authenticationRequired
        }
    }
}
#endif
