import Foundation
import Security
import XCTest
@testable import AgentLimitsiOS

final class MobileSessionCredentialStoreTests: XCTestCase {
    @MainActor
    func testSaveUsesExactAccountDeviceOnlyNonSynchronizingItem() throws {
        let client = FakeMobileSecurityClient()
        let store = MobileSessionCredentialStore(securityClient: client)
        let accountID = UUID()

        try store.saveCredential("mobile-test-token", for: accountID)

        let attributes = try XCTUnwrap(client.addedAttributes.first)
        XCTAssertEqual(
            attributes[kSecAttrService as String] as? String,
            MobileSessionCredentialStore.service
        )
        XCTAssertEqual(
            attributes[kSecAttrAccount as String] as? String,
            accountID.uuidString.lowercased()
        )
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(
            attributes[kSecAttrSynchronizable as String] as? Bool,
            false
        )
        XCTAssertEqual(
            String(
                data: try XCTUnwrap(attributes[kSecValueData as String] as? Data),
                encoding: .utf8
            ),
            "mobile-test-token"
        )
    }

    @MainActor
    func testCredentialsLoadAndDeleteByImmutableAccount() throws {
        let client = FakeMobileSecurityClient()
        let store = MobileSessionCredentialStore(securityClient: client)
        let accountID = UUID()
        client.copyStatus = errSecSuccess
        client.copyResult = Data("stored-token".utf8)

        XCTAssertEqual(try store.credential(for: accountID), "stored-token")
        try store.deleteCredential(for: accountID)

        let delete = try XCTUnwrap(client.deletedQueries.first)
        XCTAssertEqual(
            delete[kSecAttrAccount as String] as? String,
            accountID.uuidString.lowercased()
        )
    }

    @MainActor
    func testInvalidCredentialsFailBeforeKeychainMutation() {
        for credential in ["", "has space", "line\nbreak", "bad\u{001F}value"] {
            let client = FakeMobileSecurityClient()
            let store = MobileSessionCredentialStore(securityClient: client)

            XCTAssertThrowsError(
                try store.saveCredential(credential, for: UUID())
            ) {
                XCTAssertEqual(
                    $0 as? MobileSessionCredentialStoreError,
                    .invalidCredential
                )
            }
            XCTAssertTrue(client.addedAttributes.isEmpty)
        }
    }

    @MainActor
    func testReplaceRaceRetriesOneBoundedAdd() throws {
        let client = FakeMobileSecurityClient()
        client.addStatuses = [errSecDuplicateItem, errSecSuccess]
        client.updateStatuses = [errSecItemNotFound]
        let store = MobileSessionCredentialStore(securityClient: client)

        try store.saveCredential("replacement", for: UUID())

        XCTAssertEqual(client.addedAttributes.count, 2)
        XCTAssertEqual(client.updatedQueries.count, 1)
    }

    @MainActor
    func testDeleteAllIsScopedToFeatureService() throws {
        let client = FakeMobileSecurityClient()
        let store = MobileSessionCredentialStore(securityClient: client)

        try store.deleteAllCredentials()

        let query = try XCTUnwrap(client.deletedQueries.first)
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            MobileSessionCredentialStore.service
        )
        XCTAssertNil(query[kSecAttrAccount as String])
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }

    @MainActor
    func testSimulatorKeychainRoundTripUsesDeviceOnlyAttributes() throws {
        let store = MobileSessionCredentialStore()
        let accountID = UUID()
        defer { try? store.deleteCredential(for: accountID) }

        do {
            try store.saveCredential("simulator-test-token", for: accountID)
        } catch let error as MobileSessionCredentialStoreError {
            guard case .keychain(let status) = error,
                  status == errSecMissingEntitlement else {
                throw error
            }
            throw XCTSkip(
                "Unsigned simulator test hosts cannot access Keychain. The signed simulator gate runs this test separately."
            )
        }

        XCTAssertEqual(
            try store.credential(for: accountID),
            "simulator-test-token"
        )
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: MobileSessionCredentialStore.service,
            kSecAttrAccount as String: accountID.uuidString.lowercased(),
            kSecAttrSynchronizable as String: false,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        XCTAssertEqual(status, errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        )
        XCTAssertEqual(
            attributes[kSecAttrSynchronizable as String] as? Bool,
            false
        )
    }
}

@MainActor
private final class FakeMobileSecurityClient: MobileSecurityClient {
    var copyStatus: OSStatus = errSecItemNotFound
    var copyResult: Any?
    var addStatuses: [OSStatus] = [errSecSuccess]
    var updateStatuses: [OSStatus] = [errSecSuccess]
    var deleteStatuses: [OSStatus] = [errSecSuccess]
    private(set) var addedAttributes: [[String: Any]] = []
    private(set) var updatedQueries: [[String: Any]] = []
    private(set) var deletedQueries: [[String: Any]] = []

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        (copyStatus, copyResult)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        addedAttributes.append(attributes)
        return addStatuses.count > 1
            ? addStatuses.removeFirst()
            : addStatuses[0]
    }

    func update(
        _ query: [String: Any],
        attributesToUpdate: [String: Any]
    ) -> OSStatus {
        updatedQueries.append(query)
        return updateStatuses.count > 1
            ? updateStatuses.removeFirst()
            : updateStatuses[0]
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deletedQueries.append(query)
        return deleteStatuses.count > 1
            ? deleteStatuses.removeFirst()
            : deleteStatuses[0]
    }
}
