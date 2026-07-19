import Foundation
import Security
import XCTest
@testable import AgentLimits

final class SessionActivityCredentialStoreTests: XCTestCase {
    func testSaveCreatesDeviceOnlyGenericPasswordForExactAccount() throws {
        let client = RecordingSessionActivitySecurityClient()
        let store = SessionActivityCredentialStore(securityClient: client)
        let accountID = UUID(
            uuidString: "a3000000-0000-0000-0000-00000000000a"
        )!

        try store.saveCredential("  github-token-value\n", for: accountID)

        XCTAssertEqual(client.addedAttributes.count, 1)
        let attributes = try XCTUnwrap(client.addedAttributes.first)
        XCTAssertEqual(
            attributes[kSecClass as String] as? String,
            kSecClassGenericPassword as String
        )
        XCTAssertEqual(
            attributes[kSecUseDataProtectionKeychain as String] as? Bool,
            true
        )
        XCTAssertEqual(
            attributes[kSecAttrService as String] as? String,
            SessionActivityCredentialStore.service
        )
        XCTAssertEqual(
            attributes[kSecAttrAccount as String] as? String,
            accountID.uuidString.lowercased()
        )
        XCTAssertEqual(
            attributes[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(
            attributes[kSecValueData as String] as? Data,
            Data("github-token-value".utf8)
        )
    }

    func testDuplicateSaveAtomicallyReplacesExistingValue() throws {
        let client = RecordingSessionActivitySecurityClient()
        client.addStatuses = [errSecDuplicateItem]
        client.updateStatuses = [errSecSuccess]
        let store = SessionActivityCredentialStore(securityClient: client)
        let accountID = UUID(
            uuidString: "b3000000-0000-0000-0000-00000000000b"
        )!

        try store.saveCredential("replacement", for: accountID)

        XCTAssertEqual(client.updatedQueries.count, 1)
        let query = try XCTUnwrap(client.updatedQueries.first)
        let replacement = try XCTUnwrap(client.updatedAttributes.first)
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String,
            accountID.uuidString.lowercased()
        )
        XCTAssertEqual(
            replacement[kSecValueData as String] as? Data,
            Data("replacement".utf8)
        )
        XCTAssertEqual(
            replacement[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testReplaceRaceRetriesOneBoundedAdd() throws {
        let client = RecordingSessionActivitySecurityClient()
        client.addStatuses = [errSecDuplicateItem, errSecSuccess]
        client.updateStatuses = [errSecItemNotFound]
        let store = SessionActivityCredentialStore(securityClient: client)

        try store.saveCredential("replacement", for: UUID())

        XCTAssertEqual(client.addedAttributes.count, 2)
        XCTAssertEqual(client.updatedQueries.count, 1)
    }

    func testLoadAndDeleteHandleMissingItemsWithoutInventingCredential() throws {
        let client = RecordingSessionActivitySecurityClient()
        let store = SessionActivityCredentialStore(securityClient: client)
        let accountID = UUID()

        client.copyStatus = errSecItemNotFound
        XCTAssertNil(try store.credential(for: accountID))

        client.copyStatus = errSecSuccess
        client.copyResult = Data("stored-token".utf8)
        XCTAssertEqual(
            try store.credential(for: accountID),
            "stored-token"
        )

        client.deleteStatuses = [errSecItemNotFound, errSecSuccess]
        XCTAssertNoThrow(try store.deleteCredential(for: accountID))
        XCTAssertNoThrow(try store.deleteCredential(for: accountID))
        XCTAssertEqual(client.deletedQueries.count, 2)
    }

    func testDeleteAllIsIdempotentAndScopedToFeatureService() throws {
        let client = RecordingSessionActivitySecurityClient()
        client.deleteStatuses = [errSecItemNotFound, errSecSuccess]
        let store = SessionActivityCredentialStore(securityClient: client)

        XCTAssertNoThrow(try store.deleteAllCredentials())
        XCTAssertNoThrow(try store.deleteAllCredentials())

        XCTAssertEqual(client.deletedQueries.count, 2)
        for query in client.deletedQueries {
            XCTAssertEqual(
                query[kSecClass as String] as? String,
                kSecClassGenericPassword as String
            )
            XCTAssertEqual(
                query[kSecUseDataProtectionKeychain as String] as? Bool,
                true
            )
            XCTAssertEqual(
                query[kSecAttrService as String] as? String,
                SessionActivityCredentialStore.service
            )
            XCTAssertNil(query[kSecAttrAccount as String])
        }
    }

    func testInvalidStoredOrNewCredentialsFailClosed() throws {
        let client = RecordingSessionActivitySecurityClient()
        let store = SessionActivityCredentialStore(securityClient: client)

        for invalid in [
            "",
            "   ",
            "two words",
            "bad\0token",
            "bad\u{1f}token"
        ] {
            XCTAssertThrowsError(
                try store.saveCredential(invalid, for: UUID())
            ) { error in
                XCTAssertEqual(
                    error as? SessionActivityCredentialStoreError,
                    .invalidCredential
                )
            }
        }
        XCTAssertTrue(client.addedAttributes.isEmpty)

        client.copyStatus = errSecSuccess
        client.copyResult = Data([0xff, 0xfe])
        XCTAssertThrowsError(try store.credential(for: UUID())) { error in
            XCTAssertEqual(
                error as? SessionActivityCredentialStoreError,
                .invalidStoredCredential
            )
        }
    }

    func testUnexpectedKeychainStatusesSurfaceWithoutCredentialData() {
        let client = RecordingSessionActivitySecurityClient()
        let store = SessionActivityCredentialStore(securityClient: client)
        client.addStatuses = [errSecNotAvailable]

        XCTAssertThrowsError(
            try store.saveCredential("secret-value", for: UUID())
        ) { error in
            XCTAssertEqual(
                error as? SessionActivityCredentialStoreError,
                .keychain(errSecNotAvailable)
            )
            XCTAssertFalse(String(describing: error).contains("secret-value"))
        }
    }
}

private final class RecordingSessionActivitySecurityClient:
    SessionActivitySecurityClient {
    var copyStatus: OSStatus = errSecItemNotFound
    var copyResult: Any?
    var addStatuses: [OSStatus] = [errSecSuccess]
    var updateStatuses: [OSStatus] = [errSecSuccess]
    var deleteStatuses: [OSStatus] = [errSecSuccess]

    private(set) var copiedQueries: [[String: Any]] = []
    private(set) var addedAttributes: [[String: Any]] = []
    private(set) var updatedQueries: [[String: Any]] = []
    private(set) var updatedAttributes: [[String: Any]] = []
    private(set) var deletedQueries: [[String: Any]] = []

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        copiedQueries.append(query)
        return (copyStatus, copyResult)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        addedAttributes.append(attributes)
        return nextStatus(from: &addStatuses)
    }

    func update(
        _ query: [String: Any],
        attributesToUpdate: [String: Any]
    ) -> OSStatus {
        updatedQueries.append(query)
        updatedAttributes.append(attributesToUpdate)
        return nextStatus(from: &updateStatuses)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        deletedQueries.append(query)
        return nextStatus(from: &deleteStatuses)
    }

    private func nextStatus(from statuses: inout [OSStatus]) -> OSStatus {
        statuses.isEmpty ? errSecSuccess : statuses.removeFirst()
    }
}
