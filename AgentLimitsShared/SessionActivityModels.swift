import Foundation

/// Describes what a current-activity count covers. Counts from different
/// scopes must never be presented as equivalent account-wide session totals.
enum SessionActivityScope: String, Codable, Equatable, Hashable {
    case loginDevices
    case localRuntime
    /// Cloud-agent sessions visible to the supplied credential, which may be
    /// narrower than every session owned by the login.
    case cloudAgentSessions
    case managedAgents
}

/// Whether current-activity counts are exact, unavailable, or retained from a
/// prior successful observation.
enum SessionActivityAvailability: String, Codable, Equatable, Hashable {
    case available
    case unsupported
    /// A credential is absent, rejected, or lacks the required permission.
    case authenticationRequired
    case stale
    case error
}

/// Provider-neutral current activity for one immutable provider-account UUID.
/// Nil counts mean that no truthful count is available; they must not render as
/// zero. `observedAt` is the time represented by the counts, so stale snapshots
/// deliberately preserve their prior successful timestamp.
struct SessionActivitySnapshot: Equatable, Hashable, Identifiable {
    let accountID: UUID
    let provider: UsageProvider
    let scope: SessionActivityScope
    let working: Int?
    let waiting: Int?
    let open: Int?
    let availability: SessionActivityAvailability
    let observedAt: Date

    var id: UUID { accountID }

    private init(
        accountID: UUID,
        provider: UsageProvider,
        scope: SessionActivityScope,
        working: Int?,
        waiting: Int?,
        open: Int?,
        availability: SessionActivityAvailability,
        observedAt: Date
    ) {
        let hasAllCounts = working != nil && waiting != nil && open != nil
        let hasNoCounts = working == nil && waiting == nil && open == nil
        precondition(
            availability == .available || availability == .stale
                ? hasAllCounts
                : hasNoCounts,
            "Snapshot availability and counts must agree"
        )
        if let working, let waiting, let open {
            precondition(
                working >= 0 && waiting >= 0 && open == working + waiting,
                "Snapshot counts must be nonnegative and internally consistent"
            )
        }
        self.accountID = accountID
        self.provider = provider
        self.scope = scope
        self.working = working
        self.waiting = waiting
        self.open = open
        self.availability = availability
        self.observedAt = observedAt
    }

    static func available(
        account: ProviderAccount,
        counts: SessionActivityCounts,
        observedAt: Date
    ) -> SessionActivitySnapshot {
        SessionActivitySnapshot(
            accountID: account.id,
            provider: account.provider,
            scope: account.provider.sessionActivityScope,
            working: counts.working,
            waiting: counts.waiting,
            open: counts.open,
            availability: .available,
            observedAt: observedAt
        )
    }

    static func unavailable(
        account: ProviderAccount,
        availability: SessionActivityAvailability,
        observedAt: Date
    ) -> SessionActivitySnapshot {
        precondition(
            availability != .available && availability != .stale,
            "Unavailable snapshots cannot claim available or stale counts"
        )
        return SessionActivitySnapshot(
            accountID: account.id,
            provider: account.provider,
            scope: account.provider.sessionActivityScope,
            working: nil,
            waiting: nil,
            open: nil,
            availability: availability,
            observedAt: observedAt
        )
    }

    func markingStale() -> SessionActivitySnapshot {
        precondition(
            working != nil && waiting != nil && open != nil,
            "Only a counted snapshot can become stale"
        )
        return SessionActivitySnapshot(
            accountID: accountID,
            provider: provider,
            scope: scope,
            working: working,
            waiting: waiting,
            open: open,
            availability: .stale,
            observedAt: observedAt
        )
    }
}

/// Exact counts returned by one provider-specific current-activity source.
nonisolated struct SessionActivityCounts: Equatable, Hashable, Sendable {
    let working: Int
    let waiting: Int

    var open: Int { working + waiting }

    init(working: Int, waiting: Int) {
        precondition(working >= 0 && waiting >= 0, "Activity counts cannot be negative")
        self.working = working
        self.waiting = waiting
    }
}

extension UsageProvider {
    var sessionActivityScope: SessionActivityScope {
        switch self {
        case .chatgptCodex, .claudeCode:
            return .localRuntime
        case .githubCopilot:
            // Repository restrictions can make the total narrower than every
            // cloud-agent session owned by the GitHub login.
            return .cloudAgentSessions
        }
    }
}
