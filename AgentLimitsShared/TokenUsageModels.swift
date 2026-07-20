// MARK: - TokenUsageModels.swift
// Shared data models for ccusage token usage tracking.
// Used by both App and Widget targets for displaying token costs.

import Foundation

// MARK: - Token Usage Provider

/// Provider identifier for token usage tracking.
/// Uses `codex`, `claude`, and `copilot` as rawValue for JSON compatibility.
enum TokenUsageProvider: String, Codable, CaseIterable, Identifiable, SnapshotFileNaming, AIProviderProtocol {
    case codex       // ccusage codex (Codex)
    case claude      // ccusage claude (Claude Code)
    case copilot     // GitHub Copilot billing (WebView-based)

    var id: String { rawValue }

    /// Whether this provider uses CLI-based fetching.
    /// Copilot uses WebView-based fetch instead.
    var isCLIBased: Bool {
        switch self {
        case .codex, .claude:
            return true
        case .copilot:
            return false
        }
    }

    /// Display name for UI (implements AIProviderProtocol)
    var displayName: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude Code"
        case .copilot:
            return "Copilot"
        }
    }

    /// Display name for widget title
    var widgetDisplayName: String {
        switch self {
        case .codex:
            return "Codex usage"
        case .claude:
            return "Claude Code usage"
        case .copilot:
            return "Copilot usage"
        }
    }

    /// Base CLI invocation before user-supplied and date-range arguments.
    func makeCLIInvocationBase() throws -> CLICommandInvocation {
        switch self {
        case .codex:
            let ccusageExecutable = try CLICommandPathResolver.resolveExecutable(
                for: .ccusage,
                defaultName: "ccusage"
            )
            return CLICommandInvocation(
                executable: ccusageExecutable,
                arguments: ["codex", "daily"]
            )
        case .claude:
            let ccusageExecutable = try CLICommandPathResolver.resolveExecutable(
                for: .ccusage,
                defaultName: "ccusage"
            )
            return CLICommandInvocation(
                executable: ccusageExecutable,
                arguments: ["claude", "daily"]
            )
        case .copilot:
            return CLICommandInvocation(executable: "", arguments: [])
        }
    }

    /// Base command rendered safely for display or shell wrapping.
    var cliCommandBase: String {
        do {
            return try makeCLIInvocationBase().shellCommand
        } catch {
            return "[\(error.localizedDescription)]"
        }
    }

    /// Widget kind identifier for WidgetKit
    var widgetKind: String {
        switch self {
        case .codex:
            return "TokenUsageWidgetCodex"
        case .claude:
            return "TokenUsageWidgetClaude"
        case .copilot:
            return "TokenUsageWidgetCopilot"
        }
    }

    /// Snapshot filename for App Group storage
    var snapshotFileName: String {
        switch self {
        case .codex:
            return "token_usage_codex.json"
        case .claude:
            return "token_usage_claude.json"
        case .copilot:
            return "token_usage_copilot.json"
        }
    }

    /// Deep link URL for widget tap action.
    /// Constructs a URL with the provider's rawValue as a query parameter.
    var widgetDeepLinkURL: URL {
        guard let url = URL(
            string: "\(DeepLinkConfig.scheme)://open-token-usage?provider=\(rawValue)"
        ) else {
            preconditionFailure("Invalid deep link URL for token usage provider: \(rawValue)")
        }
        return url
    }

    // MARK: - Provider Conversion

    /// Converts this TokenUsageProvider to its corresponding UsageProvider.
    /// Useful when working with Usage Limits features for the same AI provider.
    var usageProvider: UsageProvider {
        switch self {
        case .codex:
            return .chatgptCodex
        case .claude:
            return .claudeCode
        case .copilot:
            return .githubCopilot
        }
    }

    /// Provider-specific profile root consumed by ccusage's child process.
    var cliDataRootEnvironmentVariable: String? {
        switch self {
        case .codex:
            return "CODEX_HOME"
        case .claude:
            return "CLAUDE_CONFIG_DIR"
        case .copilot:
            return nil
        }
    }

    /// Resolves one optional account root into a child-only environment edit.
    /// A nil/blank root deliberately unsets the provider variable instead of
    /// inheriting a profile selected in AgentLimits' parent environment.
    func resolveCLIDataRootEnvironment(
        _ rawValue: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> CLIDataRootEnvironment? {
        let trimmed = rawValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let variableName = cliDataRootEnvironmentVariable else {
            guard trimmed?.isEmpty != false else {
                throw CLIDataRootError.unsupportedProvider(self)
            }
            return nil
        }
        guard let trimmed, !trimmed.isEmpty else {
            return CLIDataRootEnvironment(
                variableName: variableName,
                value: nil
            )
        }
        guard !trimmed.contains("\0") else {
            throw CLIDataRootError.nullByte
        }
        guard !trimmed.contains(",") else {
            throw CLIDataRootError.multipleRoots
        }
        guard !trimmed.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw CLIDataRootError.controlCharacter
        }

        let absolutePath: String
        if trimmed == "~" {
            absolutePath = homeDirectory.path
        } else if trimmed.hasPrefix("~/") {
            absolutePath = homeDirectory
                .appendingPathComponent(String(trimmed.dropFirst(2)))
                .path
        } else if trimmed.hasPrefix("~") {
            throw CLIDataRootError.unsupportedTilde
        } else {
            guard trimmed.hasPrefix("/") else {
                throw CLIDataRootError.relativePath
            }
            absolutePath = trimmed
        }

        let standardizedPath = URL(
            fileURLWithPath: absolutePath,
            isDirectory: true
        ).standardizedFileURL.path
        guard standardizedPath.hasPrefix("/") else {
            throw CLIDataRootError.relativePath
        }
        return CLIDataRootEnvironment(
            variableName: variableName,
            value: standardizedPath
        )
    }
}

/// One provider-root edit, kept separate from rendered shell command text.
struct CLIDataRootEnvironment: Equatable, Sendable {
    let variableName: String
    /// Nil means explicitly remove this variable from the child environment.
    let value: String?
}

enum CLIDataRootError: LocalizedError, Equatable {
    case unsupportedProvider(TokenUsageProvider)
    case nullByte
    case controlCharacter
    case relativePath
    case multipleRoots
    case unsupportedTilde

    var errorDescription: String? {
        switch self {
        case .unsupportedProvider(let provider):
            return "\(provider.displayName) does not support a CLI data root."
        case .nullByte:
            return "CLI data root contains an unsupported null byte."
        case .controlCharacter:
            return "CLI data root contains an unsupported control character."
        case .relativePath:
            return "CLI data root must be an absolute path or start with ~/."
        case .multipleRoots:
            return "CLI data root must contain exactly one directory."
        case .unsupportedTilde:
            return "CLI data root supports only ~ or ~/ paths."
        }
    }
}

/// Complete ccusage execution request. Environment never becomes shell text.
struct CCUsageCLIExecution: Equatable {
    let invocation: CLICommandInvocation
    let dataRootEnvironment: CLIDataRootEnvironment?
}

// MARK: - Token Usage Period

/// Usage data for a specific time period (today/this week/this month)
struct TokenUsagePeriod: Codable, Equatable {
    /// Cost in USD
    let costUSD: Double
    /// Total tokens used
    let totalTokens: Int
}

// MARK: - Daily Usage Entry

/// Daily usage data entry for heatmap display
struct DailyUsageEntry: Codable, Equatable {
    /// Date in ISO8601 format (YYYY-MM-DD)
    let date: String
    /// Total tokens used on this day
    let totalTokens: Int
}

// MARK: - Token Usage Snapshot

/// Snapshot of token usage data fetched from ccusage CLI
struct TokenUsageSnapshot: Codable, SnapshotData {
    let provider: TokenUsageProvider
    let fetchedAt: Date
    /// Today's usage
    let today: TokenUsagePeriod
    /// This week's usage (Sunday start)
    let thisWeek: TokenUsagePeriod
    /// This month's usage
    let thisMonth: TokenUsagePeriod
    /// Daily usage entries for the current month (for heatmap)
    let dailyUsage: [DailyUsageEntry]

    // MARK: - Coding Keys

    private enum CodingKeys: String, CodingKey {
        case provider, fetchedAt, today, thisWeek, thisMonth, dailyUsage
    }

    // MARK: - Initializers

    /// Standard initializer with all properties
    init(
        provider: TokenUsageProvider,
        fetchedAt: Date,
        today: TokenUsagePeriod,
        thisWeek: TokenUsagePeriod,
        thisMonth: TokenUsagePeriod,
        dailyUsage: [DailyUsageEntry] = []
    ) {
        self.provider = provider
        self.fetchedAt = fetchedAt
        self.today = today
        self.thisWeek = thisWeek
        self.thisMonth = thisMonth
        self.dailyUsage = dailyUsage
    }

    /// Custom Decodable for backward compatibility with existing snapshots
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(TokenUsageProvider.self, forKey: .provider)
        fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
        today = try container.decode(TokenUsagePeriod.self, forKey: .today)
        thisWeek = try container.decode(TokenUsagePeriod.self, forKey: .thisWeek)
        thisMonth = try container.decode(TokenUsagePeriod.self, forKey: .thisMonth)
        // Optional for backward compatibility with existing snapshots without dailyUsage
        dailyUsage = try container.decodeIfPresent([DailyUsageEntry].self, forKey: .dailyUsage) ?? []
    }
}

// MARK: - Token Usage Snapshot Store

/// Persists and retrieves token usage snapshots via App Group shared container.
/// Used by both the main app (for writing) and widgets (for reading).
typealias TokenUsageSnapshotStore = AppGroupSnapshotStore<TokenUsageProvider, TokenUsageSnapshot>

extension AppGroupSnapshotStore where Provider == TokenUsageProvider, Snapshot == TokenUsageSnapshot {
    /// Shared store instance for app-wide use.
    static let shared = Self()
}

// MARK: - CCUsage Settings

/// Resolves the current month's start date string for ccusage CLI commands.
enum MonthStartDateResolver {
    /// Calculates the first day of the current month in YYYYMMDD format.
    /// - Parameters:
    ///   - now: The date to base the calculation on (default: current date)
    ///   - calendar: The calendar used for component extraction (default: .current)
    /// - Returns: Date string in compact format (e.g., "20251201")
    static func calculateStartOfMonthString(
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        // ccusage date arguments are Gregorian even when the user's preferred
        // calendar is Islamic, Hebrew, or another non-Gregorian calendar.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let components = gregorian.dateComponents([.year, .month], from: now)
        guard let year = components.year, let month = components.month else {
            return ""
        }
        return String(format: "%04d%02d01", year, month)
    }
}

/// Pre-validated ccusage external link URLs.
enum CCUsageLinks {
    /// ccusage website URL
    static let siteURL = URL(string: "https://ccusage.com/")
    /// ccusage GitHub repository URL
    static let repoURL = URL(string: "https://github.com/ryoppippi/ccusage")
}

/// Settings for ccusage CLI execution
struct CCUsageSettings: Codable, Equatable {
    let provider: TokenUsageProvider
    var isEnabled: Bool
    var additionalArgs: String

    /// Full CLI command rendered safely for display.
    var cliCommand: String {
        do {
            let arguments = try CLIArgumentParser.parse(additionalArgs)
            let base = try provider.makeCLIInvocationBase()
            return CLICommandInvocation(
                executable: base.executable,
                arguments: base.arguments + arguments
            ).shellCommand
        } catch {
            return "[\(error.localizedDescription)]"
        }
    }

    /// CLI command for display (includes -s startDate -j)
    var displayCommand: String {
        makeCLICommand(startDate: Self.currentStartOfMonth)
    }

    /// Builds the full CLI command with start date and JSON output flag.
    /// - Parameter startDate: Start date in YYYYMMDD format.
    /// - Returns: CLI command string with date and JSON arguments.
    func makeCLICommand(startDate: String) -> String {
        makeCLICommand(startDate: startDate, cliDataRoot: nil)
    }

    /// Root-aware display helper. Root remains absent from rendered command.
    func makeCLICommand(
        startDate: String,
        cliDataRoot: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        guard let execution = try? makeCLIExecution(
            startDate: startDate,
            cliDataRoot: cliDataRoot,
            homeDirectory: homeDirectory
        ) else {
            return cliCommand
        }
        return execution.invocation.shellCommand
    }

    /// Builds literal argv without evaluating the additional-arguments field.
    func makeCLIInvocation(startDate: String) throws -> CLICommandInvocation {
        try makeCLIExecution(
            startDate: startDate,
            cliDataRoot: nil
        ).invocation
    }

    /// Builds argv plus an isolated provider-root environment edit.
    func makeCLIExecution(
        startDate: String,
        cliDataRoot: String?,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> CCUsageCLIExecution {
        let additionalArguments = try CLIArgumentParser.parse(additionalArgs)
        let base = try provider.makeCLIInvocationBase()
        return CCUsageCLIExecution(
            invocation: CLICommandInvocation(
                executable: base.executable,
                arguments: base.arguments + additionalArguments + ["--since", startDate, "-j"]
            ),
            dataRootEnvironment: try provider.resolveCLIDataRootEnvironment(
                cliDataRoot,
                homeDirectory: homeDirectory
            )
        )
    }

    /// Current month's start date in YYYYMMDD format
    private static var currentStartOfMonth: String {
        MonthStartDateResolver.calculateStartOfMonthString()
    }

    /// Default settings for a provider
    static func defaultSettings(for provider: TokenUsageProvider) -> CCUsageSettings {
        CCUsageSettings(provider: provider, isEnabled: false, additionalArgs: "")
    }
}

// MARK: - CCUsage Settings Store

/// Persists ccusage settings to UserDefaults
final class CCUsageSettingsStore {
    static let shared = CCUsageSettingsStore()

    private let userDefaults: UserDefaults
    private let key = "ccusage_settings"
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(userDefaults: UserDefaults = AppDefaults.shared) {
        self.userDefaults = userDefaults
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
    }

    /// Loads settings for all providers
    func loadSettings() -> [TokenUsageProvider: CCUsageSettings] {
        guard let data = userDefaults.data(forKey: key),
              let settingsArray = try? decoder.decode([CCUsageSettings].self, from: data) else {
            return defaultSettings()
        }
        var result: [TokenUsageProvider: CCUsageSettings] = [:]
        for settings in settingsArray {
            result[settings.provider] = settings
        }
        // Ensure all providers have settings
        for provider in TokenUsageProvider.allCases where result[provider] == nil {
            result[provider] = .defaultSettings(for: provider)
        }
        return result
    }

    /// Saves settings for all providers
    func saveSettings(_ settings: [TokenUsageProvider: CCUsageSettings]) {
        let settingsArray = Array(settings.values)
        if let data = try? encoder.encode(settingsArray) {
            userDefaults.set(data, forKey: key)
        }
    }

    /// Updates settings for a single provider
    func updateSettings(_ settings: CCUsageSettings) {
        var allSettings = loadSettings()
        allSettings[settings.provider] = settings
        saveSettings(allSettings)
    }

    private func defaultSettings() -> [TokenUsageProvider: CCUsageSettings] {
        var result: [TokenUsageProvider: CCUsageSettings] = [:]
        for provider in TokenUsageProvider.allCases {
            result[provider] = .defaultSettings(for: provider)
        }
        return result
    }
}
