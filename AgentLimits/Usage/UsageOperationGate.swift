// MARK: - UsageOperationGate.swift
// Coordinates async usage operations across destructive data clearing.

import Foundation

/// Issues generation-scoped tokens for usage work that may suspend.
///
/// Clearing advances the generation and blocks new work until WebKit data has
/// also been removed. Callers must validate their token after every suspension
/// and before committing side effects.
struct UsageOperationGate {
    struct Context: Equatable {
        fileprivate let generation: UInt64
    }

    struct FetchToken: Equatable {
        fileprivate let context: Context
        fileprivate let provider: UsageProvider
        fileprivate let identifier: UInt64
    }

    struct ClearToken: Equatable {
        fileprivate let generation: UInt64
    }

    private var generation: UInt64 = 0
    private var nextIdentifier: UInt64 = 0
    private var isClearing = false
    private var activeFetches: [UsageProvider: FetchToken] = [:]

    /// Captures the current generation for login, recovery, or related work.
    func captureContext() -> Context? {
        guard !isClearing else { return nil }
        return Context(generation: generation)
    }

    /// Returns whether non-fetch work may still commit side effects.
    func isCurrent(_ context: Context) -> Bool {
        !isClearing && context.generation == generation
    }

    /// Starts one fetch for a provider in the supplied generation.
    mutating func beginFetch(
        for provider: UsageProvider,
        context: Context? = nil
    ) -> FetchToken? {
        guard !isClearing, activeFetches[provider] == nil else { return nil }
        let useContext = context ?? Context(generation: generation)
        guard isCurrent(useContext) else { return nil }

        nextIdentifier &+= 1
        let token = FetchToken(
            context: useContext,
            provider: provider,
            identifier: nextIdentifier
        )
        activeFetches[provider] = token
        return token
    }

    /// Returns whether this exact fetch is still the provider's active fetch.
    func isCurrent(_ token: FetchToken) -> Bool {
        isCurrent(token.context) && activeFetches[token.provider] == token
    }

    /// Finishes a fetch only when it is still the active operation.
    ///
    /// A false result tells the caller not to clear UI fetching state because a
    /// destructive clear or a newer fetch has already superseded this token.
    mutating func finishFetch(_ token: FetchToken) -> Bool {
        guard isCurrent(token), activeFetches[token.provider] == token else {
            return false
        }
        activeFetches.removeValue(forKey: token.provider)
        return true
    }

    /// Invalidates all outstanding work and starts the exclusive clear interval.
    mutating func beginClear() -> ClearToken? {
        guard !isClearing else { return nil }
        generation &+= 1
        isClearing = true
        activeFetches.removeAll()
        return ClearToken(generation: generation)
    }

    /// Ends the clear interval only for the matching clear operation.
    mutating func finishClear(_ token: ClearToken) -> Bool {
        guard isClearing, token.generation == generation else { return false }
        isClearing = false
        return true
    }
}
