import Foundation
import Security
import XCTest
@testable import AgentLimitsiOS

final class MobileAccountStoreTests: XCTestCase {
    @MainActor
    func testFreshStoreCreatesOneStableAccountPerProvider() {
        withDefaults { defaults in
            var credentialPurgeCount = 0
            let store = MobileAccountStore(
                defaults: defaults,
                now: { Date(timeIntervalSince1970: 1_000) },
                purgeOrphanedCredentials: {
                    credentialPurgeCount += 1
                }
            )

            XCTAssertEqual(credentialPurgeCount, 1)
            XCTAssertEqual(store.accounts.count, MobileProvider.allCases.count)
            for provider in MobileProvider.allCases {
                XCTAssertEqual(store.accounts(for: provider).count, 1)
            }

            let reloaded = MobileAccountStore(defaults: defaults)
            XCTAssertEqual(reloaded.accounts, store.accounts)
        }
    }

    @MainActor
    func testFreshStoreFailsClosedWhenCredentialPurgeFails() throws {
        try withDefaults { defaults in
            let store = MobileAccountStore(
                defaults: defaults,
                purgeOrphanedCredentials: {
                    throw TestLifecycleError.credentialPurge
                }
            )

            XCTAssertEqual(
                store.recoveryFailure,
                .orphanedCredentialCleanupFailed
            )
            XCTAssertFalse(store.canMutate)
            XCTAssertNil(
                defaults.object(forKey: MobileAccountStore.persistenceKey)
            )
            XCTAssertThrowsError(
                try store.addAccount(provider: .copilot, label: "Blocked")
            )
        }
    }

    @MainActor
    func testSameProviderAccountsPersistAndUpdateIndependently() throws {
        try withDefaults { defaults in
            let store = MobileAccountStore(defaults: defaults)
            let primary = try XCTUnwrap(store.accounts(for: .copilot).first)
            let work = try store.addAccount(provider: .copilot, label: "Work")
            _ = try store.updateAccount(
                id: primary.id,
                label: "Personal",
                isEnabled: false
            )

            let reloaded = MobileAccountStore(defaults: defaults)
            XCTAssertEqual(reloaded.accounts(for: .copilot).count, 2)
            XCTAssertEqual(reloaded.account(id: primary.id)?.label, "Personal")
            XCTAssertEqual(reloaded.account(id: primary.id)?.isEnabled, false)
            XCTAssertEqual(reloaded.account(id: work.id)?.label, "Work")
            XCTAssertEqual(reloaded.account(id: work.id)?.isEnabled, true)
        }
    }

    @MainActor
    func testUnicodeLabelsFitPersistenceAndWatchTransportBudgets() throws {
        try withDefaults { defaults in
            let family = "👨‍👩‍👧‍👦"
            let oversizedLabel = String(
                repeating: family,
                count: MobileProviderAccount.maximumLabelLength
            )
            let store = MobileAccountStore(defaults: defaults)
            let account = try store.addAccount(
                provider: .copilot,
                label: oversizedLabel
            )

            XCTAssertFalse(account.label.isEmpty)
            XCTAssertLessThanOrEqual(
                account.label.count,
                MobileProviderAccount.maximumLabelLength
            )
            XCTAssertLessThanOrEqual(
                account.label.utf8.count,
                MobileProviderAccount.maximumLabelUTF8Bytes
            )
            XCTAssertEqual(
                MobileProviderAccount.maximumLabelUTF8Bytes,
                WatchCompanionAccountStatus.maximumLabelUTF8Bytes
            )
            XCTAssertNoThrow(
                try WatchCompanionAccountStatus(
                    id: account.id,
                    provider: .copilot,
                    label: account.label,
                    isEnabled: true,
                    availability: .unsupported,
                    working: nil,
                    waiting: nil,
                    open: nil,
                    observedAt: nil,
                    retryAt: nil
                )
            )

            let reloaded = MobileAccountStore(defaults: defaults)
            XCTAssertEqual(reloaded.account(id: account.id), account)
        }
    }

    func testSingleOversizedGraphemeFallsBackToProviderName() {
        let oversizedGrapheme = "a" + String(
            repeating: "\u{301}",
            count: MobileProviderAccount.maximumLabelUTF8Bytes
        )
        XCTAssertEqual(oversizedGrapheme.count, 1)

        let account = MobileProviderAccount(
            provider: .copilot,
            label: oversizedGrapheme
        )

        XCTAssertEqual(account.label, MobileProvider.copilot.displayName)
    }

    @MainActor
    func testRemovalKeepsAtLeastOneAccountPerProvider() throws {
        try withDefaults { defaults in
            let store = MobileAccountStore(defaults: defaults)
            let primary = try XCTUnwrap(store.accounts(for: .codex).first)

            XCTAssertThrowsError(try store.removeAccount(id: primary.id)) {
                XCTAssertEqual(
                    $0 as? MobileAccountStoreError,
                    .cannotRemoveLastAccount(.codex)
                )
            }

            let second = try store.addAccount(provider: .codex, label: "Work")
            try store.removeAccount(id: second.id)
            XCTAssertEqual(store.accounts(for: .codex), [primary])
        }
    }

    @MainActor
    func testCorruptAndOversizedPayloadsRecoverToBoundedDefaults() {
        for object in ["wrong-type" as Any, Data(repeating: 0x61, count: 524_289)] {
            withDefaults { defaults in
                defaults.set(object, forKey: MobileAccountStore.persistenceKey)
                var credentialPurgeCount = 0

                let store = MobileAccountStore(
                    defaults: defaults,
                    purgeOrphanedCredentials: {
                        credentialPurgeCount += 1
                    }
                )

                XCTAssertTrue(store.didRecoverCorruptData)
                XCTAssertEqual(credentialPurgeCount, 1)
                XCTAssertEqual(store.accounts.count, MobileProvider.allCases.count)
                XCTAssertLessThan(
                    defaults.data(forKey: MobileAccountStore.persistenceKey)?.count
                        ?? .max,
                    524_289
                )
            }
        }
    }

    @MainActor
    func testCorruptPayloadStaysPendingWhenCredentialPurgeFails() throws {
        try withDefaults { defaults in
            let corruptData = Data("not-json".utf8)
            defaults.set(
                corruptData,
                forKey: MobileAccountStore.persistenceKey
            )

            let store = MobileAccountStore(
                defaults: defaults,
                purgeOrphanedCredentials: {
                    throw TestLifecycleError.credentialPurge
                }
            )

            XCTAssertTrue(store.didRecoverCorruptData)
            XCTAssertEqual(
                store.recoveryFailure,
                .orphanedCredentialCleanupFailed
            )
            XCTAssertFalse(store.canMutate)
            XCTAssertEqual(
                defaults.data(forKey: MobileAccountStore.persistenceKey),
                corruptData
            )
            XCTAssertThrowsError(
                try store.addAccount(provider: .copilot, label: "Blocked")
            ) {
                XCTAssertEqual(
                    $0 as? MobileAccountStoreError,
                    .orphanedCredentialCleanupFailed
                )
            }
        }
    }

    @MainActor
    func testNewerPayloadIsPreservedAndReadOnly() throws {
        try withDefaults { defaults in
            let original = try JSONEncoder().encode(
                TestPayload(version: 2, accounts: [])
            )
            defaults.set(original, forKey: MobileAccountStore.persistenceKey)

            let store = MobileAccountStore(defaults: defaults)

            XCTAssertEqual(store.unsupportedStoredVersion, 2)
            XCTAssertFalse(store.canMutate)
            XCTAssertEqual(
                defaults.data(forKey: MobileAccountStore.persistenceKey),
                original
            )
            XCTAssertThrowsError(
                try store.addAccount(provider: .copilot, label: "Blocked")
            ) {
                XCTAssertEqual(
                    $0 as? MobileAccountStoreError,
                    .unsupportedVersion(2)
                )
            }
        }
    }

    @MainActor
    func testAccountCountIsBoundedPerProvider() throws {
        try withDefaults { defaults in
            let store = MobileAccountStore(defaults: defaults)
            for index in 1..<MobileAccountStore.maximumAccountsPerProvider {
                _ = try store.addAccount(
                    provider: .claude,
                    label: "Account \(index)"
                )
            }

            XCTAssertEqual(
                store.accounts(for: .claude).count,
                MobileAccountStore.maximumAccountsPerProvider
            )
            XCTAssertThrowsError(
                try store.addAccount(provider: .claude, label: "Overflow")
            ) {
                XCTAssertEqual(
                    $0 as? MobileAccountStoreError,
                    .tooManyAccounts(.claude)
                )
            }
        }
    }

    @MainActor
    func testRemovalPersistenceFailureLeavesCredentialAndAccountReachable()
        throws {
        try withDefaults { defaults in
            var failPersistence = false
            let store = MobileAccountStore(
                defaults: defaults,
                persistenceWriter: { data, key, defaults in
                    guard !failPersistence else { return false }
                    defaults.set(data, forKey: key)
                    return defaults.data(forKey: key) == data
                }
            )
            let work = try store.addAccount(
                provider: .copilot,
                label: "Work"
            )
            let credentials = LifecycleCredentialStore()
            credentials.values[work.id] = "work-token"
            let model = MobileAppModel(
                accountStore: store,
                credentialStore: credentials,
                fetcher: LifecycleNoopFetcher()
            )
            failPersistence = true

            XCTAssertThrowsError(try model.removeAccount(id: work.id)) {
                XCTAssertEqual(
                    $0 as? MobileAccountStoreError,
                    .persistenceFailed
                )
            }
            XCTAssertNotNil(store.account(id: work.id))
            XCTAssertEqual(credentials.values[work.id], "work-token")
            XCTAssertTrue(credentials.deletedAccountIDs.isEmpty)
        }
    }

    @MainActor
    func testCredentialDeletionFailureRestoresPersistedAccount() throws {
        try withDefaults { defaults in
            let store = MobileAccountStore(defaults: defaults)
            let work = try store.addAccount(
                provider: .copilot,
                label: "Work"
            )
            let credentials = LifecycleCredentialStore()
            credentials.values[work.id] = "work-token"
            credentials.failAccountDeletion = true
            let model = MobileAppModel(
                accountStore: store,
                credentialStore: credentials,
                fetcher: LifecycleNoopFetcher()
            )

            XCTAssertThrowsError(try model.removeAccount(id: work.id)) {
                XCTAssertEqual(
                    $0 as? MobileSessionCredentialStoreError,
                    .keychain(errSecInteractionNotAllowed)
                )
            }
            XCTAssertNotNil(store.account(id: work.id))
            XCTAssertNotNil(
                MobileAccountStore(defaults: defaults).account(id: work.id)
            )
            XCTAssertEqual(credentials.values[work.id], "work-token")
            XCTAssertEqual(credentials.deletedAccountIDs, [work.id])
        }
    }

    @MainActor
    func testPendingRemovalReconcilesOnlyItsCredentialAfterRestart()
        throws {
        try withDefaults { defaults in
            let store = MobileAccountStore(defaults: defaults)
            let primary = try XCTUnwrap(
                store.accounts(for: .copilot).first
            )
            let work = try store.addAccount(
                provider: .copilot,
                label: "Work"
            )
            let plan = try store.prepareRemoval(id: work.id)
            try store.beginRemoval(plan)

            XCTAssertNil(store.account(id: work.id))
            XCTAssertEqual(
                store.pendingCredentialDeletionIDs,
                Set([work.id])
            )

            let credentials = LifecycleCredentialStore()
            credentials.values[primary.id] = "personal-token"
            credentials.values[work.id] = "work-token"
            let recovered = MobileAccountStore(
                defaults: defaults,
                deleteCredential: { accountID in
                    try credentials.deleteCredential(for: accountID)
                }
            )

            XCTAssertNil(recovered.account(id: work.id))
            XCTAssertTrue(recovered.pendingCredentialDeletionIDs.isEmpty)
            XCTAssertEqual(credentials.values[primary.id], "personal-token")
            XCTAssertNil(credentials.values[work.id])
            XCTAssertEqual(credentials.deletedAccountIDs, [work.id])

            let verified = MobileAccountStore(defaults: defaults)
            XCTAssertTrue(verified.pendingCredentialDeletionIDs.isEmpty)
        }
    }

    @MainActor
    func testPendingRemovalFailureRemainsDurableAndBlocksMutation()
        throws {
        try withDefaults { defaults in
            let store = MobileAccountStore(defaults: defaults)
            let work = try store.addAccount(
                provider: .copilot,
                label: "Work"
            )
            let plan = try store.prepareRemoval(id: work.id)
            try store.beginRemoval(plan)

            let failed = MobileAccountStore(
                defaults: defaults,
                deleteCredential: { _ in
                    throw TestLifecycleError.credentialPurge
                }
            )

            XCTAssertEqual(
                failed.recoveryFailure,
                .orphanedCredentialCleanupFailed
            )
            XCTAssertEqual(
                failed.pendingCredentialDeletionIDs,
                Set([work.id])
            )
            XCTAssertThrowsError(
                try failed.addAccount(provider: .copilot, label: "Blocked")
            )

            var retriedIDs: [UUID] = []
            let retried = MobileAccountStore(
                defaults: defaults,
                deleteCredential: { retriedIDs.append($0) }
            )
            XCTAssertEqual(retriedIDs, [work.id])
            XCTAssertTrue(retried.pendingCredentialDeletionIDs.isEmpty)
        }
    }

    @MainActor
    func testOversizedPendingRemovalListPurgesAllCredentials() throws {
        try withDefaults { defaults in
            let initial = MobileAccountStore(defaults: defaults)
            let oversizedPending = (0...(
                MobileProvider.allCases.count
                    * MobileAccountStore.maximumAccountsPerProvider
            )).map { _ in UUID() }
            defaults.set(
                try JSONEncoder().encode(
                    TestPayload(
                        version: 1,
                        accounts: initial.accounts,
                        pendingCredentialDeletionIDs: oversizedPending
                    )
                ),
                forKey: MobileAccountStore.persistenceKey
            )
            var purgeCount = 0

            let recovered = MobileAccountStore(
                defaults: defaults,
                purgeOrphanedCredentials: { purgeCount += 1 }
            )

            XCTAssertTrue(recovered.didRecoverCorruptData)
            XCTAssertEqual(purgeCount, 1)
            XCTAssertTrue(recovered.pendingCredentialDeletionIDs.isEmpty)
            XCTAssertEqual(recovered.accounts, initial.accounts)
            XCTAssertTrue(recovered.canMutate)
        }
    }

    @MainActor
    func testSanitizedIdentityRepairPurgesUnreachableCredentials()
        throws {
        try withDefaults { defaults in
            let duplicateID = UUID()
            let damaged = [
                MobileProviderAccount(
                    id: duplicateID,
                    provider: .codex,
                    label: "One"
                ),
                MobileProviderAccount(
                    id: duplicateID,
                    provider: .copilot,
                    label: "Two"
                )
            ]
            defaults.set(
                try JSONEncoder().encode(
                    TestPayload(version: 1, accounts: damaged)
                ),
                forKey: MobileAccountStore.persistenceKey
            )
            var purgeCount = 0

            let recovered = MobileAccountStore(
                defaults: defaults,
                purgeOrphanedCredentials: { purgeCount += 1 }
            )

            XCTAssertTrue(recovered.didRecoverCorruptData)
            XCTAssertEqual(purgeCount, 1)
            XCTAssertTrue(recovered.canMutate)
            XCTAssertEqual(
                Set(recovered.accounts.map(\.id)).count,
                recovered.accounts.count
            )
        }
    }

    private struct TestPayload: Codable {
        let version: Int
        let accounts: [MobileProviderAccount]
        var pendingCredentialDeletionIDs: [UUID]?

        init(
            version: Int,
            accounts: [MobileProviderAccount],
            pendingCredentialDeletionIDs: [UUID]? = nil
        ) {
            self.version = version
            self.accounts = accounts
            self.pendingCredentialDeletionIDs = pendingCredentialDeletionIDs
        }
    }

    private func withDefaults(
        _ body: (UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "MobileAccountStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }
}

private enum TestLifecycleError: Error {
    case credentialPurge
}

@MainActor
private final class LifecycleCredentialStore:
    MobileSessionCredentialStoring {
    var values: [UUID: String] = [:]
    var failAccountDeletion = false
    private(set) var deletedAccountIDs: [UUID] = []

    func credential(for accountID: UUID) throws -> String? {
        values[accountID]
    }

    func saveCredential(_ credential: String, for accountID: UUID) throws {
        values[accountID] = credential
    }

    func deleteCredential(for accountID: UUID) throws {
        deletedAccountIDs.append(accountID)
        if failAccountDeletion {
            throw MobileSessionCredentialStoreError.keychain(
                errSecInteractionNotAllowed
            )
        }
        values.removeValue(forKey: accountID)
    }

    func deleteAllCredentials() throws {
        values.removeAll()
    }
}

private struct LifecycleNoopFetcher: GitHubAgentTaskFetching {
    func fetchCurrentActivity(
        credential: String
    ) async throws -> SessionActivityCounts {
        SessionActivityCounts(working: 0, waiting: 0)
    }
}
