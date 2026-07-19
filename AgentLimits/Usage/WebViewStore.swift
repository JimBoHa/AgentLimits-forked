// MARK: - WebViewStore.swift
// Manages WKWebView lifecycle and page-ready state detection.
// Handles popup windows for OAuth login flows.

import SwiftUI
import Combine
import WebKit

// MARK: - WebView Store

/// Manages a WKWebView instance for a specific provider.
/// Tracks page-ready state and handles popup windows for OAuth.
@MainActor
final class WebViewStore: ObservableObject {
    let account: ProviderAccount
    let webView: WKWebView
    let websiteDataStore: WKWebsiteDataStore
    let usageURL: URL
    let provider: UsageProvider
    @Published var isPageReady = false
    @Published var popupWebView: WKWebView?
    @Published var cookieChangeToken = UUID()
    private(set) var isSuspended: Bool
    let targetHost: String
    private var coordinator: WebViewCoordinator?
    private let cookieStore: WKHTTPCookieStore
    private var cookieObserver: CookieObserver?
    /// Pool-owned guard that blocks navigation while website data is clearing.
    var isNavigationAllowed: (() -> Bool)?
    /// Callback invoked when popup navigation finishes. Returns true if popup should close.
    var onPopupNavigationFinished: ((WKWebView) async -> Bool)?
    private var isClosingPopup = false
    private(set) var isDataClearInProgress = false
    private var dataClearWebViews: [ObjectIdentifier: WKWebView] = [:]
    private var pendingDataClearWebViews: Set<ObjectIdentifier> = []
    private var pendingDataClearNavigations: [ObjectIdentifier: WKNavigation] = [:]
    private var permittedBlankNavigations: Set<ObjectIdentifier> = []
    private var dataClearFailed = false
    private var dataClearContinuation: CheckedContinuation<Bool, Never>?
    private var dataClearTimeoutTask: Task<Void, Never>?

    var isAwaitingDataClearQuiescence: Bool {
        dataClearContinuation != nil
    }

    init(
        account: ProviderAccount,
        websiteDataStore: WKWebsiteDataStore,
        loadImmediately: Bool = true
    ) {
        self.account = account
        self.provider = account.provider
        self.websiteDataStore = websiteDataStore
        self.isSuspended = !loadImmediately
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let cookieStore = configuration.websiteDataStore.httpCookieStore
        self.webView = WKWebView(frame: .zero, configuration: configuration)
        self.usageURL = account.provider.usageURL
        self.targetHost = account.provider.usageHost
        self.cookieStore = cookieStore
        let coordinator = WebViewCoordinator(store: self)
        self.coordinator = coordinator
        self.webView.navigationDelegate = coordinator
        self.webView.uiDelegate = coordinator
        let observer = CookieObserver(store: self)
        self.cookieObserver = observer
        cookieStore.add(observer)
        if loadImmediately {
            loadIfNeeded()
        }
    }

    deinit {
        if let observer = cookieObserver {
            MainActor.assumeIsolated {
                cookieStore.remove(observer)
            }
        }
    }

    /// Loads the usage URL if not already loaded
    func loadIfNeeded() {
        guard !isSuspended, !isDataClearInProgress else { return }
        guard isNavigationAllowed?() != false else { return }
        if webView.url == nil {
            // Initial navigation to provider usage page.
            webView.load(URLRequest(url: usageURL))
        }
    }

    /// Reloads the usage URL, ignoring cache
    func reloadFromOrigin() {
        guard !isDataClearInProgress else { return }
        guard isNavigationAllowed?() != false else { return }
        // Reset readiness and force a fresh load.
        isSuspended = false
        isPageReady = false
        let request = URLRequest(
            url: usageURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 60
        )
        webView.load(request)
    }

    /// 非アクティブなログインページがバックグラウンドで動き続けないようにWebViewを停止する。
    func suspend() {
        guard !isDataClearInProgress else { return }
        isSuspended = true
        isPageReady = false
        closePopupWebView()
        webView.stopLoading()
        if webView.url != nil, !Self.isBlankURL(webView.url) {
            loadBlankPage(in: webView)
        }
    }

    /// プロバイダーの使用状況ページを読み込んでWebViewを復帰する。
    func resume() {
        guard isSuspended else { return }
        guard !isDataClearInProgress else { return }
        guard isNavigationAllowed?() != false else { return }
        isSuspended = false
        reloadFromOrigin()
    }

    /// Closes any open popup WebView
    func closePopupWebView() {
        // Prevent duplicate close calls.
        guard !isClosingPopup else { return }
        isClosingPopup = true
        // Stop any popup loading and release the reference.
        if let popupWebView {
            popupWebView.stopLoading()
            popupWebView.navigationDelegate = nil
            popupWebView.uiDelegate = nil
        }
        popupWebView = nil
        onPopupNavigationFinished = nil
        isClosingPopup = false
    }

    /// Stops all page activity and closes the visible popup before the pool
    /// starts removing shared WebKit data.
    func beginDataClear() {
        guard !isDataClearInProgress else { return }
        isDataClearInProgress = true
        isSuspended = true
        isPageReady = false
        onPopupNavigationFinished = nil

        var webViews = [webView]
        if let popupWebView {
            webViews.append(popupWebView)
        }
        popupWebView = nil

        dataClearWebViews = Dictionary(
            uniqueKeysWithValues: webViews.map { (ObjectIdentifier($0), $0) }
        )
        permittedBlankNavigations.formUnion(dataClearWebViews.keys)
        for webView in webViews {
            webView.stopLoading()
        }
    }

    /// Navigates every retained page and popup to a blank document and waits
    /// for those navigations to finish. Provider redirects and new popups stay
    /// denied for the entire clear interval.
    func quiesceForDataClear(timeout: Duration) async -> Bool {
        guard isDataClearInProgress, dataClearContinuation == nil else { return false }

        // Always commit a fresh blank navigation, even when WebKit has not yet
        // reflected a just-scheduled navigation in `url` or `isLoading`.
        pendingDataClearWebViews = Set(dataClearWebViews.keys)
        pendingDataClearNavigations.removeAll()
        dataClearFailed = false

        return await withCheckedContinuation { continuation in
            dataClearContinuation = continuation
            dataClearTimeoutTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.completeDataClearQuiescence(success: false)
            }

            let identifiersToQuiesce = pendingDataClearWebViews
            for identifier in identifiersToQuiesce {
                guard let webView = dataClearWebViews[identifier] else {
                    resolveDataClearNavigation(for: identifier, succeeded: false)
                    continue
                }
                guard let navigation = webView.load(URLRequest(url: Self.blankURL)) else {
                    resolveDataClearNavigation(for: identifier, succeeded: false)
                    continue
                }
                pendingDataClearNavigations[identifier] = navigation
            }
        }
    }

    /// Releases clear-only popup WebViews after website data removal finishes.
    func finishDataClear() {
        guard isDataClearInProgress else { return }
        if dataClearContinuation != nil {
            completeDataClearQuiescence(success: false)
        }
        dataClearTimeoutTask?.cancel()
        dataClearTimeoutTask = nil

        for webView in dataClearWebViews.values where webView !== self.webView {
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
        }
        permittedBlankNavigations.subtract(dataClearWebViews.keys)
        dataClearWebViews.removeAll()
        pendingDataClearWebViews.removeAll()
        pendingDataClearNavigations.removeAll()
        dataClearFailed = false
        isDataClearInProgress = false
    }

    /// Central navigation policy used by both app-triggered and page-triggered
    /// navigations.
    func shouldAllowNavigation(in webView: WKWebView, to url: URL?) -> Bool {
        let identifier = ObjectIdentifier(webView)
        if permittedBlankNavigations.contains(identifier), Self.isBlankURL(url) {
            return true
        }
        guard !isDataClearInProgress, !isSuspended else { return false }
        guard isNavigationAllowed?() != false else { return false }
        return webView === self.webView || webView === popupWebView
    }

    func shouldCreatePopup(from webView: WKWebView) -> Bool {
        guard !isDataClearInProgress, !isSuspended else { return false }
        guard isNavigationAllowed?() != false else { return false }
        return webView === self.webView || webView === popupWebView
    }

    /// OAuth popups must inherit the opener account's cookie boundary even if
    /// WebKit supplies a configuration with a different default.
    func configurePopup(_ configuration: WKWebViewConfiguration) {
        configuration.websiteDataStore = websiteDataStore
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
    }

    func navigationDidFinish(in webView: WKWebView, navigation: WKNavigation?) {
        let identifier = ObjectIdentifier(webView)
        if isDataClearInProgress, dataClearWebViews[identifier] != nil {
            guard isPendingDataClearNavigation(navigation, for: identifier) else { return }
            guard Self.isBlankURL(webView.url) else { return }
            resolveDataClearNavigation(for: identifier, succeeded: true)
            isPageReady = false
            return
        }

        if permittedBlankNavigations.remove(identifier) != nil {
            isPageReady = false
            return
        }

        if webView === self.webView {
            isPageReady = webView.url?.host == targetHost
        } else if webView === popupWebView {
            // Check login status when popup navigation finishes.
            Task {
                if let callback = onPopupNavigationFinished,
                   await callback(webView) {
                    // Wait before closing to allow redirect processing.
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    closePopupWebView()
                }
            }
        }
    }

    func navigationDidFail(in webView: WKWebView, navigation: WKNavigation?) {
        let identifier = ObjectIdentifier(webView)
        if isDataClearInProgress, dataClearWebViews[identifier] != nil {
            if isPendingDataClearNavigation(navigation, for: identifier) {
                resolveDataClearNavigation(for: identifier, succeeded: false)
            }
        } else {
            permittedBlankNavigations.remove(identifier)
        }
        if webView === self.webView {
            isPageReady = false
        }
    }

    func webContentProcessDidTerminate(in webView: WKWebView) {
        let identifier = ObjectIdentifier(webView)
        if isDataClearInProgress, dataClearWebViews[identifier] != nil {
            // A terminated content process cannot continue mutating website data.
            resolveDataClearNavigation(for: identifier, succeeded: true)
        }
        if webView === self.webView {
            isPageReady = false
        }
    }

    private func loadBlankPage(in webView: WKWebView) {
        let identifier = ObjectIdentifier(webView)
        permittedBlankNavigations.insert(identifier)
        if webView.load(URLRequest(url: Self.blankURL)) == nil {
            permittedBlankNavigations.remove(identifier)
        }
    }

    private func resolveDataClearNavigation(
        for identifier: ObjectIdentifier,
        succeeded: Bool
    ) {
        guard pendingDataClearWebViews.remove(identifier) != nil else { return }
        pendingDataClearNavigations.removeValue(forKey: identifier)
        dataClearFailed = dataClearFailed || !succeeded
        guard pendingDataClearWebViews.isEmpty else { return }
        completeDataClearQuiescence(success: !dataClearFailed)
    }

    private func completeDataClearQuiescence(success: Bool) {
        guard let continuation = dataClearContinuation else { return }
        dataClearContinuation = nil
        dataClearTimeoutTask?.cancel()
        dataClearTimeoutTask = nil
        continuation.resume(returning: success)
    }

    private func isPendingDataClearNavigation(
        _ navigation: WKNavigation?,
        for identifier: ObjectIdentifier
    ) -> Bool {
        guard let navigation,
              let pendingNavigation = pendingDataClearNavigations[identifier] else {
            return false
        }
        return navigation === pendingNavigation
    }

    private static let blankURL = URL(string: "about:blank")!

    private static func isBlankURL(_ url: URL?) -> Bool {
        url?.scheme == "about" && url?.absoluteString == blankURL.absoluteString
    }

    private final class CookieObserver: NSObject, WKHTTPCookieStoreObserver {
        private weak var store: WebViewStore?

        init(store: WebViewStore) {
            self.store = store
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in
                // Bump token to signal cookie changes to observers.
                store?.cookieChangeToken = UUID()
            }
        }
    }
}

// MARK: - SwiftUI Integration

/// NSViewRepresentable for embedding WebViewStore's WKWebView in SwiftUI
struct WebViewRepresentable: NSViewRepresentable {
    @ObservedObject var store: WebViewStore

    func makeNSView(context: Context) -> WKWebView {
        store.loadIfNeeded()
        return store.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        store.loadIfNeeded()
    }
}

// MARK: - WebView Coordinator

/// Handles WKWebView navigation events and updates page-ready state
final class WebViewCoordinator: NSObject, WKNavigationDelegate {
    private weak var store: WebViewStore?

    init(store: WebViewStore) {
        self.store = store
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === store?.webView {
            store?.isPageReady = false
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        let shouldAllow = store?.shouldAllowNavigation(
            in: webView,
            to: navigationAction.request.url
        ) == true
        decisionHandler(shouldAllow ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        store?.navigationDidFinish(in: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        store?.navigationDidFail(in: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        store?.navigationDidFail(in: webView, navigation: navigation)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        store?.webContentProcessDidTerminate(in: webView)
    }
}

// MARK: - UI Delegate (Popup Handling)

extension WebViewCoordinator: WKUIDelegate {
    /// Creates a popup WebView for OAuth login flows
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard let store else { return nil }
        guard store.shouldCreatePopup(from: webView) else { return nil }
        guard navigationAction.targetFrame == nil else { return nil }
        store.configurePopup(configuration)
        let popup = WKWebView(frame: .zero, configuration: configuration)
        popup.navigationDelegate = self
        popup.uiDelegate = self
        store.popupWebView = popup
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let store else { return }
        if webView === store.popupWebView {
            store.closePopupWebView()
        }
    }
}
