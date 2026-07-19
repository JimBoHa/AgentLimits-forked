// MARK: - UsageOperationGate.swift
// Coordinates async usage operations across destructive data clearing.

import Foundation

/// Issues scope- and generation-bound tokens for usage work that may suspend.
///
/// Invalidating one scope leaves sibling scopes running. A global clear
/// advances the shared generation and blocks all new work until WebKit data has
/// also been removed. Callers must validate their token after every suspension
/// and before committing side effects.
struct UsageOperationGate<Scope: Hashable> {
    struct Context: Equatable {
        fileprivate let scope: Scope
        fileprivate let globalGeneration: UInt64
        fileprivate let scopeGeneration: UInt64
    }

    struct FetchToken: Equatable {
        fileprivate let context: Context
        fileprivate let identifier: UInt64
    }

    struct ClearToken: Equatable {
        fileprivate let generation: UInt64
    }

    private var globalGeneration: UInt64 = 0
    private var scopeGenerations: [Scope: UInt64] = [:]
    private var nextIdentifier: UInt64 = 0
    private var isClearing = false
    private var activeFetches: [Scope: FetchToken] = [:]

    /// Captures current global and local generations for one scope.
    func captureContext(for scope: Scope) -> Context? {
        guard !isClearing else { return nil }
        return Context(
            scope: scope,
            globalGeneration: globalGeneration,
            scopeGeneration: scopeGenerations[scope, default: 0]
        )
    }

    /// Returns whether non-fetch work may still commit side effects.
    func isCurrent(_ context: Context) -> Bool {
        !isClearing
            && context.globalGeneration == globalGeneration
            && context.scopeGeneration == scopeGenerations[context.scope, default: 0]
    }

    /// Starts one fetch for a scope in the supplied generations.
    mutating func beginFetch(
        for scope: Scope,
        context: Context? = nil
    ) -> FetchToken? {
        guard !isClearing, activeFetches[scope] == nil else { return nil }
        let useContext = context ?? Context(
            scope: scope,
            globalGeneration: globalGeneration,
            scopeGeneration: scopeGenerations[scope, default: 0]
        )
        guard useContext.scope == scope, isCurrent(useContext) else { return nil }

        nextIdentifier &+= 1
        let token = FetchToken(
            context: useContext,
            identifier: nextIdentifier
        )
        activeFetches[scope] = token
        return token
    }

    /// Returns whether this exact fetch is still the scope's active fetch.
    func isCurrent(_ token: FetchToken) -> Bool {
        isCurrent(token.context) && activeFetches[token.context.scope] == token
    }

    /// Finishes a fetch only when it is still the active operation.
    ///
    /// A false result tells the caller not to clear UI fetching state because a
    /// destructive clear or a newer fetch has already superseded this token.
    mutating func finishFetch(_ token: FetchToken) -> Bool {
        let scope = token.context.scope
        guard isCurrent(token), activeFetches[scope] == token else {
            return false
        }
        activeFetches.removeValue(forKey: scope)
        return true
    }

    /// Invalidates outstanding work for one scope without disturbing siblings.
    mutating func invalidate(scope: Scope) {
        scopeGenerations[scope, default: 0] &+= 1
        activeFetches.removeValue(forKey: scope)
    }

    /// Invalidates all outstanding work and starts the exclusive clear interval.
    mutating func beginClear() -> ClearToken? {
        guard !isClearing else { return nil }
        globalGeneration &+= 1
        isClearing = true
        scopeGenerations.removeAll(keepingCapacity: true)
        activeFetches.removeAll()
        return ClearToken(generation: globalGeneration)
    }

    /// Returns whether this exact clear still owns the exclusive interval.
    func isCurrent(_ token: ClearToken) -> Bool {
        isClearing && token.generation == globalGeneration
    }

    /// Ends the clear interval only for the matching clear operation.
    mutating func finishClear(_ token: ClearToken) -> Bool {
        guard isClearing, token.generation == globalGeneration else { return false }
        isClearing = false
        return true
    }
}
