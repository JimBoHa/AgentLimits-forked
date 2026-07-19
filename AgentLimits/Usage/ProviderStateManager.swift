// MARK: - ProviderStateManager.swift
// Manages per-provider state for usage data fetching.
// Separates state management concerns from UsageViewModel.

import Foundation

// MARK: - Provider State

/// Last fetch outcome for usage data.
enum ProviderFetchStatus: Equatable {
    case notFetched
    case success(Date)
    case failure(String)
}

/// Internal state for each provider
struct ProviderState {
    var snapshot: UsageSnapshot?
    var statusMessage: String
    var isFetching: Bool
    var isAutoRefreshEnabled: Bool?
    var lastFetchStatus: ProviderFetchStatus

    /// Creates a default state with optional snapshot
    static func initial(snapshot: UsageSnapshot? = nil) -> ProviderState {
        let fetchStatus: ProviderFetchStatus
        if let snapshot {
            fetchStatus = .success(snapshot.fetchedAt)
        } else {
            fetchStatus = .notFetched
        }
        return ProviderState(
            snapshot: snapshot,
            statusMessage: snapshot == nil ? "status.notFetched".localized() : "status.updated".localized(),
            isFetching: false,
            isAutoRefreshEnabled: nil,
            lastFetchStatus: fetchStatus
        )
    }
}

// MARK: - Provider State Manager

/// Manages independent runtime state for every immutable account UUID.
@MainActor
final class ProviderStateManager {
    private var statesByAccountID: [UUID: ProviderState] = [:]
    private var accountsByID: [UUID: ProviderAccount] = [:]

    /// Callback for state changes (used by ViewModel for objectWillChange)
    var onStateChange: ((UUID) -> Void)?

    // MARK: - Initialization

    init(accounts: [ProviderAccount] = []) {
        synchronizeAccounts(accounts)
    }

    /// Adds new accounts, refreshes mutable metadata, and removes stale state.
    func synchronizeAccounts(_ accounts: [ProviderAccount]) {
        let incomingIDs = Set(accounts.map(\.id))
        statesByAccountID = statesByAccountID.filter {
            incomingIDs.contains($0.key)
        }
        accountsByID = Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, $0)
        })
        for account in accounts where statesByAccountID[account.id] == nil {
            statesByAccountID[account.id] = .initial()
        }
    }

    /// Initializes every account from its isolated snapshot namespace.
    func loadCachedSnapshots(
        for accounts: [ProviderAccount],
        from repository: any AccountUsageSnapshotRepository
    ) {
        synchronizeAccounts(accounts)
        for account in accounts {
            statesByAccountID[account.id] = .initial(
                snapshot: repository.loadSnapshot(for: account)
            )
        }
    }

    // MARK: - State Access

    func getState(for accountID: UUID) -> ProviderState {
        statesByAccountID[accountID] ?? .initial()
    }

    var snapshotsByAccountID: [UUID: UsageSnapshot] {
        statesByAccountID.compactMapValues(\.snapshot)
    }

    var accountIDs: Set<UUID> {
        Set(accountsByID.keys)
    }

    var accounts: [ProviderAccount] {
        accountsByID.values.sorted(by: Self.accountSort)
    }

    func account(id: UUID) -> ProviderAccount? {
        accountsByID[id]
    }

    func selectedSnapshots(
        for accountsByProvider: [UsageProvider: ProviderAccount]
    ) -> [UsageProvider: UsageSnapshot] {
        accountsByProvider.compactMapValues {
            statesByAccountID[$0.id]?.snapshot
        }
    }

    func selectedFetchStatuses(
        for accountsByProvider: [UsageProvider: ProviderAccount]
    ) -> [UsageProvider: ProviderFetchStatus] {
        accountsByProvider.mapValues {
            statesByAccountID[$0.id]?.lastFetchStatus ?? .notFetched
        }
    }

    func hasLoginHistory(for accountID: UUID) -> Bool {
        statesByAccountID[accountID]?.snapshot != nil
    }

    /// Every enabled account with fetch history remains independently active.
    var backgroundActiveAccounts: [ProviderAccount] {
        accountsByID.values
            .filter { $0.isEnabled && hasLoginHistory(for: $0.id) }
            .sorted(by: Self.accountSort)
    }

    // MARK: - State Updates

    func setState(_ state: ProviderState, for accountID: UUID) {
        guard accountsByID[accountID] != nil else { return }
        statesByAccountID[accountID] = state
        onStateChange?(accountID)
    }

    func setSnapshot(_ snapshot: UsageSnapshot?, for accountID: UUID) {
        var state = getState(for: accountID)
        state.snapshot = snapshot
        setState(state, for: accountID)
    }

    func clearLoginHistory(for accountID: UUID) {
        var state = ProviderState.initial()
        state.isAutoRefreshEnabled = false
        setState(state, for: accountID)
    }

    func setFetching(_ isFetching: Bool, for accountID: UUID) {
        var state = getState(for: accountID)
        state.isFetching = isFetching
        setState(state, for: accountID)
    }

    func setStatusMessage(_ message: String, for accountID: UUID) {
        var state = getState(for: accountID)
        state.statusMessage = message
        setState(state, for: accountID)
    }

    func setFetchStatus(_ status: ProviderFetchStatus, for accountID: UUID) {
        var state = getState(for: accountID)
        state.lastFetchStatus = status
        setState(state, for: accountID)
    }

    func setAutoRefreshEnabled(_ enabled: Bool?, for accountID: UUID) {
        var state = getState(for: accountID)
        state.isAutoRefreshEnabled = enabled
        setState(state, for: accountID)
    }

    func updateAfterSuccessfulFetch(
        snapshot: UsageSnapshot,
        for accountID: UUID
    ) {
        var state = getState(for: accountID)
        state.snapshot = snapshot
        state.lastFetchStatus = .success(snapshot.fetchedAt)
        state.isAutoRefreshEnabled = true
        setState(state, for: accountID)
    }

    // MARK: - Auto Refresh Eligibility

    func autoRefreshEligibleAccounts(
        selectedAccountIDs: Set<UUID>
    ) -> [ProviderAccount] {
        accountsByID.values
            .filter { account in
                guard account.isEnabled else { return false }
                let isEnabled = statesByAccountID[account.id]?.isAutoRefreshEnabled
                return isEnabled == true
                    || (isEnabled == nil && selectedAccountIDs.contains(account.id))
            }
            .sorted(by: Self.accountSort)
    }

    private static func accountSort(
        _ left: ProviderAccount,
        _ right: ProviderAccount
    ) -> Bool {
        if left.provider != right.provider {
            return left.provider.rawValue < right.provider.rawValue
        }
        if left.createdAt != right.createdAt {
            return left.createdAt < right.createdAt
        }
        return left.id.uuidString < right.id.uuidString
    }
}
