import Foundation
import Security

@MainActor
protocol MobileSessionCredentialStoring: AnyObject {
    func credential(for accountID: UUID) throws -> String?
    func saveCredential(_ credential: String, for accountID: UUID) throws
    func deleteCredential(for accountID: UUID) throws
    func deleteAllCredentials() throws
}

@MainActor
protocol MobileSecurityClient {
    func copyMatching(_ query: [String: Any]) -> (OSStatus, Any?)
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(
        _ query: [String: Any],
        attributesToUpdate: [String: Any]
    ) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

@MainActor
struct SystemMobileSecurityClient: MobileSecurityClient {
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

enum MobileSessionCredentialStoreError: LocalizedError, Equatable {
    case invalidCredential
    case invalidStoredCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            return "Enter a credential without spaces or control characters."
        case .invalidStoredCredential:
            return "The saved credential is invalid. Remove it and save a new one."
        case .keychain(let status):
            return "Keychain operation failed (status \(status))."
        }
    }
}

/// Stores one non-synchronizing credential per immutable account UUID.
@MainActor
final class MobileSessionCredentialStore: MobileSessionCredentialStoring {
    static let service =
        "com.jimboha.agentlimits.ios.session-activity.github-agent-tasks"

    private static let maximumCredentialBytes = 16 * 1_024
    private let securityClient: any MobileSecurityClient

    init(
        securityClient: (any MobileSecurityClient)? = nil
    ) {
        self.securityClient = securityClient ?? SystemMobileSecurityClient()
    }

    func credential(for accountID: UUID) throws -> String? {
        var query = accountQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = securityClient.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let credential = String(data: data, encoding: .utf8),
                  isValid(credential) else {
                throw MobileSessionCredentialStoreError
                    .invalidStoredCredential
            }
            return credential
        case errSecItemNotFound:
            return nil
        default:
            throw MobileSessionCredentialStoreError.keychain(status)
        }
    }

    func saveCredential(
        _ credential: String,
        for accountID: UUID
    ) throws {
        let normalized = try normalize(credential)
        var attributes = accountQuery(for: accountID)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecValueData as String] = Data(normalized.utf8)

        let addStatus = securityClient.add(attributes)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let replacement: [String: Any] = [
                kSecAttrAccessible as String:
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrSynchronizable as String: false,
                kSecValueData as String: Data(normalized.utf8)
            ]
            let updateStatus = securityClient.update(
                accountQuery(for: accountID),
                attributesToUpdate: replacement
            )
            switch updateStatus {
            case errSecSuccess:
                return
            case errSecItemNotFound:
                let retryStatus = securityClient.add(attributes)
                guard retryStatus == errSecSuccess else {
                    throw MobileSessionCredentialStoreError.keychain(
                        retryStatus
                    )
                }
            default:
                throw MobileSessionCredentialStoreError.keychain(
                    updateStatus
                )
            }
        default:
            throw MobileSessionCredentialStoreError.keychain(addStatus)
        }
    }

    func deleteCredential(for accountID: UUID) throws {
        let status = securityClient.delete(accountQuery(for: accountID))
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobileSessionCredentialStoreError.keychain(status)
        }
    }

    func deleteAllCredentials() throws {
        let status = securityClient.delete(serviceQuery)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MobileSessionCredentialStoreError.keychain(status)
        }
    }

    private var serviceQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrSynchronizable as String: false
        ]
    }

    private func accountQuery(for accountID: UUID) -> [String: Any] {
        var query = serviceQuery
        query[kSecAttrAccount as String] =
            accountID.uuidString.lowercased()
        return query
    }

    private func normalize(_ credential: String) throws -> String {
        let normalized = credential.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard isValid(normalized) else {
            throw MobileSessionCredentialStoreError.invalidCredential
        }
        return normalized
    }

    private func isValid(_ credential: String) -> Bool {
        let bytes = credential.utf8
        return !credential.isEmpty
            && bytes.count <= Self.maximumCredentialBytes
            && !credential.contains(where: { $0.isWhitespace })
            && !credential.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }
}
