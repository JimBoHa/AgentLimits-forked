// MARK: - CopilotBillingFetcher.swift
// Fetches billing usage data from GitHub's usage_table API via WebView.
// Aggregates daily costs and premium request counts into TokenUsageSnapshot.

import Foundation
import WebKit

// MARK: - API Response Models

/// Response structure from GitHub billing usage_table API
struct CopilotBillingResponse: Decodable {
    let usage: [CopilotBillingEntry]
}

/// Single billing entry from usage_table API
struct CopilotBillingEntry: Decodable {
    let grossAmount: Double
    let quantity: Double
    let usageAt: String
    let sku: String
}

// MARK: - Error Types

/// Errors that can occur when fetching Copilot billing data
enum CopilotBillingFetcherError: LocalizedError {
    case scriptFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .scriptFailed(let message):
            return "error.fetchFailed".localized(message)
        case .invalidResponse:
            return "error.parseFailed".localized()
        }
    }
}

// MARK: - Copilot Billing Fetcher

/// Fetches billing usage data from GitHub's usage_table API via WebView JavaScript.
/// Uses the same WebView session as CopilotUsageFetcher.
final class CopilotBillingFetcher {
    private let scriptRunner: WebViewScriptRunner

    init(scriptRunner: WebViewScriptRunner = WebViewScriptRunner()) {
        self.scriptRunner = scriptRunner
    }

    /// Fetches and aggregates billing data into a TokenUsageSnapshot.
    @MainActor
    func fetchBillingSnapshot(using webView: WKWebView) async throws -> TokenUsageSnapshot {
        let response: CopilotBillingResponse
        do {
            response = try await scriptRunner.decodeJSONScript(
                CopilotBillingResponse.self,
                script: Self.billingScript,
                webView: webView
            )
        } catch let error as WebViewScriptRunnerError {
            throw mapScriptError(error)
        }
        return buildSnapshot(from: response)
    }

    // MARK: - Snapshot Building

    /// Aggregates billing entries into today/thisWeek/thisMonth periods and daily entries.
    func buildSnapshot(
        from response: CopilotBillingResponse,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> TokenUsageSnapshot {
        let localCalendar = Self.localGregorianCalendar(matching: calendar)
        let endOfCurrentMoment = now
        let startOfToday = localCalendar.startOfDay(for: now)
        let startOfWeek = SundayWeekStartResolver.resolve(
            for: now,
            calendar: localCalendar
        )
        let localMonthComponents = localCalendar.dateComponents([.year, .month], from: now)
        let startOfLocalMonth = localCalendar.date(from: localMonthComponents) ?? startOfToday
        let startOfBillingMonth = Self.startOfUTCBillingMonth(for: now)

        // Invalid and future timestamps must not contribute to any current period.
        let premiumEntries = response.usage.compactMap { entry -> DatedBillingEntry? in
            guard entry.sku == "copilot_premium_request",
                  let date = Self.parseUsageDate(entry.usageAt),
                  date <= endOfCurrentMoment else {
                return nil
            }
            return DatedBillingEntry(entry: entry, date: date)
        }

        let billingMonthEntries = premiumEntries.filter { $0.date >= startOfBillingMonth }
        let localMonthEntries = premiumEntries.filter { $0.date >= startOfLocalMonth }

        // Calculate today's usage
        let todayPeriod = aggregatePeriod(
            for: premiumEntries.filter { $0.date >= startOfToday }
        )

        // Calculate this week's usage (Sunday start)
        let thisWeekPeriod = aggregatePeriod(
            for: premiumEntries.filter { $0.date >= startOfWeek }
        )

        // GitHub's premium-request billing month resets at 00:00 UTC.
        let thisMonthPeriod = aggregatePeriod(for: billingMonthEntries)

        // Build current-month daily entries for the heatmap.
        let dailyUsage = buildDailyUsage(
            from: localMonthEntries,
            calendar: localCalendar
        )

        return TokenUsageSnapshot(
            provider: .copilot,
            fetchedAt: now,
            today: todayPeriod,
            thisWeek: thisWeekPeriod,
            thisMonth: thisMonthPeriod,
            dailyUsage: dailyUsage
        )
    }

    private struct DatedBillingEntry {
        let entry: CopilotBillingEntry
        let date: Date
    }

    /// Aggregates cost and quantity for a set of entries.
    private func aggregatePeriod(for entries: [DatedBillingEntry]) -> TokenUsagePeriod {
        let totalCost = entries.reduce(0.0) { $0 + $1.entry.grossAmount }
        let totalRequests = entries.reduce(0.0) { $0 + $1.entry.quantity }
        return TokenUsagePeriod(costUSD: totalCost, totalTokens: Int(totalRequests))
    }

    /// Builds sorted daily usage entries from grouped data for heatmap.
    private func buildDailyUsage(
        from entries: [DatedBillingEntry],
        calendar: Calendar
    ) -> [DailyUsageEntry] {
        let groupedByDate = Dictionary(grouping: entries) {
            Self.localDateKey(for: $0.date, calendar: calendar)
        }
        return groupedByDate.map { dateKey, datedEntries in
            let totalRequests = datedEntries.reduce(0.0) { $0 + $1.entry.quantity }
            return DailyUsageEntry(date: dateKey, totalTokens: Int(totalRequests))
        }
        .sorted { $0.date < $1.date }
    }

    // MARK: - Error Mapping

    private func mapScriptError(_ error: WebViewScriptRunnerError) -> CopilotBillingFetcherError {
        switch error {
        case .invalidResponse:
            return .invalidResponse
        case .scriptFailed(let message):
            return .scriptFailed(message)
        }
    }

    // MARK: - Date Formatters

    private static func parseUsageDate(_ value: String) -> Date? {
        guard hasStrictRFC3339Shape(value),
              hasValidGregorianDatePrefix(value) else {
            return nil
        }
        return try? Date(value, strategy: .iso8601)
    }

    /// `Date.ISO8601FormatStyle` accepts normalized times and trailing bytes.
    /// Enforce the complete GitHub timestamp grammar before parsing.
    private static func hasStrictRFC3339Shape(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count >= 20,
              bytes[4] == 45,
              bytes[7] == 45,
              bytes[10] == 84,
              bytes[13] == 58,
              bytes[16] == 58,
              let hour = twoDigitValue(bytes, at: 11),
              let minute = twoDigitValue(bytes, at: 14),
              let second = twoDigitValue(bytes, at: 17),
              hour <= 23,
              minute <= 59,
              second <= 59 else {
            return false
        }

        var timeZoneIndex = 19
        if bytes[timeZoneIndex] == 46 {
            timeZoneIndex += 1
            let fractionStart = timeZoneIndex
            while timeZoneIndex < bytes.count,
                  isASCIIDigit(bytes[timeZoneIndex]) {
                timeZoneIndex += 1
            }
            guard timeZoneIndex > fractionStart,
                  timeZoneIndex < bytes.count else {
                return false
            }
        }

        if bytes[timeZoneIndex] == 90 {
            return timeZoneIndex + 1 == bytes.count
        }

        guard bytes[timeZoneIndex] == 43 || bytes[timeZoneIndex] == 45,
              timeZoneIndex + 6 == bytes.count,
              bytes[timeZoneIndex + 3] == 58,
              let offsetHour = twoDigitValue(bytes, at: timeZoneIndex + 1),
              let offsetMinute = twoDigitValue(bytes, at: timeZoneIndex + 4) else {
            return false
        }
        return offsetHour <= 23 && offsetMinute <= 59
    }

    private static func twoDigitValue(_ bytes: [UInt8], at index: Int) -> Int? {
        guard index + 1 < bytes.count,
              isASCIIDigit(bytes[index]),
              isASCIIDigit(bytes[index + 1]) else {
            return nil
        }
        return Int(bytes[index] - 48) * 10 + Int(bytes[index + 1] - 48)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        byte >= 48 && byte <= 57
    }

    /// Foundation's ISO parser normalizes dates such as February 30 to March 2.
    /// Validate the calendar components first so malformed API rows stay excluded.
    private static func hasValidGregorianDatePrefix(_ value: String) -> Bool {
        let prefix = value.prefix(10)
        guard prefix.count == 10 else { return false }
        let components = prefix.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              components[0].count == 4,
              components[1].count == 2,
              components[2].count == 2,
              components.allSatisfy({ part in
                  part.utf8.allSatisfy(isASCIIDigit)
              }),
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]) else {
            return false
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day)
        ) else {
            return false
        }
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        return resolved.year == year && resolved.month == month && resolved.day == day
    }

    private static func localDateKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    private static func startOfUTCBillingMonth(for date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(
            from: calendar.dateComponents([.year, .month], from: date)
        ) ?? date
    }

    private static func localGregorianCalendar(matching source: Calendar) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = source.timeZone
        return calendar
    }

    // MARK: - JavaScript Scripts

    /// Script to fetch billing data from GitHub usage_table API.
    /// Uses session cookies for authentication (credentials: "include").
    private static let billingScript = """
    return (async () => {
      try {
        const response = await fetch(
          "https://github.com/settings/billing/usage_table?group=0&period=3&product=&query=",
          {
            method: "GET",
            credentials: "include",
            headers: {
              "Accept": "application/json"
            }
          }
        );
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
