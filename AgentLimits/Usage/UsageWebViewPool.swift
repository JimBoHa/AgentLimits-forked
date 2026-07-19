// MARK: - UsageWebViewPool.swift
// Manages a pool of WebViewStore instances for each provider.
// Handles data clearing and WebView lifecycle management.

import Combine
import WebKit

@MainActor
protocol WebsiteDataClearing {
    func clearAllWebsiteData() async throws
}

/// Production WebKit data remover. Explicit cookie deletion is awaited after
/// the broad website-data removal callback completes.
@MainActor
final class DefaultWebsiteDataClearer: WebsiteDataClearing {
    private let dataStore: WKWebsiteDataStore

    init(dataStore: WKWebsiteDataStore? = nil) {
        self.dataStore = dataStore ?? .default()
    }

    func clearAllWebsiteData() async throws {
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) {
                continuation.resume()
            }
        }

        let cookies = await dataStore.httpCookieStore.allCookies()
        for cookie in cookies {
            await dataStore.httpCookieStore.deleteCookie(cookie)
        }
    }
}

// MARK: - Activation Policy

/// Tracks background login-history needs separately from the provider that is
/// currently needed by the settings UI.
struct UsageWebViewActivationPolicy {
    private(set) var backgroundProviders: Set<UsageProvider> = []
    private(set) var foregroundProvider: UsageProvider?

    var activeProviders: Set<UsageProvider> {
        var providers = backgroundProviders
        if let foregroundProvider {
            providers.insert(foregroundProvider)
        }
        return providers
    }

    mutating func setBackgroundProviders(_ providers: Set<UsageProvider>) {
        backgroundProviders = providers
    }

    mutating func setForegroundProvider(_ provider: UsageProvider) {
        foregroundProvider = provider
    }

    mutating func clearForegroundProvider() {
        foregroundProvider = nil
    }
}

// MARK: - WebView Pool

/// Manages WebViewStore instances for each provider.
/// Provides shared access and handles data clearing.
@MainActor
final class UsageWebViewPool: ObservableObject {
    struct DataClearToken: Equatable {
        fileprivate let identifier: UInt64
    }

    enum DataClearError: LocalizedError {
        case invalidToken
        case webViewsDidNotQuiesce

        var errorDescription: String? {
            switch self {
            case .invalidToken:
                return "The website-data clear is no longer active."
            case .webViewsDidNotQuiesce:
                return "Login pages could not be stopped safely before clearing data."
            }
        }
    }

    private var webViewStoreByProvider: [UsageProvider: WebViewStore]
    private var activationPolicy = UsageWebViewActivationPolicy()
    private var activeDataClear: DataClearToken?
    private var nextDataClearIdentifier: UInt64 = 0
    private let websiteDataClearer: any WebsiteDataClearing
    private let quiescenceTimeout: Duration

    init(
        providers: [UsageProvider] = UsageProvider.allCases,
        websiteDataClearer: (any WebsiteDataClearing)? = nil,
        quiescenceTimeout: Duration = .seconds(5)
    ) {
        var stores: [UsageProvider: WebViewStore] = [:]
        for provider in providers {
            stores[provider] = WebViewStore(initialProvider: provider, loadImmediately: false)
        }
        self.webViewStoreByProvider = stores
        self.websiteDataClearer = websiteDataClearer ?? DefaultWebsiteDataClearer()
        self.quiescenceTimeout = quiescenceTimeout
        for store in stores.values {
            configureNavigationGuard(for: store)
        }
    }

    /// Returns the WebViewStore for the specified provider, creating if needed.
    func getWebViewStore(for provider: UsageProvider) -> WebViewStore {
        if let existingStore = webViewStoreByProvider[provider] {
            return existingStore
        }
        let newStore = WebViewStore(initialProvider: provider, loadImmediately: false)
        configureNavigationGuard(for: newStore)
        webViewStoreByProvider[provider] = newStore
        return newStore
    }

    /// Makes one provider active for the settings UI.
    /// During a clear this only updates the policy; no navigation occurs.
    func resume(_ provider: UsageProvider) {
        activationPolicy.setForegroundProvider(provider)
        reconcileActiveStores()
    }

    /// Releases the settings UI provider while retaining background providers.
    func clearForegroundProvider() {
        activationPolicy.clearForegroundProvider()
        reconcileActiveStores()
    }

    /// Updates providers that should remain active due to login history.
    /// During a clear this only records the latest policy.
    func applyBackgroundPolicy(activeProviders: Set<UsageProvider>) {
        activationPolicy.setBackgroundProviders(activeProviders)
        reconcileActiveStores()
    }

    /// Reloads a desired provider from its canonical origin when navigation is allowed.
    func reloadFromOrigin(_ provider: UsageProvider) {
        guard activeDataClear == nil else { return }
        guard activationPolicy.activeProviders.contains(provider) else { return }
        getWebViewStore(for: provider).reloadFromOrigin()
    }

    /// Starts an exclusive website-data clear and immediately blocks every
    /// provider navigation and popup.
    func beginDataClear() -> DataClearToken? {
        guard activeDataClear == nil else { return nil }
        nextDataClearIdentifier &+= 1
        let token = DataClearToken(identifier: nextDataClearIdentifier)
        activeDataClear = token
        for store in webViewStoreByProvider.values {
            store.beginDataClear()
        }
        return token
    }

    /// Quiesces every main page and popup before deleting shared WebKit data.
    /// Call only between beginDataClear and finishDataClear.
    func clearWebsiteData(_ token: DataClearToken) async throws {
        guard activeDataClear == token else { throw DataClearError.invalidToken }

        var allWebViewsQuiesced = true
        for store in webViewStoreByProvider.values {
            let didQuiesce = await store.quiesceForDataClear(timeout: quiescenceTimeout)
            allWebViewsQuiesced = allWebViewsQuiesced && didQuiesce
            guard activeDataClear == token else { throw DataClearError.invalidToken }
        }
        guard allWebViewsQuiesced else { throw DataClearError.webViewsDidNotQuiesce }

        try await websiteDataClearer.clearAllWebsiteData()
        guard activeDataClear == token else { throw DataClearError.invalidToken }
    }

    /// Ends a clear and restores the most recent activation policy. Policy
    /// changes received while clearing therefore win over the pre-clear state.
    @discardableResult
    func finishDataClear(_ token: DataClearToken) -> Bool {
        guard activeDataClear == token else { return false }
        for store in webViewStoreByProvider.values {
            store.finishDataClear()
        }
        activeDataClear = nil
        reconcileActiveStores()
        return true
    }

    private func configureNavigationGuard(for store: WebViewStore) {
        store.isNavigationAllowed = { [weak self] in
            guard let self else { return false }
            return self.activeDataClear == nil
        }
    }

    private func reconcileActiveStores() {
        guard activeDataClear == nil else { return }
        let desiredProviders = activationPolicy.activeProviders
        let knownProviders = Set(webViewStoreByProvider.keys).union(desiredProviders)
        for provider in knownProviders {
            let store = getWebViewStore(for: provider)
            if desiredProviders.contains(provider) {
                store.resume()
            } else {
                store.suspend()
            }
        }
    }
}
