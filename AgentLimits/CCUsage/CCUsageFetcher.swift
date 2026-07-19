// MARK: - CCUsageFetcher.swift
// Executes ccusage CLI commands and parses JSON output to fetch token usage data.
// Uses ShellExecutor for command execution.

import Foundation

// MARK: - Calendar Boundaries

enum SundayWeekStartResolver {
    static func resolve(
        for date: Date,
        calendar: Calendar = .current
    ) -> Date {
        let startOfDay = calendar.startOfDay(for: date)
        let daysSinceSunday = calendar.component(.weekday, from: startOfDay) - 1
        return calendar.date(
            byAdding: .day,
            value: -daysSinceSunday,
            to: startOfDay
        ) ?? startOfDay
    }
}

// MARK: - CLI Response Models

/// ccusage daily -j output format (Claude)
struct CCUsageClaudeResponse: Codable {
    struct DayEntry: Codable {
        let date: String           // "YYYY-MM-DD"
        let totalTokens: Int
        let totalCost: Double
    }
    struct Totals: Codable {
        let totalTokens: Int
        let totalCost: Double
    }
    let daily: [DayEntry]
    let totals: Totals
}

/// ccusage codex daily -j output format (Codex)
struct CCUsageCodexResponse: Codable {
    struct DayEntry: Codable {
        let date: String           // "YYYY-MM-DD"
        let totalTokens: Int
        let costUSD: Double
    }
    struct Totals: Codable {
        let totalTokens: Int
        let costUSD: Double
    }
    let daily: [DayEntry]
    let totals: Totals
}

// MARK: - Errors

/// Errors that can occur during ccusage CLI execution
enum CCUsageFetcherError: Error, LocalizedError {
    case cliNotFound(command: String)
    case executionFailed(exitCode: Int32, stderr: String)
    case timeout
    case outputLimitExceeded(maximumBytes: Int)
    case invalidExecutable(String)
    case invalidArguments(String)
    case parseError(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let command):
            return "CLI not found: \(command). Please install: npm install -g ccusage"
        case .executionFailed(let code, let stderr):
            return "CLI failed (\(code)): \(stderr)"
        case .timeout:
            return "CLI execution timed out"
        case .outputLimitExceeded(let maximumBytes):
            return "CLI output exceeded the \(maximumBytes)-byte limit"
        case .invalidExecutable(let message):
            return message
        case .invalidArguments(let message):
            return "Invalid additional arguments: \(message)"
        case .parseError(let message):
            return "Failed to parse JSON: \(message)"
        }
    }
}

// MARK: - CCUsage Fetcher

/// Executes ccusage CLI commands and parses the JSON output.
/// Uses ShellExecutor for command execution with timeout support.
final class CCUsageFetcher {
    private let shellExecutor: ShellExecutor
    private let settingsStore: CCUsageSettingsStore

    /// Creates a new fetcher with the specified configuration.
    /// - Parameters:
    ///   - timeout: Maximum time to wait for CLI completion (default: 60 seconds)
    ///   - settingsStore: Store for ccusage settings (default: shared instance)
    init(timeout: TimeInterval = 60, settingsStore: CCUsageSettingsStore = .shared) {
        self.shellExecutor = ShellExecutor(timeout: timeout)
        self.settingsStore = settingsStore
    }

    /// Fetches a token usage snapshot for the specified provider.
    /// - Parameter provider: The provider to fetch data for (Claude or Codex)
    /// - Returns: A snapshot containing today/week/month usage data
    /// - Throws: `CCUsageFetcherError` if CLI execution or parsing fails
    func fetchSnapshot(for provider: TokenUsageProvider) async throws -> TokenUsageSnapshot {
        // Load per-provider settings and build CLI command for this month.
        let settings = settingsStore.loadSettings()[provider] ?? .defaultSettings(for: provider)
        let startOfMonth = calculateStartOfMonth()
        let invocation: CLICommandInvocation
        do {
            invocation = try settings.makeCLIInvocation(startDate: startOfMonth)
        } catch let error as CLICommandPathResolverError {
            throw CCUsageFetcherError.invalidExecutable(error.localizedDescription)
        } catch {
            throw CCUsageFetcherError.invalidArguments(error.localizedDescription)
        }
        // Execute CLI and parse JSON response into snapshot.
        let jsonData = try await executeCLI(invocation: invocation)
        return try parseResponse(jsonData: jsonData, provider: provider)
    }

    // MARK: - Private Methods

    /// Calculates the first day of the current month in YYYYMMDD format.
    /// Used as the start date parameter for CLI commands to fetch monthly usage.
    /// - Returns: Date string in compact format (e.g., "20251201" for December 1, 2025)
    private func calculateStartOfMonth() -> String {
        // Delegate to shared month-start resolver for consistency.
        MonthStartDateResolver.calculateStartOfMonthString()
    }

    /// Executes the CLI command and returns the JSON output.
    /// Uses ShellExecutor for command execution and maps errors to CCUsageFetcherError.
    /// - Parameter invocation: The executable and literal arguments to execute
    /// - Returns: The stdout data (JSON)
    /// - Throws: `CCUsageFetcherError` mapped from `ShellExecutorError`
    private func executeCLI(invocation: CLICommandInvocation) async throws -> Data {
        do {
            // Run only the shell-quoted rendering of structured argv.
            return try await shellExecutor.execute(command: invocation.shellCommand)
        } catch let error as ShellExecutorError {
            // Map shell execution errors into domain errors.
            throw mapShellError(error, command: invocation.executable)
        }
    }

    /// Maps ShellExecutorError to CCUsageFetcherError for domain-specific error messages.
    /// - Parameters:
    ///   - error: The shell execution error
    ///   - command: The command that was executed (for error context)
    /// - Returns: A CCUsageFetcherError with appropriate message
    private func mapShellError(_ error: ShellExecutorError, command: String) -> CCUsageFetcherError {
        // Translate shell execution errors into ccusage-specific errors.
        switch error {
        case .launchFailed:
            return .cliNotFound(command: command)
        case .timeout:
            return .timeout
        case .outputLimitExceeded(let maximumBytes):
            return .outputLimitExceeded(maximumBytes: maximumBytes)
        case .executionFailed(let exitCode, let stderr):
            return .executionFailed(exitCode: exitCode, stderr: stderr)
        }
    }

    /// Parses the JSON response and builds a snapshot
    func parseResponse(
        jsonData: Data,
        provider: TokenUsageProvider,
        now: Date = Date(),
        calendar sourceCalendar: Calendar = .current
    ) throws -> TokenUsageSnapshot {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sourceCalendar.timeZone
        let isoFormatter = Self.makeISODateFormatter(calendar: calendar)
        let todayString = isoFormatter.string(from: now)

        // Calculate a Sunday boundary without locale-dependent week numbering.
        let startOfWeek = SundayWeekStartResolver.resolve(for: now, calendar: calendar)

        // Route to provider-specific parsing while sharing summary logic.
        switch provider {
        case .claude:
            return try parseClaudeResponse(
                jsonData: jsonData,
                provider: provider,
                todayString: todayString,
                startOfWeek: startOfWeek,
                now: now,
                calendar: calendar,
                isoFormatter: isoFormatter
            )
        case .codex:
            return try parseCodexResponse(
                jsonData: jsonData,
                provider: provider,
                todayString: todayString,
                startOfWeek: startOfWeek,
                now: now,
                calendar: calendar,
                isoFormatter: isoFormatter
            )
        case .copilot:
            // Copilot billing is fetched via WebView, not CLI.
            throw CCUsageFetcherError.parseError("Copilot billing does not use CLI fetching")
        }
    }

    private static func makeISODateFormatter(calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }

    /// Internal daily entry for parsing and aggregation.
    /// Distinct from shared `DailyUsageEntry` which uses ISO8601 dates only.
    private struct InternalDailyEntry {
        let date: String
        let totalTokens: Int
        let costUSD: Double
    }

    private func decodeResponse<T: Decodable>(_ type: T.Type, jsonData: Data) throws -> T {
        let decoder = JSONDecoder()
        do {
            // Decode JSON into the expected response model.
            return try decoder.decode(T.self, from: jsonData)
        } catch {
            throw CCUsageFetcherError.parseError(error.localizedDescription)
        }
    }

    private func buildSnapshot(
        provider: TokenUsageProvider,
        dailyEntries: [InternalDailyEntry],
        startOfWeek: Date,
        now: Date,
        calendar: Calendar,
        isTodayEntry: (InternalDailyEntry) -> Bool,
        parseDate: (InternalDailyEntry) -> Date?,
        normalizeToISO: (InternalDailyEntry) -> String
    ) -> TokenUsageSnapshot {
        let endOfToday = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: now)
        ) ?? now
        let datedEntries = dailyEntries.compactMap { entry -> (InternalDailyEntry, Date)? in
            guard let date = parseDate(entry), date < endOfToday else { return nil }
            return (entry, date)
        }

        // Build "today" usage from valid, non-future daily entries.
        let todayEntry = datedEntries
            .map(\.0)
            .first(where: isTodayEntry)
        let today = TokenUsagePeriod(
            costUSD: todayEntry?.costUSD ?? 0,
            totalTokens: todayEntry?.totalTokens ?? 0
        )

        // Aggregate week totals from the start-of-week date.
        let weekEntries = datedEntries.filter { $0.1 >= startOfWeek }.map(\.0)
        let thisWeek = TokenUsagePeriod(
            costUSD: weekEntries.reduce(0) { $0 + $1.costUSD },
            totalTokens: weekEntries.reduce(0) { $0 + $1.totalTokens }
        )

        let monthComponents = calendar.dateComponents([.year, .month], from: now)
        let startOfMonth = calendar.date(from: monthComponents) ?? startOfWeek
        let monthEntries = datedEntries.filter { $0.1 >= startOfMonth }.map(\.0)
        let thisMonth = TokenUsagePeriod(
            costUSD: monthEntries.reduce(0) { $0 + $1.costUSD },
            totalTokens: monthEntries.reduce(0) { $0 + $1.totalTokens }
        )

        // Build daily usage entries with normalized ISO8601 dates for heatmap.
        let dailyUsage = datedEntries.map { entry, _ in
            DailyUsageEntry(
                date: normalizeToISO(entry),
                totalTokens: entry.totalTokens
            )
        }

        return TokenUsageSnapshot(
            provider: provider,
            fetchedAt: now,
            today: today,
            thisWeek: thisWeek,
            thisMonth: thisMonth,
            dailyUsage: dailyUsage
        )
    }

    /// Parses Claude (ccusage) response
    private func parseClaudeResponse(
        jsonData: Data,
        provider: TokenUsageProvider,
        todayString: String,
        startOfWeek: Date,
        now: Date,
        calendar: Calendar,
        isoFormatter: DateFormatter
    ) throws -> TokenUsageSnapshot {
        // Decode ccusage response and normalize fields.
        let response = try decodeResponse(CCUsageClaudeResponse.self, jsonData: jsonData)
        let dailyEntries = response.daily.map { entry in
            InternalDailyEntry(
                date: entry.date,
                totalTokens: entry.totalTokens,
                costUSD: entry.totalCost
            )
        }
        // Build standardized snapshot from normalized entries.
        // Claude dates are already in ISO8601 format, so return as-is.
        return buildSnapshot(
            provider: provider,
            dailyEntries: dailyEntries,
            startOfWeek: startOfWeek,
            now: now,
            calendar: calendar,
            isTodayEntry: { $0.date == todayString },
            parseDate: { isoFormatter.date(from: $0.date) },
            normalizeToISO: { $0.date }
        )
    }

    /// Parses Codex (ccusage codex) response
    private func parseCodexResponse(
        jsonData: Data,
        provider: TokenUsageProvider,
        todayString: String,
        startOfWeek: Date,
        now: Date,
        calendar: Calendar,
        isoFormatter: DateFormatter
    ) throws -> TokenUsageSnapshot {
        let response = try decodeResponse(CCUsageCodexResponse.self, jsonData: jsonData)
        let dailyEntries = response.daily.map { entry in
            InternalDailyEntry(
                date: entry.date,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD
            )
        }
        return buildSnapshot(
            provider: provider,
            dailyEntries: dailyEntries,
            startOfWeek: startOfWeek,
            now: now,
            calendar: calendar,
            isTodayEntry: { $0.date == todayString },
            parseDate: { isoFormatter.date(from: $0.date) },
            normalizeToISO: { $0.date }
        )
    }
}
