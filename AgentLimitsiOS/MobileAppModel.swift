import Combine
import Foundation

enum MobileAppModelError: LocalizedError, Equatable {
    case accountRemovalRollbackFailed

    var errorDescription: String? {
        switch self {
        case .accountRemovalRollbackFailed:
            return "The account could not be restored after credential cleanup failed. Restart the app before making more changes."
        }
    }
}

@MainActor
final class MobileAppModel: ObservableObject {
    let accountStore: MobileAccountStore
    let activityController: MobileSessionActivityController

    init(
        accountStore: MobileAccountStore? = nil,
        credentialStore: (any MobileSessionCredentialStoring)? = nil,
        fetcher: (any GitHubAgentTaskFetching)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let resolvedCredentialStore: any MobileSessionCredentialStoring
        if let credentialStore {
            resolvedCredentialStore = credentialStore
        } else {
            resolvedCredentialStore = MobileSessionCredentialStore()
        }
        let resolvedAccountStore = accountStore ?? MobileAccountStore(
            now: now,
            purgeOrphanedCredentials: {
                try resolvedCredentialStore.deleteAllCredentials()
            },
            deleteCredential: { accountID in
                try resolvedCredentialStore.deleteCredential(for: accountID)
            }
        )
        self.accountStore = resolvedAccountStore
        self.activityController = MobileSessionActivityController(
            accountResolver: resolvedAccountStore,
            credentialStore: resolvedCredentialStore,
            fetcher: fetcher ?? GitHubAgentTaskFetcher(),
            now: now
        )
    }

    @discardableResult
    func addAccount(
        provider: MobileProvider,
        label: String
    ) throws -> MobileProviderAccount {
        try accountStore.addAccount(provider: provider, label: label)
    }

    @discardableResult
    func updateAccount(
        id: UUID,
        label: String,
        isEnabled: Bool
    ) throws -> MobileProviderAccount {
        try accountStore.updateAccount(
            id: id,
            label: label,
            isEnabled: isEnabled
        )
    }

    func removeAccount(id: UUID) async throws {
        let plan = try accountStore.prepareRemoval(id: id)
        try await activityController.prepareAccountRetirement(plan.target)
        let removedAccount: MobileProviderAccount
        do {
            try activityController.validatePreparedAccountRetirement(
                plan.target
            )
            removedAccount = try accountStore.beginRemoval(plan)
        } catch {
            activityController.cancelAccountRetirement(plan.target)
            throw error
        }
        do {
            try activityController.retireAccount(plan.target)
        } catch {
            do {
                try accountStore.restoreRemoval(
                    plan,
                    removedAccount: removedAccount
                )
            } catch {
                throw MobileAppModelError.accountRemovalRollbackFailed
            }
            throw error
        }
        try accountStore.finishRemoval(plan)
    }

    func clearAllSessionData() async throws {
        try await activityController.clearAllSessionData()
    }

    func refreshEnabledAccounts() async {
        await activityController.refreshEnabledAccounts()
    }
}
