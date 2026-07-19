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
            XCTAssertTrue(firstLoad.allSatisfy { $0.webKitStorage == .legacyDefault })
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
            XCTAssertEqual(work.webKitStorage, .isolated)
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
            XCTAssertEqual(store.account(id: work.id)?.webKitStorage, .isolated)

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
            let selectedAfterFailure = store.selectedAccount(for: .claudeCode)
            XCTAssertEqual(selectedAfterFailure.id, account.id)
        }
    }

    func testCorruptPayloadFallsBackToStableIsolatedDefaults() {
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
        XCTAssertTrue(recovered.allSatisfy { $0.webKitStorage == .isolated })
        XCTAssertEqual(store.loadAccounts(), recovered)
    }

    func testWrongTypedPayloadIsCorruptRatherThanAUsableFreshInstall() {
        withStoreAndDefaults { store, defaults in
            defaults.set("not-data", forKey: Self.accountKey)

            let recovered = store.loadAccounts()

            XCTAssertTrue(recovered.allSatisfy { $0.webKitStorage == .isolated })
            XCTAssertNotNil(defaults.data(forKey: Self.accountKey))
            XCTAssertEqual(store.loadAccounts(), recovered)
        }
    }

    func testUpdatePreservesImmutableIdentityFields() throws {
        try withStore { store in
            let work = try store.addAccount(provider: .chatgptCodex, label: "Work")
            let inconsistentUpdate = ProviderAccount(
                id: work.id,
                provider: .claudeCode,
                label: "Renamed",
                isEnabled: false,
                cliDataRoot: "/tmp/claude",
                createdAt: .distantPast,
                webKitStorage: .legacyDefault
            )

            try store.updateAccount(inconsistentUpdate)

            let stored = try XCTUnwrap(store.account(id: work.id))
            XCTAssertEqual(stored.provider, work.provider)
            XCTAssertEqual(stored.createdAt, work.createdAt)
            XCTAssertEqual(stored.webKitStorage, work.webKitStorage)
            XCTAssertEqual(stored.label, "Renamed")
            XCTAssertFalse(stored.isEnabled)
        }
    }

    func testV1MigrationAssignsLegacyStorageOnlyToOldestAccountPerProvider() throws {
        try withStoreAndDefaults { store, defaults in
            let olderID = UUID()
            let newerID = UUID()
            let baseDate = Date(timeIntervalSinceReferenceDate: 750_000_000)
            let payload = V1Payload(
                version: 1,
                accounts: [
                    V1Account(
                        id: newerID,
                        provider: .chatgptCodex,
                        label: "Newer",
                        createdAt: baseDate.addingTimeInterval(10)
                    ),
                    V1Account(
                        id: olderID,
                        provider: .chatgptCodex,
                        label: "Older",
                        createdAt: baseDate
                    ),
                    V1Account(
                        id: UUID(),
                        provider: .claudeCode,
                        label: "Claude",
                        createdAt: baseDate
                    ),
                    V1Account(
                        id: UUID(),
                        provider: .githubCopilot,
                        label: "Copilot",
                        createdAt: baseDate
                    )
                ]
            )
            defaults.set(try JSONEncoder().encode(payload), forKey: Self.accountKey)

            let migrated = store.loadAccounts()

            XCTAssertEqual(
                migrated.first(where: { $0.id == olderID })?.webKitStorage,
                .legacyDefault
            )
            XCTAssertEqual(
                migrated.first(where: { $0.id == newerID })?.webKitStorage,
                .isolated
            )
            for provider in UsageProvider.allCases {
                XCTAssertEqual(
                    migrated.filter {
                        $0.provider == provider && $0.webKitStorage == .legacyDefault
                    }.count,
                    1
                )
            }

            let stored = try decodeStoredPayload(defaults)
            XCTAssertEqual(stored.version, 2)
            XCTAssertEqual(stored.accounts, migrated)
        }
    }

    func testV1MigrationKeepsRepairedZeroIdentifierIsolated() throws {
        try withStoreAndDefaults { store, defaults in
            let zeroID = try XCTUnwrap(UUID(uuidString: Self.zeroUUIDString))
            let baseDate = Date(timeIntervalSinceReferenceDate: 750_000_000)
            let payload = V1Payload(
                version: 1,
                accounts: [
                    V1Account(
                        id: zeroID,
                        provider: .chatgptCodex,
                        label: "Invalid Codex",
                        createdAt: baseDate
                    ),
                    V1Account(
                        id: UUID(),
                        provider: .claudeCode,
                        label: "Claude",
                        createdAt: baseDate
                    ),
                    V1Account(
                        id: UUID(),
                        provider: .githubCopilot,
                        label: "Copilot",
                        createdAt: baseDate
                    )
                ]
            )
            defaults.set(try JSONEncoder().encode(payload), forKey: Self.accountKey)

            let migrated = store.accounts(for: .chatgptCodex)

            XCTAssertEqual(migrated.count, 1)
            XCTAssertNotEqual(migrated[0].id, zeroID)
            XCTAssertEqual(migrated[0].webKitStorage, .isolated)
            XCTAssertEqual(store.accounts(for: .chatgptCodex), migrated)
        }
    }

    func testV1DuplicateIdentifierRepairUsesOldestAccountNotSerializedOrder() throws {
        try withStoreAndDefaults { store, defaults in
            let duplicateID = UUID()
            let baseDate = Date(timeIntervalSinceReferenceDate: 750_000_000)
            let payload = V1Payload(
                version: 1,
                accounts: [
                    V1Account(
                        id: duplicateID,
                        provider: .chatgptCodex,
                        label: "Newer",
                        createdAt: baseDate.addingTimeInterval(10)
                    ),
                    V1Account(
                        id: duplicateID,
                        provider: .chatgptCodex,
                        label: "Older",
                        createdAt: baseDate
                    ),
                    V1Account(
                        id: UUID(),
                        provider: .claudeCode,
                        label: "Claude",
                        createdAt: baseDate
                    ),
                    V1Account(
                        id: UUID(),
                        provider: .githubCopilot,
                        label: "Copilot",
                        createdAt: baseDate
                    )
                ]
            )
            defaults.set(try JSONEncoder().encode(payload), forKey: Self.accountKey)

            let migrated = store.accounts(for: .chatgptCodex)

            XCTAssertEqual(migrated.count, 2)
            XCTAssertEqual(migrated.first(where: { $0.label == "Older" })?.id, duplicateID)
            XCTAssertEqual(
                migrated.first(where: { $0.label == "Older" })?.webKitStorage,
                .legacyDefault
            )
            XCTAssertNotEqual(migrated.first(where: { $0.label == "Newer" })?.id, duplicateID)
            XCTAssertEqual(
                migrated.first(where: { $0.label == "Newer" })?.webKitStorage,
                .isolated
            )
        }
    }

    func testModernPayloadWithoutLegacyStorageDoesNotPromoteAnAccount() throws {
        try withStoreAndDefaults { store, defaults in
            let accounts = UsageProvider.allCases.map {
                ProviderAccount(
                    provider: $0,
                    label: $0.displayName,
                    webKitStorage: .isolated
                )
            }
            defaults.set(
                try JSONEncoder().encode(StoredPayload(version: 2, accounts: accounts)),
                forKey: Self.accountKey
            )

            XCTAssertTrue(store.loadAccounts().allSatisfy {
                $0.webKitStorage == .isolated
            })
            XCTAssertTrue(store.loadAccounts().allSatisfy {
                $0.webKitStorage == .isolated
            })
        }
    }

    func testMissingAndUnknownModernStorageValuesDefaultToIsolated() throws {
        try withStoreAndDefaults { store, defaults in
            let accounts = UsageProvider.allCases.map {
                ProviderAccount(
                    provider: $0,
                    label: $0.displayName,
                    webKitStorage: .isolated
                )
            }
            let data = try JSONEncoder().encode(StoredPayload(version: 2, accounts: accounts))
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            var rawAccounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
            rawAccounts[0].removeValue(forKey: "webKitStorage")
            rawAccounts[1]["webKitStorage"] = "futureSharedStore"
            root["accounts"] = rawAccounts
            defaults.set(
                try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
                forKey: Self.accountKey
            )

            let loaded = store.loadAccounts()

            XCTAssertTrue(loaded.allSatisfy { $0.webKitStorage == .isolated })
            XCTAssertEqual(Set(loaded.map(\.id)), Set(accounts.map(\.id)))
            XCTAssertEqual(Set(loaded.map(\.label)), Set(accounts.map(\.label)))
            let normalizedData = try XCTUnwrap(defaults.data(forKey: Self.accountKey))
            let normalizedRoot = try XCTUnwrap(
                JSONSerialization.jsonObject(with: normalizedData) as? [String: Any]
            )
            let normalizedAccounts = try XCTUnwrap(
                normalizedRoot["accounts"] as? [[String: Any]]
            )
            XCTAssertTrue(normalizedAccounts.allSatisfy {
                $0["webKitStorage"] as? String == "isolated"
            })
        }
    }

    func testNewerRegistryVersionIsStablePreservedAndReadOnly() throws {
        try withStoreAndDefaults { store, defaults in
            let futureID = UUID()
            let futureData = try JSONSerialization.data(withJSONObject: [
                "version": 99,
                "accounts": [[
                    "id": futureID.uuidString,
                    "provider": "futureProvider",
                    "label": "Future",
                    "isEnabled": true,
                    "createdAt": 0,
                    "webKitStorage": "futureStorage"
                ]]
            ], options: [.sortedKeys])
            defaults.set(futureData, forKey: Self.accountKey)
            let selectionKey = selectedKey(for: .chatgptCodex)
            defaults.set(futureID.uuidString.lowercased(), forKey: selectionKey)

            let firstLoad = store.loadAccounts()
            let secondLoad = store.loadAccounts()
            _ = store.selectedAccount(for: .chatgptCodex)
            _ = store.primaryAccount(for: .chatgptCodex)

            XCTAssertEqual(firstLoad, secondLoad)
            XCTAssertEqual(firstLoad.count, UsageProvider.allCases.count)
            XCTAssertTrue(firstLoad.allSatisfy { $0.webKitStorage == .isolated })
            XCTAssertEqual(defaults.data(forKey: Self.accountKey), futureData)
            XCTAssertEqual(
                defaults.string(forKey: selectionKey),
                futureID.uuidString.lowercased()
            )
            XCTAssertThrowsError(
                try store.addAccount(provider: .chatgptCodex, label: "Blocked")
            ) { error in
                XCTAssertEqual(
                    error as? ProviderAccountStoreError,
                    .unsupportedVersion(99)
                )
            }
            XCTAssertEqual(defaults.data(forKey: Self.accountKey), futureData)
        }
    }

    func testNormalizedCLIRootTieCannotGrantLegacyStorageByArrayOrder() throws {
        try withStoreAndDefaults { store, defaults in
            let duplicateID = UUID()
            let createdAt = Date(timeIntervalSinceReferenceDate: 750_000_000)
            let legacyNilRoot = ProviderAccount(
                id: duplicateID,
                provider: .chatgptCodex,
                label: "Duplicate",
                cliDataRoot: nil,
                createdAt: createdAt,
                webKitStorage: .legacyDefault
            )
            let baseData = try JSONEncoder().encode(
                StoredPayload(version: 2, accounts: [legacyNilRoot, legacyNilRoot])
            )
            let baseRoot = try XCTUnwrap(
                JSONSerialization.jsonObject(with: baseData) as? [String: Any]
            )
            let baseAccounts = try XCTUnwrap(
                baseRoot["accounts"] as? [[String: Any]]
            )
            let legacyAccount = baseAccounts[0]
            var isolatedEmptyRoot = baseAccounts[1]
            isolatedEmptyRoot["cliDataRoot"] = ""
            isolatedEmptyRoot["webKitStorage"] = "isolated"

            for accountOrder in [
                [legacyAccount, isolatedEmptyRoot],
                [isolatedEmptyRoot, legacyAccount]
            ] {
                var orderedRoot = baseRoot
                orderedRoot["accounts"] = accountOrder
                defaults.set(
                    try JSONSerialization.data(
                        withJSONObject: orderedRoot,
                        options: [.sortedKeys]
                    ),
                    forKey: Self.accountKey
                )
                let repaired = store.accounts(for: .chatgptCodex)
                XCTAssertEqual(repaired.count, 2)
                XCTAssertTrue(repaired.allSatisfy { $0.webKitStorage == .isolated })
                XCTAssertEqual(repaired.filter { $0.id == duplicateID }.count, 1)
            }
        }
    }

    func testDuplicateLegacyStorageIsDeterministicallyDemoted() throws {
        try withStoreAndDefaults { store, defaults in
            let baseDate = Date(timeIntervalSinceReferenceDate: 750_000_000)
            let older = ProviderAccount(
                provider: .chatgptCodex,
                label: "Older",
                createdAt: baseDate,
                webKitStorage: .legacyDefault
            )
            let newer = ProviderAccount(
                provider: .chatgptCodex,
                label: "Newer",
                createdAt: baseDate.addingTimeInterval(1),
                webKitStorage: .legacyDefault
            )
            defaults.set(
                try JSONEncoder().encode(
                    StoredPayload(version: 2, accounts: [newer, older])
                ),
                forKey: Self.accountKey
            )

            let loaded = store.accounts(for: .chatgptCodex)

            XCTAssertEqual(loaded.first(where: { $0.id == older.id })?.webKitStorage, .legacyDefault)
            XCTAssertEqual(loaded.first(where: { $0.id == newer.id })?.webKitStorage, .isolated)
            XCTAssertEqual(try decodeStoredPayload(defaults).accounts, store.loadAccounts())
        }
    }

    func testModernDuplicateIdentifierRepairUsesOldestAccountNotSerializedOrder() throws {
        try withStoreAndDefaults { store, defaults in
            let duplicateID = UUID()
            let baseDate = Date(timeIntervalSinceReferenceDate: 750_000_000)
            let older = ProviderAccount(
                id: duplicateID,
                provider: .chatgptCodex,
                label: "Older",
                createdAt: baseDate,
                webKitStorage: .legacyDefault
            )
            let newer = ProviderAccount(
                id: duplicateID,
                provider: .chatgptCodex,
                label: "Newer",
                createdAt: baseDate.addingTimeInterval(10),
                webKitStorage: .legacyDefault
            )
            defaults.set(
                try JSONEncoder().encode(
                    StoredPayload(version: 2, accounts: [newer, older])
                ),
                forKey: Self.accountKey
            )

            let repaired = store.accounts(for: .chatgptCodex)

            XCTAssertEqual(repaired.first(where: { $0.label == "Older" })?.id, duplicateID)
            XCTAssertEqual(
                repaired.first(where: { $0.label == "Older" })?.webKitStorage,
                .legacyDefault
            )
            XCTAssertNotEqual(repaired.first(where: { $0.label == "Newer" })?.id, duplicateID)
            XCTAssertEqual(
                repaired.first(where: { $0.label == "Newer" })?.webKitStorage,
                .isolated
            )
        }
    }

    func testV1CrossProviderDuplicateKeepsRepairedIdentityIsolated() throws {
        try withStoreAndDefaults { store, defaults in
            let duplicateID = UUID()
            let baseDate = Date(timeIntervalSinceReferenceDate: 750_000_000)
            let payload = V1Payload(
                version: 1,
                accounts: [
                    V1Account(
                        id: duplicateID,
                        provider: .claudeCode,
                        label: "Claude Duplicate",
                        createdAt: baseDate.addingTimeInterval(1)
                    ),
                    V1Account(
                        id: duplicateID,
                        provider: .chatgptCodex,
                        label: "Codex Original",
                        createdAt: baseDate
                    ),
                    V1Account(
                        id: UUID(),
                        provider: .githubCopilot,
                        label: "Copilot",
                        createdAt: baseDate
                    )
                ]
            )
            defaults.set(try JSONEncoder().encode(payload), forKey: Self.accountKey)

            let migrated = store.loadAccounts()
            let codex = try XCTUnwrap(
                migrated.first(where: { $0.provider == .chatgptCodex })
            )
            let claude = try XCTUnwrap(
                migrated.first(where: { $0.provider == .claudeCode })
            )

            XCTAssertEqual(codex.id, duplicateID)
            XCTAssertEqual(codex.webKitStorage, .legacyDefault)
            XCTAssertNotEqual(claude.id, duplicateID)
            XCTAssertEqual(claude.webKitStorage, .isolated)
            XCTAssertEqual(Set(migrated.map(\.id)).count, migrated.count)
        }
    }

    func testZeroAndDuplicateUUIDsAreRekeyedWithoutDroppingAccounts() throws {
        try withStoreAndDefaults { store, defaults in
            let duplicateID = UUID()
            let first = ProviderAccount(
                id: duplicateID,
                provider: .chatgptCodex,
                label: "First",
                createdAt: .distantPast,
                webKitStorage: .legacyDefault
            )
            let duplicate = ProviderAccount(
                id: duplicateID,
                provider: .chatgptCodex,
                label: "Duplicate",
                createdAt: Date(timeIntervalSinceReferenceDate: 1),
                webKitStorage: .legacyDefault
            )
            let data = try JSONEncoder().encode(
                StoredPayload(version: 2, accounts: [first, duplicate])
            )
            var root = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: Any]
            )
            var rawAccounts = try XCTUnwrap(root["accounts"] as? [[String: Any]])
            var zero = rawAccounts[1]
            zero["id"] = Self.zeroUUIDString
            zero["label"] = "Zero"
            rawAccounts.append(zero)
            root["accounts"] = rawAccounts
            defaults.set(
                try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
                forKey: Self.accountKey
            )

            let loaded = store.accounts(for: .chatgptCodex)

            XCTAssertEqual(loaded.count, 3)
            XCTAssertEqual(Set(loaded.map(\.id)).count, 3)
            XCTAssertFalse(loaded.contains { $0.id.uuidString == Self.zeroUUIDString })
            XCTAssertEqual(loaded.first(where: { $0.label == "First" })?.id, duplicateID)
            XCTAssertEqual(
                loaded.first(where: { $0.label == "Duplicate" })?.webKitStorage,
                .isolated
            )
            XCTAssertEqual(
                loaded.first(where: { $0.label == "Zero" })?.webKitStorage,
                .isolated
            )
            XCTAssertEqual(store.accounts(for: .chatgptCodex), loaded)
        }
    }

    func testRemovingLegacyAccountNeverPromotesAReplacement() throws {
        try withStore { store in
            let legacy = store.accounts(for: .chatgptCodex)[0]
            let isolated = try store.addAccount(provider: .chatgptCodex, label: "Work")

            try store.removeAccount(id: legacy.id)

            XCTAssertEqual(store.accounts(for: .chatgptCodex), [isolated])
            XCTAssertEqual(
                store.accounts(for: .chatgptCodex)[0].webKitStorage,
                .isolated
            )
            let added = try store.addAccount(provider: .chatgptCodex, label: "Personal")
            XCTAssertEqual(added.webKitStorage, .isolated)
            XCTAssertTrue(store.accounts(for: .chatgptCodex).allSatisfy {
                $0.webKitStorage == .isolated
            })
        }
    }

    func testSelectionPersistsIndependentlyForEachProvider() throws {
        try withStoreAndDefaults { store, defaults in
            let codexWork = try store.addAccount(provider: .chatgptCodex, label: "Codex Work")
            let claudeWork = try store.addAccount(provider: .claudeCode, label: "Claude Work")
            try store.selectAccount(id: codexWork.id)
            try store.selectAccount(id: claudeWork.id)

            let reloadedStore = ProviderAccountStore(
                userDefaults: defaults,
                key: Self.accountKey
            )
            let persistedCodexSelection = reloadedStore.selectedAccount(for: .chatgptCodex)
            let persistedClaudeSelection = reloadedStore.selectedAccount(for: .claudeCode)
            XCTAssertEqual(persistedCodexSelection.id, codexWork.id)
            XCTAssertEqual(persistedClaudeSelection.id, claudeWork.id)

            let codexPrimary = reloadedStore.accounts(for: .chatgptCodex)[0]
            try reloadedStore.selectAccount(id: codexPrimary.id)
            let changedCodexSelection = reloadedStore.selectedAccount(for: .chatgptCodex)
            let unchangedClaudeSelection = reloadedStore.selectedAccount(for: .claudeCode)
            XCTAssertEqual(changedCodexSelection.id, codexPrimary.id)
            XCTAssertEqual(unchangedClaudeSelection.id, claudeWork.id)
        }
    }

    func testValidDisabledSelectionRemainsSelected() throws {
        try withStore { store in
            let work = try store.addAccount(provider: .chatgptCodex, label: "Work")
            try store.selectAccount(id: work.id)
            try store.updateAccount(work.updating(
                label: work.label,
                isEnabled: false,
                cliDataRoot: work.cliDataRoot
            ))

            XCTAssertEqual(store.selectedAccount(for: .chatgptCodex).id, work.id)
        }
    }

    func testInvalidSelectionsRepairToEnabledThenFirstAccount() throws {
        try withStoreAndDefaults { store, defaults in
            let primary = store.accounts(for: .chatgptCodex)[0]
            let work = try store.addAccount(provider: .chatgptCodex, label: "Work")
            try store.updateAccount(primary.updating(
                label: primary.label,
                isEnabled: false,
                cliDataRoot: primary.cliDataRoot
            ))
            let key = selectedKey(for: .chatgptCodex)

            for invalid in ["not-a-uuid", UUID().uuidString,
                            store.accounts(for: .claudeCode)[0].id.uuidString] {
                defaults.set(invalid, forKey: key)
                XCTAssertEqual(store.selectedAccount(for: .chatgptCodex).id, work.id)
                XCTAssertEqual(defaults.string(forKey: key), work.id.uuidString.lowercased())
            }

            try store.updateAccount(work.updating(
                label: work.label,
                isEnabled: false,
                cliDataRoot: work.cliDataRoot
            ))
            defaults.set("invalid-again", forKey: key)
            XCTAssertEqual(store.selectedAccount(for: .chatgptCodex).id, primary.id)
        }
    }

    func testRemovingSelectedAccountChoosesFirstEnabledReplacement() throws {
        try withStore { store in
            let primary = store.accounts(for: .chatgptCodex)[0]
            try store.updateAccount(primary.updating(
                label: primary.label,
                isEnabled: false,
                cliDataRoot: primary.cliDataRoot
            ))
            let selected = try store.addAccount(provider: .chatgptCodex, label: "Selected")
            let replacement = try store.addAccount(provider: .chatgptCodex, label: "Replacement")
            try store.selectAccount(id: selected.id)

            try store.removeAccount(id: selected.id)

            XCTAssertEqual(store.selectedAccount(for: .chatgptCodex).id, replacement.id)
        }
    }

    func testRemovingSelectedAccountFallsBackToFirstDisabledReplacement() throws {
        try withStoreAndDefaults { store, defaults in
            let primary = store.accounts(for: .chatgptCodex)[0]
            let selected = try store.addAccount(provider: .chatgptCodex, label: "Selected")
            let later = try store.addAccount(provider: .chatgptCodex, label: "Later")
            for account in [primary, selected, later] {
                try store.updateAccount(account.updating(
                    label: account.label,
                    isEnabled: false,
                    cliDataRoot: account.cliDataRoot
                ))
            }
            try store.selectAccount(id: selected.id)

            try store.removeAccount(id: selected.id)

            XCTAssertEqual(store.selectedAccount(for: .chatgptCodex).id, primary.id)
            XCTAssertEqual(
                defaults.string(forKey: selectedKey(for: .chatgptCodex)),
                primary.id.uuidString.lowercased()
            )
        }
    }

    func testRemovingNonselectedAccountPreservesSelection() throws {
        try withStore { store in
            let primary = store.accounts(for: .chatgptCodex)[0]
            let selected = try store.addAccount(provider: .chatgptCodex, label: "Selected")
            try store.selectAccount(id: selected.id)

            try store.removeAccount(id: primary.id)

            XCTAssertEqual(store.selectedAccount(for: .chatgptCodex).id, selected.id)
        }
    }

    func testSelectingUnknownAccountFailsWithoutChangingSelection() throws {
        try withStore { store in
            let selected = store.selectedAccount(for: .chatgptCodex)

            XCTAssertThrowsError(try store.selectAccount(id: UUID())) { error in
                XCTAssertEqual(error as? ProviderAccountStoreError, .accountNotFound)
            }
            let selectionAfterFailure = store.selectedAccount(for: .chatgptCodex)
            XCTAssertEqual(selectionAfterFailure.id, selected.id)
        }
    }

    private static let accountKey = "test_accounts"
    private static let zeroUUIDString = "00000000-0000-0000-0000-000000000000"

    private struct StoredPayload: Codable {
        let version: Int
        let accounts: [ProviderAccount]
    }

    private struct V1Payload: Codable {
        let version: Int
        let accounts: [V1Account]
    }

    private struct V1Account: Codable {
        let id: UUID
        let provider: UsageProvider
        let label: String
        let isEnabled: Bool
        let cliDataRoot: String?
        let createdAt: Date

        init(
            id: UUID,
            provider: UsageProvider,
            label: String,
            isEnabled: Bool = true,
            cliDataRoot: String? = nil,
            createdAt: Date
        ) {
            self.id = id
            self.provider = provider
            self.label = label
            self.isEnabled = isEnabled
            self.cliDataRoot = cliDataRoot
            self.createdAt = createdAt
        }
    }

    private func decodeStoredPayload(_ defaults: UserDefaults) throws -> StoredPayload {
        let data = try XCTUnwrap(defaults.data(forKey: Self.accountKey))
        return try JSONDecoder().decode(StoredPayload.self, from: data)
    }

    private func selectedKey(for provider: UsageProvider) -> String {
        "\(Self.accountKey).selected.\(provider.rawValue)"
    }

    private func withStore(
        _ body: (ProviderAccountStore) throws -> Void
    ) rethrows {
        let suiteName = "ProviderAccountStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(ProviderAccountStore(
            userDefaults: defaults,
            key: Self.accountKey
        ))
    }

    private func withStoreAndDefaults(
        _ body: (ProviderAccountStore, UserDefaults) throws -> Void
    ) rethrows {
        let suiteName = "ProviderAccountStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(
            ProviderAccountStore(userDefaults: defaults, key: Self.accountKey),
            defaults
        )
    }
}
