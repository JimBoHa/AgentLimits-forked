// MARK: - UsageWebViewPool.swift
// Manages a pool of WebViewStore instances for each provider.
// Handles data clearing and WebView lifecycle management.

import Combine
import WebKit

// MARK: - WebView Pool

/// Manages WebViewStore instances for each provider.
/// Provides shared access and handles data clearing.
@MainActor
final class UsageWebViewPool: ObservableObject {
    private var webViewStoreByProvider: [UsageProvider: WebViewStore]

    init(providers: [UsageProvider] = UsageProvider.allCases) {
        var stores: [UsageProvider: WebViewStore] = [:]
        for provider in providers {
            stores[provider] = WebViewStore(initialProvider: provider, loadImmediately: false)
        }
        self.webViewStoreByProvider = stores
    }

    /// Returns the WebViewStore for the specified provider, creating if needed
    func getWebViewStore(for provider: UsageProvider) -> WebViewStore {
        if let existingStore = webViewStoreByProvider[provider] {
            return existingStore
        }
        // Lazily create a WebViewStore when requested.
        let newStore = WebViewStore(initialProvider: provider, loadImmediately: false)
        webViewStoreByProvider[provider] = newStore
        return newStore
    }

    /// 指定プロバイダーのWebViewを停止状態にする。
    func suspend(_ provider: UsageProvider) {
        getWebViewStore(for: provider).suspend()
    }

    /// 指定プロバイダーのWebViewを復帰する。
    func resume(_ provider: UsageProvider) {
        getWebViewStore(for: provider).resume()
    }

    /// 取得実績のあるプロバイダーだけをバックグラウンドで稼働状態に保つ。
    func applyBackgroundPolicy(activeProviders: Set<UsageProvider>) {
        for provider in UsageProvider.allCases {
            if activeProviders.contains(provider) {
                resume(provider)
            } else {
                suspend(provider)
            }
        }
    }

    /// すべてのWebサイトデータ（Cookie/キャッシュ）を削除し、必要に応じてWebViewを再読み込みする。
    func clearWebsiteData(reloadsWebViews: Bool = true) async {
        // Remove cookies/cache and refresh all web views.
        let dataStore = WKWebsiteDataStore.default()
        let dataTypes = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.removeData(ofTypes: dataTypes, modifiedSince: Date.distantPast) {
                continuation.resume()
            }
        }
        await clearHttpCookies(in: dataStore)
        if reloadsWebViews {
            reloadAllWebViews()
        }
    }

    private func clearHttpCookies(in dataStore: WKWebsiteDataStore) async {
        await withCheckedContinuation { continuation in
            dataStore.httpCookieStore.getAllCookies { cookies in
                // Explicitly delete cookies after data removal.
                for cookie in cookies {
                    dataStore.httpCookieStore.delete(cookie)
                }
                continuation.resume()
            }
        }
    }

    private func reloadAllWebViews() {
        for store in webViewStoreByProvider.values {
            store.reloadFromOrigin()
        }
    }
}
