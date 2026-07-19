import Combine
import Foundation
import WebKit
import XCTest
@testable import AgentLimits

@MainActor
final class ProviderAccountRemovalLifecycleTests: XCTestCase {
    func testIsolatedLocalCleanupFailureCancelsBeforeRegistryCommit() async throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let primary = fixture.store.primaryAccount(for: .chatgptCodex)
        let target = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Work"
        )
        try fixture.store.selectAccount(id: target.id)
        let localRemover = RecordingLocalDataRemover(error: .localData)
        let staticRemover = RecordingIdentifiedDataStoreRemover(
            existingIdentifiers: [target.id]
        )
        let pool = makePool(accountStore: fixture.store)
        let targetStore = pool.getWebViewStore(for: target)
        let manager = makeManager(
            accountStore: fixture.store,
            pool: pool,
            localRemover: localRemover,
            staticRemover: staticRemover
        )

        do {
            _ = try await manager.removeAccount(id: target.id)
            XCTFail("Expected local-data deletion to fail")
        } catch {
            XCTAssertEqual(error as? LifecycleTestError, .localData)
        }

        XCTAssertEqual(localRemover.removedAccountIDs, [target.id])
        XCTAssertTrue(staticRemover.removalCalls.isEmpty)
        XCTAssertEqual(fixture.store.account(id: target.id), target)
        XCTAssertTrue(fixture.store.pendingWebKitDataStoreDeletionIDs.isEmpty)
        XCTAssertEqual(
            fixture.store.selectedAccount(for: .chatgptCodex).id,
            primary.id
        )
        XCTAssertFalse(targetStore.isRetirementInProgress)
        XCTAssertFalse(targetStore.isDataClearInProgress)
        XCTAssertFalse(targetStore.isRetired)

        pool.resume(target)
        XCTAssertTrue(pool.getWebViewStore(for: target) === targetStore)
    }

    func testLegacyLocalCleanupFailureRestoresWholePool() async throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let target = fixture.store.primaryAccount(for: .chatgptCodex)
        _ = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Replacement"
        )
        let clearer = RecordingLifecycleWebsiteDataClearer()
        let localRemover = RecordingLocalDataRemover(error: .localData)
        let staticRemover = RecordingIdentifiedDataStoreRemover()
        let pool = makePool(
            accountStore: fixture.store,
            websiteDataClearer: clearer
        )
        let targetStore = pool.getWebViewStore(for: target)
        let manager = makeManager(
            accountStore: fixture.store,
            pool: pool,
            localRemover: localRemover,
            staticRemover: staticRemover
        )

        do {
            _ = try await manager.removeAccount(id: target.id)
            XCTFail("Expected local-data deletion to fail")
        } catch {
            XCTAssertEqual(error as? LifecycleTestError, .localData)
        }

        XCTAssertEqual(clearer.dataStoreIdentifiers.count, 2)
        XCTAssertEqual(Set(clearer.dataStoreIdentifiers).count, 2)
        XCTAssertTrue(staticRemover.removalCalls.isEmpty)
        XCTAssertEqual(fixture.store.account(id: target.id), target)
        XCTAssertFalse(targetStore.isRetirementInProgress)
        XCTAssertFalse(targetStore.isDataClearInProgress)
        XCTAssertFalse(targetStore.isRetired)

        let clearToken = try XCTUnwrap(pool.beginDataClear())
        XCTAssertTrue(pool.cancelDataClear(clearToken))
    }

    func testStaticRemovalFailureLeavesTombstoneAndRelaunchDrainRetries() async throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let target = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Work"
        )
        let localRemover = RecordingLocalDataRemover()
        let staticRemover = RecordingIdentifiedDataStoreRemover(
            existingIdentifiers: [target.id],
            removalError: .websiteData
        )
        var createdAccountIDs: [UUID] = []
        let pool = makePool(
            accountStore: fixture.store,
            onDataStoreCreation: { createdAccountIDs.append($0.id) }
        )
        let targetStore = pool.getWebViewStore(for: target)
        targetStore.onPopupNavigationFinished = { _ in true }
        var retiredAccountIDs: [UUID] = []
        let retirementObservation = pool.webViewStoreWillRetire.sink {
            retiredAccountIDs.append($0)
        }
        let manager = makeManager(
            accountStore: fixture.store,
            pool: pool,
            localRemover: localRemover,
            staticRemover: staticRemover
        )

        let outcome = try await manager.removeAccount(id: target.id)

        XCTAssertEqual(outcome, .removedWithPendingCleanup)
        XCTAssertEqual(localRemover.removedAccountIDs, [target.id])
        XCTAssertEqual(staticRemover.removalCalls, [target.id])
        XCTAssertEqual(retiredAccountIDs, [target.id])
        XCTAssertNil(fixture.store.account(id: target.id))
        XCTAssertEqual(
            fixture.store.pendingWebKitDataStoreDeletionIDs,
            [target.id]
        )
        XCTAssertTrue(targetStore.isRetired)
        XCTAssertFalse(targetStore.isRetirementInProgress)
        XCTAssertFalse(targetStore.isDataClearInProgress)
        XCTAssertNil(targetStore.webView.navigationDelegate)
        XCTAssertNil(targetStore.webView.uiDelegate)
        XCTAssertNil(targetStore.onPopupNavigationFinished)
        XCTAssertFalse(
            targetStore.shouldAllowNavigation(
                in: targetStore.webView,
                to: target.provider.usageURL
            )
        )

        let creationCountAfterRemoval = createdAccountIDs.count
        pool.resume(target)
        pool.reloadFromOrigin(target)
        XCTAssertEqual(createdAccountIDs.count, creationCountAfterRemoval)

        let reloadedStore = ProviderAccountStore(
            userDefaults: fixture.defaults,
            key: Self.accountKey
        )
        var relaunchedAccountIDs: [UUID] = []
        let relaunchedPool = makePool(
            accountStore: reloadedStore,
            onDataStoreCreation: { relaunchedAccountIDs.append($0.id) }
        )
        relaunchedPool.resume(target)
        relaunchedPool.reloadFromOrigin(target)
        XCTAssertFalse(relaunchedAccountIDs.contains(target.id))

        staticRemover.removalError = nil
        let relaunchedManager = makeManager(
            accountStore: reloadedStore,
            pool: relaunchedPool,
            localRemover: localRemover,
            staticRemover: staticRemover
        )
        let remaining = await relaunchedManager
            .drainPendingWebKitDataStoreDeletions()

        XCTAssertTrue(remaining.isEmpty)
        XCTAssertTrue(reloadedStore.pendingWebKitDataStoreDeletionIDs.isEmpty)
        XCTAssertEqual(staticRemover.removalCalls, [target.id, target.id])
        withExtendedLifetime(retirementObservation) {}
    }

    func testLegacyRemovalClearsSharedStoresWithoutStaticDeletion() async throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let target = fixture.store.primaryAccount(for: .chatgptCodex)
        let replacement = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Replacement"
        )
        let clearer = RecordingLifecycleWebsiteDataClearer()
        let localRemover = RecordingLocalDataRemover()
        let staticRemover = RecordingIdentifiedDataStoreRemover(
            existingIdentifiers: [replacement.id]
        )
        let pool = makePool(
            accountStore: fixture.store,
            websiteDataClearer: clearer
        )
        let replacementStore = pool.getWebViewStore(for: replacement)
        let manager = makeManager(
            accountStore: fixture.store,
            pool: pool,
            localRemover: localRemover,
            staticRemover: staticRemover
        )

        let outcome = try await manager.removeAccount(id: target.id)

        XCTAssertEqual(outcome, .removed)
        XCTAssertNil(fixture.store.account(id: target.id))
        XCTAssertEqual(
            fixture.store.selectedAccount(for: .chatgptCodex).id,
            replacement.id
        )
        XCTAssertTrue(fixture.store.pendingWebKitDataStoreDeletionIDs.isEmpty)
        XCTAssertEqual(localRemover.removedAccountIDs, [target.id])
        XCTAssertTrue(staticRemover.removalCalls.isEmpty)
        XCTAssertEqual(clearer.dataStoreIdentifiers.count, 2)
        XCTAssertEqual(Set(clearer.dataStoreIdentifiers).count, 2)
        XCTAssertFalse(replacementStore.isDataClearInProgress)
        XCTAssertFalse(replacementStore.isRetired)

        let clearToken = try XCTUnwrap(pool.beginDataClear())
        XCTAssertTrue(pool.cancelDataClear(clearToken))
    }

    private static let accountKey = "test_accounts"

    private func makeFixture() -> (
        store: ProviderAccountStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "ProviderAccountRemovalLifecycleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            ProviderAccountStore(
                userDefaults: defaults,
                key: Self.accountKey
            ),
            defaults,
            suiteName
        )
    }

    private func makePool(
        accountStore: ProviderAccountStore,
        websiteDataClearer: (any WebsiteDataClearing)? = nil,
        onDataStoreCreation: ((ProviderAccount) -> Void)? = nil
    ) -> UsageWebViewPool {
        UsageWebViewPool(
            providers: [.chatgptCodex],
            accountStore: accountStore,
            websiteDataClearer: websiteDataClearer,
            websiteDataStoreProvider: { account in
                onDataStoreCreation?(account)
                return .nonPersistent()
            },
            quiescenceTimeout: .seconds(2)
        )
    }

    private func makeManager(
        accountStore: ProviderAccountStore,
        pool: UsageWebViewPool,
        localRemover: RecordingLocalDataRemover,
        staticRemover: RecordingIdentifiedDataStoreRemover
    ) -> ProviderAccountRemovalManager {
        ProviderAccountRemovalManager(
            accountStore: accountStore,
            webViewPool: pool,
            localDataRemover: localRemover,
            websiteDataStoreRemover: staticRemover,
            cleanupAttempts: 1,
            cleanupRetryDelay: .milliseconds(0)
        )
    }
}

private enum LifecycleTestError: Error, Equatable {
    case localData
    case websiteData
}

@MainActor
private final class RecordingLocalDataRemover:
    ProviderAccountLocalDataRemoving {
    private(set) var removedAccountIDs: [UUID] = []
    var error: LifecycleTestError?

    init(error: LifecycleTestError? = nil) {
        self.error = error
    }

    func removeLocalData(for account: ProviderAccount) throws {
        removedAccountIDs.append(account.id)
        if let error {
            throw error
        }
    }
}

@MainActor
private final class RecordingIdentifiedDataStoreRemover:
    IdentifiedWebsiteDataStoreRemoving {
    private(set) var existingIdentifiers: Set<UUID>
    private(set) var containsCalls: [UUID] = []
    private(set) var removalCalls: [UUID] = []
    var removalError: LifecycleTestError?

    init(
        existingIdentifiers: Set<UUID> = [],
        removalError: LifecycleTestError? = nil
    ) {
        self.existingIdentifiers = existingIdentifiers
        self.removalError = removalError
    }

    func containsDataStore(for identifier: UUID) async -> Bool {
        containsCalls.append(identifier)
        return existingIdentifiers.contains(identifier)
    }

    func removeDataStore(for identifier: UUID) async throws {
        removalCalls.append(identifier)
        if let removalError {
            throw removalError
        }
        existingIdentifiers.remove(identifier)
    }
}

@MainActor
private final class RecordingLifecycleWebsiteDataClearer: WebsiteDataClearing {
    private(set) var dataStoreIdentifiers: [ObjectIdentifier] = []

    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws {
        dataStoreIdentifiers.append(ObjectIdentifier(dataStore))
    }
}
