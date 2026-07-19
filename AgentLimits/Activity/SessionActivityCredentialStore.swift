import Foundation
import Security

protocol SessionActivityCredentialStoring {
    func credential(for accountID: UUID) throws -> String?
    func saveCredential(_ credential: String, for accountID: UUID) throws
    func deleteCredential(for accountID: UUID) throws
    func deleteAllCredentials() throws
}

protocol SessionActivitySecurityClient {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(
        _ query: [String: Any],
        attributesToUpdate: [String: Any]
    ) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

struct SystemSessionActivitySecurityClient: SessionActivitySecurityClient {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?) {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(
        _ query: [String: Any],
        attributesToUpdate: [String: Any]
    ) -> OSStatus {
        SecItemUpdate(
            query as CFDictionary,
            attributesToUpdate as CFDictionary
        )
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

enum SessionActivityCredentialStoreError: LocalizedError, Equatable {
    case invalidCredential
    case invalidStoredCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "activity.errorInvalidCredential".localized()
        case .invalidStoredCredential:
            return "activity.errorInvalidStoredCredential".localized()
        case .keychain(let status):
            return "activity.errorKeychainFormat".localized(status)
        }
    }
}

/// Stores one GitHub Agent Tasks credential per immutable provider-account
/// UUID. The stable service name intentionally does not depend on a mutable
/// bundle identifier. Credentials stay on this device and become available
/// after its first unlock following boot.
final class SessionActivityCredentialStore: SessionActivityCredentialStoring {
    static let service =
        "com.jimboha.agentlimits-forked.session-activity.github-agent-tasks"

    private static let maximumCredentialBytes = 16 * 1_024
    private let securityClient: any SessionActivitySecurityClient

    init(
        securityClient: any SessionActivitySecurityClient =
            SystemSessionActivitySecurityClient()
    ) {
        self.securityClient = securityClient
    }

    func credential(for accountID: UUID) throws -> String? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = securityClient.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credential = String(data: data, encoding: .utf8),
                  isValidStoredCredential(credential) else {
                throw SessionActivityCredentialStoreError
                    .invalidStoredCredential
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw SessionActivityCredentialStoreError.keychain(status)
        }
    }

    func saveCredential(
        _ credential: String,
        for accountID: UUID
    ) throws {
        let normalized = try normalize(credential)
        let credentialData = Data(normalized.utf8)
        var attributes = baseQuery(for: accountID)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = credentialData

        let addStatus = securityClient.add(attributes)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let replacement: [String: Any] = [
                kSecAttrAccessible as String:
                    kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                kSecValueData as String: credentialData
            ]
            let updateStatus = securityClient.update(
                baseQuery(for: accountID),
                attributesToUpdate: replacement
            )
            switch updateStatus {
            case errSecSuccess:
                return
            case errSecItemNotFound:
                // Another process may have deleted the item between add and
                // update. One bounded add retry safely resolves that race.
                let retryStatus = securityClient.add(attributes)
                guard retryStatus == errSecSuccess else {
                    throw SessionActivityCredentialStoreError
                        .keychain(retryStatus)
                }
            default:
                throw SessionActivityCredentialStoreError
                    .keychain(updateStatus)
            }
        default:
            throw SessionActivityCredentialStoreError.keychain(addStatus)
        }
    }

    func deleteCredential(for accountID: UUID) throws {
        let status = securityClient.delete(baseQuery(for: accountID))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionActivityCredentialStoreError.keychain(status)
        }
    }

    /// Deletes only credentials owned by this feature's stable Keychain
    /// service. It cannot match generic-password items from other features.
    func deleteAllCredentials() throws {
        let status = securityClient.delete(serviceQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SessionActivityCredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(for accountID: UUID) -> [String: Any] {
        var query = serviceQuery
        query[kSecAttrAccount as String] =
            accountID.uuidString.lowercased()
        return query
    }

    private var serviceQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            // macOS applies kSecAttrAccessible semantics only when using its
            // Data Protection keychain (or synchronizable items). This item is
            // intentionally local, so select Data Protection explicitly.
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrService as String: Self.service
        ]
    }

    private func normalize(_ credential: String) throws -> String {
        let normalized = credential.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard isValidStoredCredential(normalized) else {
            throw SessionActivityCredentialStoreError.invalidCredential
        }
        return normalized
    }

    private func isValidStoredCredential(_ credential: String) -> Bool {
        let bytes = credential.utf8
        return !credential.isEmpty
            && bytes.count <= Self.maximumCredentialBytes
            && !credential.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
            && !credential.contains(where: { $0.isWhitespace })
    }
}
