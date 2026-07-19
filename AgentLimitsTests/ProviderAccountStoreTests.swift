import Foundation
import XCTest
@testable import AgentLimits

final class ProviderAccountStoreTests: XCTestCase {
    func testFirstLoadCreatesStablePrimaryAccountForEveryProvider() {
        withStore { store in
            let firstLoad = store.loadAccounts()
            let secondLoad = store.loadAccounts()

            XCTAssertEqual(firstLoad, secondLoad)
            XCTAssertEqual(firstLoad.count, UsageProvider.allCases.count)
            for provider in UsageProvider.allCases {
                XCTAssertEqual(firstLoad.filter { $0.provider == provider }.count, 1)
            }
            XCTAssertEqual(Set(firstLoad.map(\.id)).count, firstLoad.count)
        }
    }

    func testAddsUpdatesAndRemovesIndependentAccounts() throws {
        try withStore { store in
            let work = try store.addAccount(
                provider: .chatgptCodex,
                label: "  Work  ",
                cliDataRoot: "  ~/Codex Work  "
            )
            XCTAssertEqual(work.label, "Work")
            XCTAssertEqual(work.cliDataRoot, "~/Codex Work")
            XCTAssertEqual(store.accounts(for: .chatgptCodex).count, 2)

            let disabled = work.updating(
                label: "Company",
                isEnabled: false,
                cliDataRoot: ""
            )
            try store.updateAccount(disabled)
            XCTAssertEqual(store.account(id: work.id)?.label, "Company")
            XCTAssertEqual(store.account(id: work.id)?.isEnabled, false)
            XCTAssertNil(store.account(id: work.id)?.cliDataRoot)

            try store.removeAccount(id: work.id)
            XCTAssertNil(store.account(id: work.id))
            XCTAssertEqual(store.accounts(for: .chatgptCodex).count, 1)
        }
    }

    func testCannotRemoveLastAccountForProvider() throws {
        try withStore { store in
            let account = store.primaryAccount(for: .claudeCode)

            XCTAssertThrowsError(try store.removeAccount(id: account.id)) { error in
                XCTAssertEqual(
                    error as? ProviderAccountStoreError,
                    .cannotRemoveLastAccount(.claudeCode)
                )
            }
            XCTAssertEqual(store.accounts(for: .claudeCode), [account])
        }
    }

    func testCorruptPayloadFallsBackToFreshStableDefaults() {
        let suiteName = "ProviderAccountStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(Data("not-json".utf8), forKey: "test_accounts")
        let store = ProviderAccountStore(
            userDefaults: defaults,
            key: "test_accounts"
        )

        let recovered = store.loadAccounts()

        XCTAssertEqual(recovered.count, UsageProvider.allCases.count)
        XCTAssertEqual(store.loadAccounts(), recovered)
    }

    private func withStore(
        _ body: (ProviderAccountStore) throws -> Void
    ) rethrows {
        let suiteName = "ProviderAccountStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(ProviderAccountStore(
            userDefaults: defaults,
            key: "test_accounts"
        ))
    }
}
