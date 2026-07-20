// MARK: - CopilotUsageFetcher.swift
// Fetches usage data from GitHub Copilot via JavaScript injection.
// Uses the entitlement API to get premium interaction quotas.

import Foundation
import WebKit

// MARK: - API Response Models

/// Response structure from GitHub Copilot entitlement API
struct CopilotUsageResponse: Codable {
    let licenseType: String?
    let plan: String?

    struct Quotas: Codable {
        struct Limits: Codable {
            let premiumInteractions: Int?
        }

        struct Remaining: Codable {
            let premiumInteractions: Int?
            let premiumInteractionsPercentage: Double?
        }

        let limits: Limits?
        let remaining: Remaining?
        let resetDate: String?
        let overagesEnabled: Bool?
    }

    let quotas: Quotas?
}

enum CopilotUsageResponseError: Error, Equatable {
    case invalidQuota
}

extension CopilotUsageResponse {
    /// Copilot reset dates are date-only UTC billing boundaries.
    private static let billingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Date formatter for parsing resetDate ("yyyy-MM-dd")
    private static let resetDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    func toSnapshot(fetchedAt: Date) throws -> UsageSnapshot {
        let primary = try makePrimaryWindow()
        return UsageSnapshot(
            provider: .githubCopilot,
            fetchedAt: fetchedAt,
            primaryWindow: primary,
            secondaryWindow: nil
        )
    }

    private func makePrimaryWindow() throws -> UsageWindow? {
        guard let quotas else {
            return nil
        }

        let limitCount = quotas.limits?.premiumInteractions
        if let limitCount, limitCount < 0 {
            throw CopilotUsageResponseError.invalidQuota
        }

        let remainingCount = quotas.remaining?.premiumInteractions
        if let remainingCount,
           remainingCount < 0,
           quotas.overagesEnabled != true {
            // GitHub permits consumption past the included allowance only when
            // paid overages are enabled. A negative remainder otherwise cannot
            // describe a coherent entitlement.
            throw CopilotUsageResponseError.invalidQuota
        }

        let usedCount: Int?
        if let limit = limitCount, let remainder = remainingCount {
            let (difference, overflow) = limit.subtractingReportingOverflow(
                remainder
            )
            guard !overflow else {
                throw CopilotUsageResponseError.invalidQuota
            }
            // A remainder above the nominal allowance can occur after an
            // entitlement increase. Preserve the existing zero-used behavior.
            // A negative remainder with overages enabled reports usage beyond
            // the included allowance.
            usedCount = max(0, difference)
        } else {
            usedCount = nil
        }

        guard let remainingPercentage = quotas.remaining?.premiumInteractionsPercentage else {
            return nil
        }
        guard remainingPercentage.isFinite else {
            throw CopilotUsageResponseError.invalidQuota
        }

        let usedPercent = max(0, min(100, 100.0 - remainingPercentage))
        let resetAt = quotas.resetDate.flatMap { Self.resetDateFormatter.date(from: $0) }
        let limitWindowSeconds = computeLimitWindowSeconds(resetAt: resetAt)

        return UsageWindow(
            kind: .primary,
            usedPercent: usedPercent,
            resetAt: resetAt,
            limitWindowSeconds: limitWindowSeconds,
            usedCount: usedCount,
            limitCount: limitCount
        )
    }

    /// Computes the billing window duration in seconds.
    /// Uses the first day of the current month as window start, with resetAt as window end.
    private func computeLimitWindowSeconds(resetAt: Date?) -> TimeInterval {
        guard let resetAt = resetAt else {
            return UsageLimitDuration.thirtyDays
        }
        let cal = Self.billingCalendar
        // Assume billing period starts on the 1st of the previous or current month
        let resetComponents = cal.dateComponents([.year, .month], from: resetAt)
        guard let resetMonth = resetComponents.month,
              let resetYear = resetComponents.year else {
            return UsageLimitDuration.thirtyDays
        }
        // Window start is the 1st of the month before resetDate's month
        var startComponents = DateComponents()
        if resetMonth == 1 {
            startComponents.year = resetYear - 1
            startComponents.month = 12
        } else {
            startComponents.year = resetYear
            startComponents.month = resetMonth - 1
        }
        startComponents.day = 1
        guard let windowStart = cal.date(from: startComponents) else {
            return UsageLimitDuration.thirtyDays
        }
        let duration = resetAt.timeIntervalSince(windowStart)
        return duration > 0 ? duration : UsageLimitDuration.thirtyDays
    }
}

// MARK: - Error Types

/// Errors that can occur when fetching Copilot usage data
enum CopilotUsageFetcherError: LocalizedError {
    case pageNotReady
    case scriptFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .pageNotReady:
            return "error.loginNotLoaded".localized()
        case .scriptFailed(let message):
            return "error.fetchFailed".localized(message)
        case .invalidResponse:
            return "error.parseFailed".localized()
        }
    }
}

// MARK: - Copilot Usage Fetcher

/// Fetches usage data from GitHub Copilot by executing JavaScript in WebView.
/// Authenticates via GitHub session cookies to access entitlement API.
final class CopilotUsageFetcher {
    private let scriptRunner: WebViewScriptRunner

    init(scriptRunner: WebViewScriptRunner = WebViewScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    /// Fetches current usage snapshot by executing JavaScript in the WebView
    @MainActor
    func fetchUsageSnapshot(using webView: WKWebView) async throws -> UsageSnapshot {
        do {
            let response = try await scriptRunner.decodeJSONScript(
                CopilotUsageResponse.self,
                script: Self.usageScript,
                webView: webView
            )
            return try response.toSnapshot(fetchedAt: Date())
        } catch let error as WebViewScriptRunnerError {
            throw mapScriptError(error)
        } catch is CopilotUsageResponseError {
            throw CopilotUsageFetcherError.invalidResponse
        }
    }

    /// Checks if user is logged in by verifying the GitHub session cookie
    @MainActor
    func hasValidSession(using webView: WKWebView) async -> Bool {
        await hasValidSessionCookie(using: webView)
    }

    private func hasValidSessionCookie(using webView: WKWebView) async -> Bool {
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
        return await withCheckedContinuation { continuation in
            cookieStore.getAllCookies { cookies in
                let now = Date()
                // Look for GitHub's logged_in cookie on github.com domain.
                let isValid = cookies.contains { cookie in
                    guard cookie.name == "logged_in" else { return false }
                    guard CookieDomainMatcher.matches(
                        cookie.domain,
                        expectedDomain: "github.com"
                    ) else { return false }
                    guard cookie.value == "yes" else { return false }
                    if let expiresDate = cookie.expiresDate {
                        return expiresDate > now
                    }
                    return true
                }
                continuation.resume(returning: isValid)
            }
        }
    }

    private func mapScriptError(_ error: WebViewScriptRunnerError) -> CopilotUsageFetcherError {
        switch error {
        case .invalidResponse:
            return .invalidResponse
        case .scriptFailed(let message):
            return .scriptFailed(message)
        }
    }

    // MARK: - JavaScript Scripts

    /// Script to fetch usage data from GitHub Copilot entitlement API.
    /// Uses session cookies for authentication (credentials: "include").
    private static let usageScript = """
    return (async () => {
      try {
        const response = await fetch("https://github.com/github-copilot/chat/entitlement", {
          method: "GET",
          credentials: "include",
          headers: {
            "Accept": "application/json"
          }
        });
        if (!response.ok) {
          throw new Error("HTTP " + response.status);
        }
        const data = await response.json();
        return JSON.stringify(data);
      } catch (error) {
        const message = error && error.message ? error.message : String(error);
        return JSON.stringify({ "__error": message });
      }
    })();
    """
}
