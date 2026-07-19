import Combine
import Foundation
import WebKit
import XCTest
@testable import AgentLimits

@MainActor
final class ProviderAccountRemovalLifecycleTests: XCTestCase {
    func testLocalRetirementPreflightRunsBeforeSelectionMutation()
        async throws {
        let fixture = makeFixture()
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
        }
        let target = fixture.store.primaryAccount(for: .chatgptCodex)
        _ = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Replacement"
        )
        let localRemover = RecordingLocalDataRemover()
        localRemover.prepareError = .localData
        localRemover.onPrepare = { account in
            XCTAssertEqual(account.id, target.id)
            XCTAssertEqual(
                fixture.store.selectedAccount(for: .chatgptCodex).id,
                target.id
            )
        }
        let pool = makePool(accountStore: fixture.store)
        let manager = makeManager(
            accountStore: fixture.store,
            pool: pool,
            localRemover: localRemover,
            staticRemover: RecordingIdentifiedDataStoreRemover()
        )

        do {
            _ = try await manager.removeAccount(id: target.id)
            XCTFail("Expected retirement preflight to fail")
        } catch {
            XCTAssertEqual(error as? LifecycleTestError, .localData)
        }

        XCTAssertEqual(localRemover.preparedAccountIDs, [target.id])
        XCTAssertTrue(localRemover.removedAccountIDs.isEmpty)
        XCTAssertEqual(fixture.store.account(id: target.id), target)
        XCTAssertEqual(
            fixture.store.selectedAccount(for: .chatgptCodex).id,
            target.id
        )
    }

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
            websiteDataClearer: clearer,
            providers: UsageProvider.allCases
        )
        let targetStore = pool.getWebViewStore(for: target)
        let claudeStore = pool.getWebViewStore(
            for: fixture.store.primaryAccount(for: .claudeCode)
        )
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

        XCTAssertEqual(
            clearer.dataStoreIdentifiers,
            [ObjectIdentifier(targetStore.websiteDataStore)]
        )
        XCTAssertTrue(staticRemover.removalCalls.isEmpty)
        XCTAssertEqual(fixture.store.account(id: target.id), target)
        XCTAssertFalse(targetStore.isRetirementInProgress)
        XCTAssertFalse(targetStore.isDataClearInProgress)
        XCTAssertFalse(targetStore.isRetired)
        XCTAssertFalse(claudeStore.isDataClearInProgress)

        let clearToken = try XCTUnwrap(pool.beginDataClear())
        XCTAssertTrue(pool.cancelDataClear(clearToken))
    }

    func testActivityRetirementFailureCancelsBeforeRegistryCommit()
        async throws {
        let fixture = makeFixture()
        defer {
            fixture.defaults.removePersistentDomain(
                forName: fixture.suiteName
            )
        }
        let target = try fixture.store.addAccount(
            provider: .githubCopilot,
            label: "Work"
        )
        let localRemover = RecordingLocalDataRemover()
        let activityRetirer = RecordingActivityDataRetirer(
            error: .activityData
        )
        activityRetirer.onRetire = { account in
            XCTAssertEqual(localRemover.removedAccountIDs, [account.id])
            XCTAssertEqual(fixture.store.account(id: account.id), account)
        }
        let staticRemover = RecordingIdentifiedDataStoreRemover()
        let pool = makePool(
            accountStore: fixture.store,
            providers: [.githubCopilot]
        )
        let targetStore = pool.getWebViewStore(for: target)
        let manager = makeManager(
            accountStore: fixture.store,
            pool: pool,
            localRemover: localRemover,
            activityRetirer: activityRetirer,
            staticRemover: staticRemover
        )

        do {
            _ = try await manager.removeAccount(id: target.id)
            XCTFail("Expected activity-data retirement to fail")
        } catch {
            XCTAssertEqual(error as? LifecycleTestError, .activityData)
        }

        XCTAssertEqual(activityRetirer.retiredAccountIDs, [target.id])
        XCTAssertEqual(fixture.store.account(id: target.id), target)
        XCTAssertTrue(
            fixture.store.pendingWebKitDataStoreDeletionIDs.isEmpty
        )
        XCTAssertTrue(staticRemover.removalCalls.isEmpty)
        XCTAssertFalse(targetStore.isRetirementInProgress)
        XCTAssertFalse(targetStore.isDataClearInProgress)
        XCTAssertFalse(targetStore.isRetired)
        XCTAssertTrue(pool.getWebViewStore(for: target) === targetStore)
    }

    func testLegacyWebsiteDataCleanupFailureRestoresWholePool() async throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let target = fixture.store.primaryAccount(for: .chatgptCodex)
        let expectedLegacyAccountIDs = Set(
            fixture.store.loadAccounts()
                .filter { $0.webKitStorage == .legacyDefault }
                .map(\.id)
        )
        let replacement = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Replacement"
        )
        let clearer = RecordingLifecycleWebsiteDataClearer(
            error: .websiteData
        )
        let localRemover = RecordingLocalDataRemover()
        let staticRemover = RecordingIdentifiedDataStoreRemover()
        let pool = makePool(
            accountStore: fixture.store,
            websiteDataClearer: clearer
        )
        let targetStore = pool.getWebViewStore(for: target)
        let replacementStore = pool.getWebViewStore(for: replacement)
        let manager = makeManager(
            accountStore: fixture.store,
            pool: pool,
            localRemover: localRemover,
            staticRemover: staticRemover
        )

        do {
            _ = try await manager.removeAccount(id: target.id)
            XCTFail("Expected website-data deletion to fail")
        } catch {
            XCTAssertEqual(error as? LifecycleTestError, .websiteData)
        }

        let legacyStores = pool.webViewStores.filter {
            $0.account.webKitStorage == .legacyDefault
        }
        XCTAssertEqual(
            Set(legacyStores.map { $0.account.id }),
            expectedLegacyAccountIDs
        )
        XCTAssertTrue(
            legacyStores.allSatisfy { !$0.isDataClearInProgress }
        )
        XCTAssertEqual(
            clearer.dataStoreIdentifiers,
            [ObjectIdentifier(targetStore.websiteDataStore)]
        )
        XCTAssertTrue(localRemover.removedAccountIDs.isEmpty)
        XCTAssertTrue(staticRemover.removalCalls.isEmpty)
        XCTAssertEqual(fixture.store.account(id: target.id), target)
        XCTAssertFalse(replacementStore.isDataClearInProgress)

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
        let activityRetirer = RecordingActivityDataRetirer()
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
            activityRetirer: activityRetirer,
            staticRemover: staticRemover
        )

        let outcome = try await manager.removeAccount(id: target.id)

        XCTAssertEqual(outcome, .removedWithPendingCleanup)
        XCTAssertEqual(localRemover.removedAccountIDs, [target.id])
        XCTAssertEqual(activityRetirer.retiredAccountIDs, [target.id])
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
        let legacySiblingAccountIDs = Set(
            fixture.store.loadAccounts()
                .filter {
                    $0.webKitStorage == .legacyDefault && $0.id != target.id
                }
                .map(\.id)
        )
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
        let targetStore = pool.getWebViewStore(for: target)
        let replacementStore = pool.getWebViewStore(for: replacement)
        var legacySiblingStores: [WebViewStore] = []
        localRemover.onRemove = { _ in
            XCTAssertTrue(targetStore.isDataClearInProgress)
            legacySiblingStores = pool.webViewStores.filter {
                $0.account.webKitStorage == .legacyDefault
            }
            XCTAssertEqual(
                Set(legacySiblingStores.map { $0.account.id }),
                legacySiblingAccountIDs
            )
            XCTAssertTrue(
                legacySiblingStores.allSatisfy(\.isDataClearInProgress)
            )
            XCTAssertFalse(replacementStore.isDataClearInProgress)
        }
        var invalidatedAccountIDs: Set<UUID> = []
        var didStartReentrantClear = false
        let invalidationObservation = pool.webViewStoreRetirementDidBegin.sink {
            invalidatedAccountIDs.insert($0)
            if pool.beginDataClear() != nil {
                didStartReentrantClear = true
            }
        }
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
        XCTAssertEqual(
            clearer.dataStoreIdentifiers,
            [ObjectIdentifier(targetStore.websiteDataStore)]
        )
        XCTAssertNotEqual(
            ObjectIdentifier(targetStore.websiteDataStore),
            ObjectIdentifier(replacementStore.websiteDataStore)
        )
        XCTAssertEqual(
            invalidatedAccountIDs,
            legacySiblingAccountIDs.union([target.id])
        )
        XCTAssertFalse(didStartReentrantClear)
        XCTAssertFalse(replacementStore.isDataClearInProgress)
        XCTAssertFalse(replacementStore.isRetired)
        XCTAssertTrue(
            legacySiblingStores.allSatisfy { !$0.isDataClearInProgress }
        )

        let clearToken = try XCTUnwrap(pool.beginDataClear())
        XCTAssertTrue(pool.cancelDataClear(clearToken))
        withExtendedLifetime(invalidationObservation) {}
    }

    func testLegacyRemovalCannotBeCancelledDuringWebsiteDataDeletion() async throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let target = fixture.store.primaryAccount(for: .chatgptCodex)
        _ = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Replacement"
        )
        let clearer = SuspendingLifecycleWebsiteDataClearer()
        let pool = makePool(
            accountStore: fixture.store,
            websiteDataClearer: clearer
        )
        let targetStore = pool.getWebViewStore(for: target)
        let plan = try fixture.store.prepareRemoval(id: target.id)
        let token = try pool.beginAccountRetirement(plan)
        let clearTask = Task {
            try await pool.quiesceAccountForRetirement(token)
        }

        await clearer.waitUntilStarted()

        let legacySiblingStores = pool.webViewStores.filter {
            $0.account.webKitStorage == .legacyDefault
        }
        XCTAssertFalse(pool.cancelAccountRetirement(token))
        XCTAssertNil(pool.beginDataClear())
        XCTAssertTrue(targetStore.isDataClearInProgress)
        XCTAssertFalse(legacySiblingStores.isEmpty)
        XCTAssertTrue(
            legacySiblingStores.allSatisfy(\.isDataClearInProgress)
        )
        for store in legacySiblingStores {
            XCTAssertFalse(
                store.shouldAllowNavigation(
                    in: store.webView,
                    to: store.account.provider.usageURL
                )
            )
        }

        clearer.finish()
        try await clearTask.value

        XCTAssertTrue(targetStore.isRetirementInProgress)
        XCTAssertTrue(pool.cancelAccountRetirement(token))
        XCTAssertFalse(targetStore.isRetirementInProgress)
        XCTAssertFalse(targetStore.isDataClearInProgress)
        XCTAssertTrue(
            legacySiblingStores.allSatisfy { !$0.isDataClearInProgress }
        )
        let clearToken = try XCTUnwrap(pool.beginDataClear())
        XCTAssertTrue(pool.cancelDataClear(clearToken))
    }

    func testLegacyRetirementCancellationNotifiesEveryInvalidatedAccount()
        throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let target = fixture.store.primaryAccount(for: .chatgptCodex)
        _ = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Replacement"
        )
        let pool = makePool(accountStore: fixture.store)
        var beganAccountIDs: [UUID] = []
        var canceledAccountIDs: [UUID] = []
        let beginObservation = pool.webViewStoreRetirementDidBegin.sink {
            beganAccountIDs.append($0)
        }
        let cancelObservation = pool.webViewStoreRetirementDidRestore.sink {
            canceledAccountIDs.append($0)
        }
        let plan = try fixture.store.prepareRemoval(id: target.id)

        let token = try pool.beginAccountRetirement(plan)
        XCTAssertTrue(pool.cancelAccountRetirement(token))

        XCTAssertGreaterThan(beganAccountIDs.count, 1)
        XCTAssertEqual(canceledAccountIDs, beganAccountIDs)
        withExtendedLifetime(beginObservation) {}
        withExtendedLifetime(cancelObservation) {}
    }

    func testRetirementReservesExclusivityBeforeStoreCreationCallbacks() throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let target = fixture.store.primaryAccount(for: .chatgptCodex)
        _ = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Replacement"
        )
        let pool = makePool(
            accountStore: fixture.store,
            providers: []
        )
        var didStartReentrantClear = false
        pool.onWebViewStoreCreated = { _ in
            if pool.beginDataClear() != nil {
                didStartReentrantClear = true
            }
        }
        let plan = try fixture.store.prepareRemoval(id: target.id)

        let token = try pool.beginAccountRetirement(plan)

        XCTAssertFalse(didStartReentrantClear)
        XCTAssertTrue(pool.cancelAccountRetirement(token))
        pool.onWebViewStoreCreated = nil
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
        onDataStoreCreation: ((ProviderAccount) -> Void)? = nil,
        providers: [UsageProvider] = [.chatgptCodex]
    ) -> UsageWebViewPool {
        UsageWebViewPool(
            providers: providers,
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
        activityRetirer: RecordingActivityDataRetirer? = nil,
        staticRemover: RecordingIdentifiedDataStoreRemover
    ) -> ProviderAccountRemovalManager {
        ProviderAccountRemovalManager(
            accountStore: accountStore,
            webViewPool: pool,
            localDataRemover: localRemover,
            activityDataRetirer: activityRetirer,
            websiteDataStoreRemover: staticRemover,
            cleanupAttempts: 1,
            cleanupRetryDelay: .milliseconds(0)
        )
    }
}

private enum LifecycleTestError: Error, Equatable {
    case localData
    case websiteData
    case activityData
}

@MainActor
private final class RecordingLocalDataRemover:
    ProviderAccountLocalDataRemoving {
    private(set) var preparedAccountIDs: [UUID] = []
    private(set) var removedAccountIDs: [UUID] = []
    var error: LifecycleTestError?
    var prepareError: LifecycleTestError?
    var onPrepare: ((ProviderAccount) -> Void)?
    var onRemove: ((ProviderAccount) -> Void)?

    init(error: LifecycleTestError? = nil) {
        self.error = error
    }

    func prepareLocalDataRetirement(
        for account: ProviderAccount
    ) throws {
        preparedAccountIDs.append(account.id)
        onPrepare?(account)
        if let prepareError {
            throw prepareError
        }
    }

    func removeLocalData(for account: ProviderAccount) throws {
        removedAccountIDs.append(account.id)
        onRemove?(account)
        if let error {
            throw error
        }
    }
}

@MainActor
private final class RecordingActivityDataRetirer:
    ProviderAccountActivityDataRetiring {
    private(set) var retiredAccountIDs: [UUID] = []
    var error: LifecycleTestError?
    var onRetire: ((ProviderAccount) -> Void)?

    init(error: LifecycleTestError? = nil) {
        self.error = error
    }

    func retireActivityData(for account: ProviderAccount) throws {
        retiredAccountIDs.append(account.id)
        onRetire?(account)
        if let error { throw error }
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
    var error: LifecycleTestError?

    init(error: LifecycleTestError? = nil) {
        self.error = error
    }

    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws {
        dataStoreIdentifiers.append(ObjectIdentifier(dataStore))
        if let error {
            throw error
        }
    }
}

@MainActor
private final class SuspendingLifecycleWebsiteDataClearer: WebsiteDataClearing {
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }
}
