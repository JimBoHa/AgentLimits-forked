import Foundation

nonisolated enum WatchCompanionProvider: String, Codable, CaseIterable, Sendable {
    case codex
    case claude
    case copilot

    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        case .copilot:
            return "GitHub Copilot"
        }
    }
}

nonisolated enum WatchCompanionAvailability: String, Codable, Sendable {
    case notChecked
    case available
    case stale
    case unsupported
    case authenticationRequired
    case insufficientPermissions
    case rateLimited
    case unavailable
}

nonisolated enum WatchCompanionTransportKeys {
    static let envelopeData = "agentlimits.companion.envelope"
    static let refreshAccountID = "agentlimits.companion.refresh-account-id"
}

nonisolated enum WatchCompanionTransportError: LocalizedError, Equatable {
    case payloadTooLarge(Int)
    case unsupportedVersion(Int)
    case invalidGeneratedAt
    case tooManyAccounts(Int)
    case duplicateAccountID(UUID)
    case invalidLabel(UUID)
    case inconsistentStatus(UUID)

    var errorDescription: String? {
        switch self {
        case .payloadTooLarge(let byteCount):
            return "Companion payload is too large (\(byteCount) bytes)."
        case .unsupportedVersion(let version):
            return "Companion payload version \(version) is unsupported."
        case .invalidGeneratedAt:
            return "Companion payload has an invalid generation timestamp."
        case .tooManyAccounts(let count):
            return "Companion payload has too many accounts (\(count))."
        case .duplicateAccountID(let id):
            return "Companion payload repeats account \(id.uuidString)."
        case .invalidLabel(let id):
            return "Companion payload has an invalid label for account \(id.uuidString)."
        case .inconsistentStatus(let id):
            return "Companion payload has inconsistent activity for account \(id.uuidString)."
        }
    }
}

nonisolated struct WatchCompanionAccountStatus:
    Codable,
    Equatable,
    Hashable,
    Identifiable,
    Sendable {
    static let maximumLabelLength = 80
    static let maximumLabelUTF8Bytes = maximumLabelLength * 4

    let id: UUID
    let provider: WatchCompanionProvider
    let label: String
    let isEnabled: Bool
    let availability: WatchCompanionAvailability
    let working: Int?
    let waiting: Int?
    let open: Int?
    let observedAt: Date?
    let retryAt: Date?

    init(
        id: UUID,
        provider: WatchCompanionProvider,
        label: String,
        isEnabled: Bool,
        availability: WatchCompanionAvailability,
        working: Int?,
        waiting: Int?,
        open: Int?,
        observedAt: Date?,
        retryAt: Date?
    ) throws {
        guard Self.isValidLabel(label) else {
            throw WatchCompanionTransportError.invalidLabel(id)
        }
        guard Self.hasValidStatus(
            availability: availability,
            working: working,
            waiting: waiting,
            open: open,
            observedAt: observedAt,
            retryAt: retryAt
        ) else {
            throw WatchCompanionTransportError.inconsistentStatus(id)
        }

        self.id = id
        self.provider = provider
        self.label = label
        self.isEnabled = isEnabled
        self.availability = availability
        self.working = working
        self.waiting = waiting
        self.open = open
        self.observedAt = observedAt
        self.retryAt = retryAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case provider
        case label
        case isEnabled
        case availability
        case working
        case waiting
        case open
        case observedAt
        case retryAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)

        do {
            try self.init(
                id: id,
                provider: container.decode(
                    WatchCompanionProvider.self,
                    forKey: .provider
                ),
                label: container.decode(String.self, forKey: .label),
                isEnabled: container.decode(Bool.self, forKey: .isEnabled),
                availability: container.decode(
                    WatchCompanionAvailability.self,
                    forKey: .availability
                ),
                working: container.decodeIfPresent(Int.self, forKey: .working),
                waiting: container.decodeIfPresent(Int.self, forKey: .waiting),
                open: container.decodeIfPresent(Int.self, forKey: .open),
                observedAt: container.decodeIfPresent(Date.self, forKey: .observedAt),
                retryAt: container.decodeIfPresent(Date.self, forKey: .retryAt)
            )
        } catch let error as WatchCompanionTransportError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: error.localizedDescription,
                    underlyingError: error
                )
            )
        }
    }

    private static func isValidLabel(_ label: String) -> Bool {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
            && trimmed == label
            && label.count <= maximumLabelLength
            && label.utf8.count <= maximumLabelUTF8Bytes
    }

    private static func hasValidStatus(
        availability: WatchCompanionAvailability,
        working: Int?,
        waiting: Int?,
        open: Int?,
        observedAt: Date?,
        retryAt: Date?
    ) -> Bool {
        guard isFinite(observedAt), isFinite(retryAt) else { return false }

        switch availability {
        case .available, .stale:
            return retryAt == nil
                && validExactCounts(
                    working: working,
                    waiting: waiting,
                    open: open,
                    observedAt: observedAt
                )
        case .rateLimited:
            guard retryAt != nil else { return false }
            if working == nil, waiting == nil, open == nil, observedAt == nil {
                return true
            }
            return validExactCounts(
                working: working,
                waiting: waiting,
                open: open,
                observedAt: observedAt
            )
        case .notChecked, .unsupported, .authenticationRequired,
             .insufficientPermissions, .unavailable:
            return working == nil
                && waiting == nil
                && open == nil
                && observedAt == nil
                && retryAt == nil
        }
    }

    private static func validExactCounts(
        working: Int?,
        waiting: Int?,
        open: Int?,
        observedAt: Date?
    ) -> Bool {
        guard let working, let waiting, let open, observedAt != nil,
              working >= 0, waiting >= 0 else {
            return false
        }
        let (expectedOpen, overflow) = working.addingReportingOverflow(waiting)
        return !overflow && open == expectedOpen
    }

    private static func isFinite(_ date: Date?) -> Bool {
        guard let date else { return true }
        return date.timeIntervalSinceReferenceDate.isFinite
    }
}

nonisolated struct WatchCompanionEnvelope: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let maximumAccountCount = 96
    static let maximumPayloadBytes = 256 * 1024
    static let maximumObservationClockSkew: TimeInterval = 5 * 60

    let version: Int
    let generatedAt: Date
    let accounts: [WatchCompanionAccountStatus]

    init(
        version: Int = currentVersion,
        generatedAt: Date,
        accounts: [WatchCompanionAccountStatus]
    ) throws {
        guard version == Self.currentVersion else {
            throw WatchCompanionTransportError.unsupportedVersion(version)
        }
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WatchCompanionTransportError.invalidGeneratedAt
        }
        guard accounts.count <= Self.maximumAccountCount else {
            throw WatchCompanionTransportError.tooManyAccounts(accounts.count)
        }

        var accountIDs = Set<UUID>()
        accountIDs.reserveCapacity(accounts.count)
        for account in accounts {
            guard accountIDs.insert(account.id).inserted else {
                throw WatchCompanionTransportError.duplicateAccountID(account.id)
            }
            if let observedAt = account.observedAt,
               observedAt.timeIntervalSince(generatedAt)
                > Self.maximumObservationClockSkew {
                throw WatchCompanionTransportError.inconsistentStatus(
                    account.id
                )
            }
        }

        self.version = version
        self.generatedAt = generatedAt
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case generatedAt
        case accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        do {
            try self.init(
                version: container.decode(Int.self, forKey: .version),
                generatedAt: container.decode(Date.self, forKey: .generatedAt),
                accounts: container.decode(
                    [WatchCompanionAccountStatus].self,
                    forKey: .accounts
                )
            )
        } catch let error as WatchCompanionTransportError {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: error.localizedDescription,
                    underlyingError: error
                )
            )
        }
    }

    func encodedData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumPayloadBytes else {
            throw WatchCompanionTransportError.payloadTooLarge(data.count)
        }
        return data
    }

    static func decodeValidated(_ data: Data) throws -> Self {
        guard data.count <= maximumPayloadBytes else {
            throw WatchCompanionTransportError.payloadTooLarge(data.count)
        }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
