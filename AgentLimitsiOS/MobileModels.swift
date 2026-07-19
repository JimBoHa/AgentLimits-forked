import Foundation

nonisolated enum MobileProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude
    case copilot

    var id: String { rawValue }

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

    var supportsCurrentSessions: Bool {
        self == .copilot
    }
}

nonisolated struct MobileProviderAccount: Codable, Equatable, Hashable, Identifiable, Sendable {
    static let maximumLabelLength = 80

    let id: UUID
    let provider: MobileProvider
    let createdAt: Date
    var label: String
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        provider: MobileProvider,
        label: String,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.createdAt = createdAt
        self.label = Self.normalizedLabel(label, provider: provider)
        self.isEnabled = isEnabled
    }

    func updating(label: String, isEnabled: Bool) -> MobileProviderAccount {
        MobileProviderAccount(
            id: id,
            provider: provider,
            label: label,
            isEnabled: isEnabled,
            createdAt: createdAt
        )
    }

    static func normalizedLabel(
        _ value: String,
        provider: MobileProvider
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = trimmed.isEmpty ? provider.displayName : trimmed
        return String(resolved.prefix(maximumLabelLength))
    }
}

nonisolated struct MobileAccountCatalogSnapshot: Equatable, Sendable {
    let provider: MobileProvider
    let accounts: [MobileProviderAccount]
}

/// Exact counts returned by GitHubAgentTaskFetcher. This shape intentionally
/// matches the shared fetcher's dependency without importing macOS models.
nonisolated struct SessionActivityCounts: Equatable, Hashable, Sendable {
    let working: Int
    let waiting: Int

    var open: Int { working + waiting }

    init(working: Int, waiting: Int) {
        precondition(working >= 0 && waiting >= 0)
        self.working = working
        self.waiting = waiting
    }
}

nonisolated enum MobileSessionAvailability: String, Codable, Equatable, Sendable {
    case notChecked
    case available
    case stale
    case unsupported
    case authenticationRequired
    case insufficientPermissions
    case rateLimited
    case unavailable
}

nonisolated struct MobileSessionActivitySnapshot:
    Codable,
    Equatable,
    Hashable,
    Identifiable,
    Sendable {
    let accountID: UUID
    let provider: MobileProvider
    let availability: MobileSessionAvailability
    let working: Int?
    let waiting: Int?
    let open: Int?
    let observedAt: Date?
    let retryAt: Date?

    var id: UUID { accountID }

    private init(
        accountID: UUID,
        provider: MobileProvider,
        availability: MobileSessionAvailability,
        working: Int?,
        waiting: Int?,
        open: Int?,
        observedAt: Date?,
        retryAt: Date? = nil
    ) {
        Self.assertValid(
            availability: availability,
            working: working,
            waiting: waiting,
            open: open,
            observedAt: observedAt,
            retryAt: retryAt
        )
        self.accountID = accountID
        self.provider = provider
        self.availability = availability
        self.working = working
        self.waiting = waiting
        self.open = open
        self.observedAt = observedAt
        self.retryAt = retryAt
    }

    static func notChecked(account: MobileProviderAccount) -> Self {
        unavailable(account: account, availability: .notChecked)
    }

    static func available(
        account: MobileProviderAccount,
        counts: SessionActivityCounts,
        observedAt: Date
    ) -> Self {
        Self(
            accountID: account.id,
            provider: account.provider,
            availability: .available,
            working: counts.working,
            waiting: counts.waiting,
            open: counts.open,
            observedAt: observedAt,
            retryAt: nil
        )
    }

    static func unavailable(
        account: MobileProviderAccount,
        availability: MobileSessionAvailability
    ) -> Self {
        precondition(
            availability != .available
                && availability != .stale
                && availability != .rateLimited
        )
        return Self(
            accountID: account.id,
            provider: account.provider,
            availability: availability,
            working: nil,
            waiting: nil,
            open: nil,
            observedAt: nil,
            retryAt: nil
        )
    }

    static func rateLimited(
        account: MobileProviderAccount,
        previous: Self?,
        retryAt: Date
    ) -> Self {
        let hasCounts = previous?.working != nil
            && previous?.waiting != nil
            && previous?.open != nil
            && previous?.observedAt != nil
        return Self(
            accountID: account.id,
            provider: account.provider,
            availability: .rateLimited,
            working: hasCounts ? previous?.working : nil,
            waiting: hasCounts ? previous?.waiting : nil,
            open: hasCounts ? previous?.open : nil,
            observedAt: hasCounts ? previous?.observedAt : nil,
            retryAt: retryAt
        )
    }

    func markingStale() -> Self {
        precondition(working != nil && waiting != nil && open != nil)
        return Self(
            accountID: accountID,
            provider: provider,
            availability: .stale,
            working: working,
            waiting: waiting,
            open: open,
            observedAt: observedAt,
            retryAt: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case accountID
        case provider
        case availability
        case working
        case waiting
        case open
        case observedAt
        case retryAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let accountID = try container.decode(UUID.self, forKey: .accountID)
        let provider = try container.decode(MobileProvider.self, forKey: .provider)
        let availability = try container.decode(
            MobileSessionAvailability.self,
            forKey: .availability
        )
        let working = try container.decodeIfPresent(Int.self, forKey: .working)
        let waiting = try container.decodeIfPresent(Int.self, forKey: .waiting)
        let open = try container.decodeIfPresent(Int.self, forKey: .open)
        let observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
        let retryAt = try container.decodeIfPresent(Date.self, forKey: .retryAt)

        guard Self.isValid(
            availability: availability,
            working: working,
            waiting: waiting,
            open: open,
            observedAt: observedAt,
            retryAt: retryAt
        ) else {
            throw DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Activity snapshot fields are inconsistent."
                )
            )
        }

        self.accountID = accountID
        self.provider = provider
        self.availability = availability
        self.working = working
        self.waiting = waiting
        self.open = open
        self.observedAt = observedAt
        self.retryAt = retryAt
    }

    private static func assertValid(
        availability: MobileSessionAvailability,
        working: Int?,
        waiting: Int?,
        open: Int?,
        observedAt: Date?,
        retryAt: Date?
    ) {
        precondition(
            isValid(
                availability: availability,
                working: working,
                waiting: waiting,
                open: open,
                observedAt: observedAt,
                retryAt: retryAt
            )
        )
    }

    private static func isValid(
        availability: MobileSessionAvailability,
        working: Int?,
        waiting: Int?,
        open: Int?,
        observedAt: Date?,
        retryAt: Date?
    ) -> Bool {
        switch availability {
        case .available, .stale:
            guard let working, let waiting, let open, observedAt != nil,
                  retryAt == nil, working >= 0, waiting >= 0 else {
                return false
            }
            let (total, overflow) = working.addingReportingOverflow(waiting)
            return !overflow && open == total
        case .rateLimited:
            guard retryAt != nil else { return false }
            let values = [working, waiting, open]
            if values.allSatisfy({ $0 == nil }) {
                return observedAt == nil
            }
            guard let working, let waiting, let open, observedAt != nil,
                  working >= 0, waiting >= 0 else {
                return false
            }
            let (total, overflow) = working.addingReportingOverflow(waiting)
            return !overflow && open == total
        case .notChecked, .unsupported, .authenticationRequired,
             .insufficientPermissions, .unavailable:
            return working == nil
                && waiting == nil
                && open == nil
                && observedAt == nil
                && retryAt == nil
        }
    }
}

nonisolated struct MobileProviderActivitySnapshot: Equatable, Sendable {
    let provider: MobileProvider
    let accounts: [MobileSessionActivitySnapshot]
}
