import Foundation
import WebKit
import XCTest
@testable import AgentLimits

@MainActor
final class AccountWebKitIsolationTests: XCTestCase {
    func testSameProviderAccountsUseStableDistinctWebViewAndDataStores() async throws {
        let fixture = makeAccountStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let personal = fixture.store.selectedAccount(for: .chatgptCodex)
        let work = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Work"
        )
        registerDataStoreCleanup(work.id)
        var pool: UsageWebViewPool? = UsageWebViewPool(
            providers: [.chatgptCodex],
            accountStore: fixture.store
        )
        var personalStore: WebViewStore? = pool?.getWebViewStore(for: personal)
        var workStore: WebViewStore? = pool?.getWebViewStore(for: work)

        XCTAssertTrue(personalStore === pool?.getWebViewStore(for: personal))
        XCTAssertTrue(workStore === pool?.getWebViewStore(for: work))
        XCTAssertFalse(personalStore === workStore)
        XCTAssertFalse(personalStore?.webView === workStore?.webView)
        XCTAssertTrue(personalStore?.websiteDataStore === WKWebsiteDataStore.default())
        XCTAssertNil(personalStore?.websiteDataStore.identifier)
        XCTAssertEqual(workStore?.websiteDataStore.identifier, work.id)
        XCTAssertEqual(workStore?.webView.configuration.websiteDataStore.identifier, work.id)
        var popupConfiguration: WKWebViewConfiguration? = WKWebViewConfiguration()
        if let popupConfiguration {
            workStore?.configurePopup(popupConfiguration)
            XCTAssertEqual(popupConfiguration.websiteDataStore.identifier, work.id)
        }
        try fixture.store.selectAccount(id: work.id)
        XCTAssertTrue(workStore === pool?.getWebViewStore(for: .chatgptCodex))

        personalStore = nil
        workStore = nil
        popupConfiguration = nil
        pool = nil
        await waitForWebKitRelease()
        await removeDataStore(work.id)
    }

    func testSwitchingForegroundAccountSuspendsSameProviderSibling() throws {
        let fixture = makeAccountStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let personal = fixture.store.selectedAccount(for: .chatgptCodex)
        let work = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Work"
        )
        let pool = UsageWebViewPool(
            providers: [.chatgptCodex],
            accountStore: fixture.store,
            websiteDataStoreProvider: { _ in .nonPersistent() }
        )
        let personalStore = pool.getWebViewStore(for: personal)
        let workStore = pool.getWebViewStore(for: work)

        pool.resume(personal)
        XCTAssertFalse(personalStore.isSuspended)
        XCTAssertTrue(workStore.isSuspended)

        pool.resume(work)
        XCTAssertTrue(personalStore.isSuspended)
        XCTAssertFalse(workStore.isSuspended)
    }

    func testUnsupportedFutureRegistryUsesOnlyEphemeralWebSessions() {
        let suiteName = "AccountWebKitIsolationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            Data(#"{"version":99,"accounts":[]}"#.utf8),
            forKey: "test_accounts"
        )
        let accountStore = ProviderAccountStore(
            userDefaults: defaults,
            key: "test_accounts"
        )
        XCTAssertFalse(accountStore.supportsPersistentWebSessions)

        let pool = UsageWebViewPool(accountStore: accountStore)
        let dataStores = pool.webViewStores.map(\.websiteDataStore)

        XCTAssertEqual(dataStores.count, UsageProvider.allCases.count)
        XCTAssertEqual(Set(dataStores.map(ObjectIdentifier.init)).count, dataStores.count)
        XCTAssertTrue(dataStores.allSatisfy { !$0.isPersistent })
        XCTAssertTrue(dataStores.allSatisfy { $0.identifier == nil })
    }

    func testGlobalClearTargetsDefaultOnceAndEveryIsolatedAccount() async throws {
        let fixture = makeAccountStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let codexWork = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Codex Work"
        )
        let claudeWork = try fixture.store.addAccount(
            provider: .claudeCode,
            label: "Claude Work"
        )
        registerDataStoreCleanup(codexWork.id)
        registerDataStoreCleanup(claudeWork.id)
        let clearer = RecordingAccountWebsiteDataClearer()
        var pool: UsageWebViewPool? = UsageWebViewPool(
            accountStore: fixture.store,
            websiteDataClearer: clearer
        )
        let token = try XCTUnwrap(pool?.beginDataClear())

        try await pool?.clearWebsiteData(token)

        XCTAssertEqual(clearer.identifiers.count, 3)
        XCTAssertEqual(clearer.identifiers.filter { $0 == nil }.count, 1)
        XCTAssertEqual(
            Set(clearer.identifiers.compactMap { $0 }),
            [codexWork.id, claudeWork.id]
        )
        XCTAssertTrue(pool?.finishDataClear(token) == true)

        pool = nil
        await waitForWebKitRelease()
        await removeDataStore(codexWork.id)
        await removeDataStore(claudeWork.id)
    }

    func testAccountAddedDuringClearIsBlockedQuiescedAndCleared() async throws {
        let fixture = makeAccountStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let clearer = FirstCallSuspendingAccountWebsiteDataClearer()
        var pool: UsageWebViewPool? = UsageWebViewPool(
            accountStore: fixture.store,
            websiteDataClearer: clearer
        )
        var addedID: UUID?
        do {
            let token = try XCTUnwrap(pool?.beginDataClear())
            let activePool = try XCTUnwrap(pool)
            let clearTask = Task {
                try await activePool.clearWebsiteData(token)
            }
            defer { clearer.finishFirstCall() }
            let didStart = await clearer.waitUntilFirstCallStarts()
            guard didStart else {
                clearer.finishFirstCall()
                _ = try? await clearTask.value
                XCTFail("Website-data clearer did not start before timeout")
                return
            }

            let added = try fixture.store.addAccount(
                provider: .chatgptCodex,
                label: "Added During Clear"
            )
            addedID = added.id
            registerDataStoreCleanup(added.id)
            let addedStore = activePool.getWebViewStore(for: added)

            XCTAssertTrue(addedStore.isDataClearInProgress)
            XCTAssertTrue(addedStore.isSuspended)
            XCTAssertFalse(
                addedStore.shouldAllowNavigation(
                    in: addedStore.webView,
                    to: added.provider.usageURL
                )
            )
            XCTAssertFalse(activePool.finishDataClear(token))
            XCTAssertTrue(addedStore.isDataClearInProgress)

            clearer.finishFirstCall()
            try await clearTask.value

            XCTAssertTrue(clearer.identifiers.contains(added.id))
            XCTAssertTrue(activePool.finishDataClear(token))
        }
        pool = nil
        await waitForWebKitRelease()
        if let addedID {
            await removeDataStore(addedID)
        }
    }

    func testAccountAddedAfterClearMustBeClearedBeforeFinish() async throws {
        let fixture = makeAccountStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let clearer = RecordingAccountWebsiteDataClearer()
        var pool: UsageWebViewPool? = UsageWebViewPool(
            accountStore: fixture.store,
            websiteDataClearer: clearer
        )
        let token = try XCTUnwrap(pool?.beginDataClear())
        try await pool?.clearWebsiteData(token)
        XCTAssertTrue(pool?.isWebsiteDataClearComplete(token) == true)

        let added = try fixture.store.addAccount(
            provider: .chatgptCodex,
            label: "Added After Clear"
        )
        registerDataStoreCleanup(added.id)

        XCTAssertFalse(pool?.isWebsiteDataClearComplete(token) == true)
        XCTAssertFalse(pool?.finishDataClear(token) == true)
        var addedStore: WebViewStore? = try XCTUnwrap(pool?.getWebViewStore(for: added))
        XCTAssertTrue(addedStore?.isDataClearInProgress == true)

        try await pool?.clearWebsiteData(token)

        XCTAssertTrue(clearer.identifiers.contains(added.id))
        XCTAssertTrue(pool?.isWebsiteDataClearComplete(token) == true)
        XCTAssertTrue(pool?.finishDataClear(token) == true)
        addedStore = nil
        pool = nil
        await waitForWebKitRelease()
        await removeDataStore(added.id)
    }

    func testIdentifiedStoresIsolateSameDomainCookies() async throws {
        let personalID = UUID()
        let workID = UUID()
        registerDataStoreCleanup(personalID)
        registerDataStoreCleanup(workID)
        var personalStore: WKWebsiteDataStore? = WKWebsiteDataStore(
            forIdentifier: personalID
        )
        var workStore: WKWebsiteDataStore? = WKWebsiteDataStore(
            forIdentifier: workID
        )
        var personalCookies: WKHTTPCookieStore? = personalStore?.httpCookieStore
        var workCookies: WKHTTPCookieStore? = workStore?.httpCookieStore
        let personalCookie = try XCTUnwrap(makeCookie(value: "personal"))
        let workCookie = try XCTUnwrap(makeCookie(value: "work"))

        await personalCookies?.setCookie(personalCookie)
        await workCookies?.setCookie(workCookie)

        let personalValues = await personalCookies?.allCookies()
            .filter { $0.name == Self.cookieName }
            .map(\.value)
        let workValues = await workCookies?.allCookies()
            .filter { $0.name == Self.cookieName }
            .map(\.value)
        XCTAssertEqual(personalValues, ["personal"])
        XCTAssertEqual(workValues, ["work"])

        if let personalStore {
            try await DefaultWebsiteDataClearer().clearAllWebsiteData(in: personalStore)
        }
        if let workStore {
            try await DefaultWebsiteDataClearer().clearAllWebsiteData(in: workStore)
        }
        personalCookies = nil
        workCookies = nil
        personalStore = nil
        workStore = nil
        await waitForWebKitRelease()
        await removeDataStore(personalID)
        await removeDataStore(workID)
    }

    private static let cookieName = "agentlimits_account_isolation"

    private func makeCookie(value: String) -> HTTPCookie? {
        HTTPCookie(properties: [
            .domain: "example.com",
            .path: "/",
            .name: Self.cookieName,
            .value: value,
            .secure: "TRUE",
            .expires: Date().addingTimeInterval(300)
        ])
    }

    private func makeAccountStore() -> (
        store: ProviderAccountStore,
        defaults: UserDefaults,
        suiteName: String
    ) {
        let suiteName = "AccountWebKitIsolationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (
            ProviderAccountStore(userDefaults: defaults, key: "test_accounts"),
            defaults,
            suiteName
        )
    }

    private func waitForWebKitRelease() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func registerDataStoreCleanup(_ identifier: UUID) {
        addTeardownBlock { @MainActor [weak self] in
            guard let self else { return }
            await self.waitForWebKitRelease()
            await self.removeDataStore(identifier)
        }
    }

    private func removeDataStore(_ identifier: UUID) async {
        for _ in 0..<100 {
            let identifiers = await WKWebsiteDataStore.allDataStoreIdentifiers
            guard identifiers.contains(identifier) else { return }
            do {
                try await WKWebsiteDataStore.remove(forIdentifier: identifier)
            } catch {
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTFail("Identified WebKit store remained in use: \(identifier.uuidString)")
    }
}

@MainActor
private final class RecordingAccountWebsiteDataClearer: WebsiteDataClearing {
    private(set) var identifiers: [UUID?] = []

    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws {
        identifiers.append(dataStore.identifier)
    }
}

@MainActor
private final class FirstCallSuspendingAccountWebsiteDataClearer: WebsiteDataClearing {
    private(set) var identifiers: [UUID?] = []
    private var firstCallStarted = false
    private var finishRequested = false
    private var finishContinuation: CheckedContinuation<Void, Never>?

    func clearAllWebsiteData(in dataStore: WKWebsiteDataStore) async throws {
        identifiers.append(dataStore.identifier)
        guard identifiers.count == 1 else { return }
        firstCallStarted = true
        guard !finishRequested else { return }
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
    }

    func waitUntilFirstCallStarts() async -> Bool {
        for _ in 0..<200 {
            if firstCallStarted { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return firstCallStarted
    }

    func finishFirstCall() {
        finishRequested = true
        finishContinuation?.resume()
        finishContinuation = nil
    }
}
