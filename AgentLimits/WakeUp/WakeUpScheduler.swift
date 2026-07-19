// MARK: - WakeUpScheduler.swift
// Manages scheduled CLI invocations via LaunchAgent to wake up Claude Code and Codex sessions.
// Creates plist files in ~/Library/LaunchAgents/ for launchd to execute CLI commands.

import Combine
@preconcurrency import Foundation
import OSLog

// MARK: - Configuration

/// LaunchAgent configuration constants
enum LaunchAgentConfig {
    static let labelPrefix = "com.dmng.agentlimit.wakeup"
    static let launchAgentsPath = "Library/LaunchAgents"
    static let logDirectory = "/tmp"
    static let cliTimeoutSeconds: Int = 30
}

// MARK: - Wake Up Schedule

/// Configuration for wake-up schedule per provider
struct WakeUpSchedule: Codable, Equatable {
    let provider: UsageProvider
    /// Enabled hours (0-23) for wake-up calls
    var enabledHours: Set<Int>
    /// Whether the schedule is active
    var isEnabled: Bool
    /// Additional CLI arguments (e.g., --model="haiku")
    var additionalArgs: String = ""

    /// Creates a default disabled schedule for a provider
    static func defaultSchedule(for provider: UsageProvider) -> WakeUpSchedule {
        WakeUpSchedule(
            provider: provider,
            enabledHours: [],
            isEnabled: false,
            additionalArgs: ""
        )
    }

    /// Returns the LaunchAgent label for this schedule
    var launchAgentLabel: String {
        "\(LaunchAgentConfig.labelPrefix)-\(provider.rawValue)"
    }

    /// Returns the plist filename for this schedule
    var plistFileName: String {
        "\(launchAgentLabel).plist"
    }

    /// Returns the base CLI command (without logging prefix)
    var cliCommand: String {
        let args = additionalArgs.trimmingCharacters(in: .whitespaces)
        let suffix = args.isEmpty ? "" : " \(args)"

        switch provider {
        case .chatgptCodex:
            let codexExecutable = CLICommandPathResolver.resolveExecutable(for: .codex, defaultName: "codex")
            return "\(codexExecutable) exec --skip-git-repo-check \"hello\"\(suffix)"
        case .claudeCode:
            let claudeExecutable = CLICommandPathResolver.resolveExecutable(for: .claude, defaultName: "claude")
            return "\(claudeExecutable) -p \"hello\"\(suffix)"
        case .githubCopilot:
            return ""
        }
    }

    /// Returns the log file path for this schedule
    var logPath: String {
        "\(LaunchAgentConfig.logDirectory)/agentlimit-wakeup-\(provider.rawValue).log"
    }
}

// MARK: - Wake Up Result

/// Result of a CLI wake-up invocation
enum WakeUpResult {
    case success(output: String)
    case failure(error: WakeUpError)
}

/// Errors that can occur during wake-up operations
enum WakeUpError: Error, LocalizedError {
    case cliNotFound(command: String)
    case executionFailed(exitCode: Int32, stderr: String)
    case timeout
    case launchAgentWriteFailed(Error)
    case launchAgentLoadFailed(Error)
    case homeDirectoryNotFound

    var errorDescription: String? {
        switch self {
        case .cliNotFound(let command):
            return "CLI not found: \(command)"
        case .executionFailed(let code, let stderr):
            return "CLI failed (\(code)): \(stderr)"
        case .timeout:
            return "CLI execution timed out"
        case .launchAgentWriteFailed(let error):
            return "Failed to write LaunchAgent: \(error.localizedDescription)"
        case .launchAgentLoadFailed(let error):
            return "Failed to load LaunchAgent: \(error.localizedDescription)"
        case .homeDirectoryNotFound:
            return "Home directory not found"
        }
    }
}

struct LaunchCtlResult {
    let terminationStatus: Int32
    let standardError: String
}

struct LaunchCtlCommandFailure: LocalizedError {
    let operation: String
    let terminationStatus: Int32
    let standardError: String

    var errorDescription: String? {
        let detail = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        if detail.isEmpty {
            return "launchctl \(operation) failed with exit code \(terminationStatus)"
        }
        return "launchctl \(operation) failed with exit code \(terminationStatus): \(detail)"
    }
}

struct LaunchAgentRollbackFailure: LocalizedError {
    let originalError: Error
    let rollbackError: Error

    var errorDescription: String? {
        "\(originalError.localizedDescription); rollback also failed: \(rollbackError.localizedDescription)"
    }
}

private enum LaunchCtlProcessRunner {
    nonisolated static func run(arguments: [String]) throws -> LaunchCtlResult {
        let process = Process()
        let standardError = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        // Drain while launchctl runs so its stderr pipe cannot block completion.
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return LaunchCtlResult(
            terminationStatus: process.terminationStatus,
            standardError: String(decoding: errorData, as: UTF8.self)
        )
    }
}

// MARK: - LaunchAgent Manager

/// Manages LaunchAgent plist files for scheduled CLI execution
final class LaunchAgentManager {
    private let fileManager: FileManager
    private let homeDirectoryOverride: URL?
    private let launchCtlRunner: ([String]) throws -> LaunchCtlResult
    private let removeItem: (URL) throws -> Void
    private var loadedLabels: Set<String> = []

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        launchCtlRunner: @escaping ([String]) throws -> LaunchCtlResult = LaunchCtlProcessRunner.run,
        removeItem: ((URL) throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectoryOverride = homeDirectory
        self.launchCtlRunner = launchCtlRunner
        self.removeItem = removeItem ?? { try fileManager.removeItem(at: $0) }
    }

    /// Returns the real user home directory (not sandboxed container)
    private var realHomeDirectory: URL {
        if let homeDirectoryOverride {
            return homeDirectoryOverride
        }
        // Use POSIX API to get real home directory, bypassing sandbox
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        // Fallback to environment variable
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        // Last resort (may be sandboxed)
        return fileManager.homeDirectoryForCurrentUser
    }

    /// Returns the LaunchAgents directory URL
    private var launchAgentsURL: URL? {
        realHomeDirectory
            .appendingPathComponent(LaunchAgentConfig.launchAgentsPath, isDirectory: true)
    }

    /// Returns the plist file URL for a schedule
    func plistURL(for schedule: WakeUpSchedule) -> URL? {
        launchAgentsURL?.appendingPathComponent(schedule.plistFileName)
    }

    /// Checks if a LaunchAgent is installed for the given schedule
    func isInstalled(for schedule: WakeUpSchedule) -> Bool {
        guard let url = plistURL(for: schedule) else { return false }
        return fileManager.fileExists(atPath: url.path)
            && loadedLabels.contains(schedule.launchAgentLabel)
    }

    /// Installs or updates a LaunchAgent for the given schedule
    func install(schedule: WakeUpSchedule) throws {
        guard let url = plistURL(for: schedule) else {
            Logger.wakeup.error("LaunchAgentManager: homeDirectoryNotFound")
            throw WakeUpError.homeDirectoryNotFound
        }

        Logger.wakeup.info("LaunchAgentManager: Installing plist at \(url.path)")
        let wasServiceLoaded = try serviceIsLoaded(schedule)
        updateCachedLoadedState(wasServiceLoaded, for: schedule)
        let hadPreviousPlist = fileManager.fileExists(atPath: url.path)
        let previousPlistData: Data?
        if hadPreviousPlist {
            do {
                previousPlistData = try Data(contentsOf: url)
            } catch {
                throw WakeUpError.launchAgentWriteFailed(error)
            }
        } else {
            previousPlistData = nil
        }

        // Generate and stage the new plist before stopping a working service.
        let plistData: Data
        do {
            plistData = try generatePlist(for: schedule)
        } catch {
            throw WakeUpError.launchAgentWriteFailed(error)
        }
        Logger.wakeup.info("LaunchAgentManager: Generated plist data (\(plistData.count) bytes)")

        // Ensure directory exists
        if let directory = launchAgentsURL {
            do {
                // Create LaunchAgents directory if needed.
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                Logger.wakeup.info("LaunchAgentManager: Directory ensured at \(directory.path)")
            } catch {
                Logger.wakeup.error("LaunchAgentManager: Failed to create directory: \(error.localizedDescription)")
                throw WakeUpError.launchAgentWriteFailed(error)
            }
        }

        // Write plist file
        do {
            // Persist plist atomically to avoid partial writes.
            try plistData.write(to: url, options: .atomic)
            Logger.wakeup.info("LaunchAgentManager: Plist written successfully")
        } catch {
            Logger.wakeup.error("LaunchAgentManager: Failed to write plist: \(error.localizedDescription)")
            throw WakeUpError.launchAgentWriteFailed(error)
        }

        // Only after staging succeeds do we stop the old service and load the
        // replacement. Any failure restores and verifies the prior state.
        do {
            if wasServiceLoaded {
                Logger.wakeup.info("LaunchAgentManager: Unloading existing agent")
                try unload(schedule: schedule)
            }
            try load(schedule: schedule)
        } catch {
            let originalError = error
            do {
                try rollbackPlist(
                    at: url,
                    previousData: previousPlistData,
                    schedule: schedule
                )
            } catch {
                let rollbackError = error
                throw WakeUpError.launchAgentLoadFailed(
                    LaunchAgentRollbackFailure(
                        originalError: originalError,
                        rollbackError: rollbackError
                    )
                )
            }
            throw originalError
        }
    }

    /// Uninstalls a LaunchAgent for the given schedule
    func uninstall(schedule: WakeUpSchedule) throws {
        guard let url = plistURL(for: schedule) else {
            throw WakeUpError.homeDirectoryNotFound
        }

        let previousPlistData: Data?
        if fileManager.fileExists(atPath: url.path) {
            do {
                previousPlistData = try Data(contentsOf: url)
            } catch {
                throw WakeUpError.launchAgentWriteFailed(error)
            }
        } else {
            previousPlistData = nil
        }

        // Never remove the plist while launchd may still be running the job.
        try unload(schedule: schedule)
        if fileManager.fileExists(atPath: url.path) {
            do {
                try removeItem(url)
            } catch {
                let removalError = WakeUpError.launchAgentWriteFailed(error)
                do {
                    if !fileManager.fileExists(atPath: url.path), let previousPlistData {
                        try previousPlistData.write(to: url, options: .atomic)
                    }
                    try load(schedule: schedule)
                } catch {
                    throw WakeUpError.launchAgentLoadFailed(
                        LaunchAgentRollbackFailure(
                            originalError: removalError,
                            rollbackError: error
                        )
                    )
                }
                throw removalError
            }
        }
    }

    /// Loads a LaunchAgent using launchctl bootstrap (modern API)
    private func load(schedule: WakeUpSchedule) throws {
        guard let url = plistURL(for: schedule) else { return }

        let arguments = ["bootstrap", "gui/\(getuid())", url.path]
        let result = try runLaunchCtl(arguments, operation: "bootstrap")
        try requireSuccess(result, operation: "bootstrap")
        guard try serviceIsLoaded(schedule) else {
            throw WakeUpError.launchAgentLoadFailed(
                LaunchCtlCommandFailure(
                    operation: "bootstrap verification",
                    terminationStatus: -1,
                    standardError: "service is not loaded"
                )
            )
        }
        updateCachedLoadedState(true, for: schedule)
    }

    /// Unloads a LaunchAgent using launchctl bootout (modern API)
    private func unload(schedule: WakeUpSchedule) throws {
        let result = try runLaunchCtl([
            "bootout",
            "gui/\(getuid())/\(schedule.launchAgentLabel)"
        ], operation: "bootout")

        let remainsLoaded = try serviceIsLoaded(schedule)
        if result.terminationStatus != 0, remainsLoaded {
            updateCachedLoadedState(true, for: schedule)
            throw WakeUpError.launchAgentLoadFailed(
                commandFailure(for: result, operation: "bootout")
            )
        }
        guard !remainsLoaded else {
            updateCachedLoadedState(true, for: schedule)
            throw WakeUpError.launchAgentLoadFailed(
                LaunchCtlCommandFailure(
                    operation: "bootout verification",
                    terminationStatus: result.terminationStatus,
                    standardError: "service is still loaded"
                )
            )
        }
        // A nonzero bootout result is acceptable only after print confirms the
        // service was already absent.
        updateCachedLoadedState(false, for: schedule)
    }

    private func rollbackPlist(
        at url: URL,
        previousData: Data?,
        schedule: WakeUpSchedule
    ) throws {
        if let previousData {
            try previousData.write(to: url, options: .atomic)
            if try serviceIsLoaded(schedule) {
                // A failed bootstrap can still leave the replacement loaded.
                // Stop it before loading the restored plist so success means
                // the original configuration is actually active again.
                try unload(schedule: schedule)
            }
            try load(schedule: schedule)
        } else {
            if try serviceIsLoaded(schedule) {
                try unload(schedule: schedule)
            }
            if fileManager.fileExists(atPath: url.path) {
                try removeItem(url)
            }
            guard try !serviceIsLoaded(schedule) else {
                throw WakeUpError.launchAgentLoadFailed(
                    LaunchCtlCommandFailure(
                        operation: "rollback verification",
                        terminationStatus: -1,
                        standardError: "service is still loaded"
                    )
                )
            }
            updateCachedLoadedState(false, for: schedule)
        }
    }

    private func serviceIsLoaded(_ schedule: WakeUpSchedule) throws -> Bool {
        let result = try runLaunchCtl([
            "print",
            "gui/\(getuid())/\(schedule.launchAgentLabel)"
        ], operation: "print")
        switch result.terminationStatus {
        case 0:
            return true
        case 113:
            return false
        default:
            throw WakeUpError.launchAgentLoadFailed(
                commandFailure(for: result, operation: "print")
            )
        }
    }

    private func updateCachedLoadedState(
        _ isLoaded: Bool,
        for schedule: WakeUpSchedule
    ) {
        if isLoaded {
            loadedLabels.insert(schedule.launchAgentLabel)
        } else {
            loadedLabels.remove(schedule.launchAgentLabel)
        }
    }

    private func runLaunchCtl(
        _ arguments: [String],
        operation: String
    ) throws -> LaunchCtlResult {
        do {
            return try launchCtlRunner(arguments)
        } catch {
            throw WakeUpError.launchAgentLoadFailed(error)
        }
    }

    private func requireSuccess(
        _ result: LaunchCtlResult,
        operation: String
    ) throws {
        guard result.terminationStatus == 0 else {
            let failure = commandFailure(for: result, operation: operation)
            Logger.wakeup.error("LaunchAgent command failed: \(failure.localizedDescription)")
            throw WakeUpError.launchAgentLoadFailed(failure)
        }
    }

    private func commandFailure(
        for result: LaunchCtlResult,
        operation: String
    ) -> LaunchCtlCommandFailure {
        LaunchCtlCommandFailure(
            operation: operation,
            terminationStatus: result.terminationStatus,
            standardError: result.standardError
        )
    }

    /// Generates plist data for a schedule
    private func generatePlist(for schedule: WakeUpSchedule) throws -> Data {
        // Build full command with logging prefix.
        let fullCommand = WakeUpCommandBuilder.buildLaunchAgentCommand(for: schedule)

        // Build StartCalendarInterval array
        var calendarIntervals: [[String: Int]] = []
        for hour in schedule.enabledHours.sorted() {
            calendarIntervals.append([
                "Hour": hour,
                "Minute": 0
            ])
        }

        // Compose LaunchAgent plist payload.
        let plist: [String: Any] = [
            "Label": schedule.launchAgentLabel,
            "ProgramArguments": [
                ShellPathResolver.resolveLoginShellPath(),
                "-l",
                "-c",
                fullCommand
            ],
            "StartCalendarInterval": calendarIntervals,
            "StandardOutPath": schedule.logPath,
            "StandardErrorPath": schedule.logPath,
            "RunAtLoad": false
        ]

        return try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
    }
}

// MARK: - CLI Executor

enum WakeUpCommandBuilder {
    static func buildLaunchAgentCommand(for schedule: WakeUpSchedule) -> String {
        let prefixedCommand = ShellCommandPathPrefixer.prefixIfNeeded(command: schedule.cliCommand)
        let guardedCommand = wrapWithTimeout(command: prefixedCommand)
        return buildCommand(for: schedule, command: guardedCommand, marker: nil)
    }

    static func buildTestCommand(for schedule: WakeUpSchedule) -> String {
        let baseCommand = buildCommand(for: schedule, command: schedule.cliCommand, marker: "[TEST]")
        return buildLoggedTestCommand(command: baseCommand, logPath: schedule.logPath)
    }

    static func buildLoggedTestCommand(command: String, logPath: String) -> String {
        "set -o pipefail; { \(command); } 2>&1 | tee -a \"\(logPath)\""
    }

    private static func buildCommand(
        for schedule: WakeUpSchedule,
        command: String,
        marker: String?
    ) -> String {
        let markerSuffix = marker.map { " \($0)" } ?? ""
        let escapedCommand = command.replacingOccurrences(of: "\"", with: "\\\"")
        return "echo \"=== $(date)\(markerSuffix) ===\" && echo \"Command: \(escapedCommand)\" && mkdir -p ~/.agentlimits && cd ~/.agentlimits && \(command)"
    }

    private static func wrapWithTimeout(command: String) -> String {
        let timeout = LaunchAgentConfig.cliTimeoutSeconds
        return "{ \(command) & pid=$!; ( sleep \(timeout); if kill -0 $pid 2>/dev/null; then kill $pid; sleep 2; kill -0 $pid 2>/dev/null && kill -9 $pid; fi ) & watchdog=$!; wait $pid; exit_code=$?; kill -9 $watchdog 2>/dev/null; exit $exit_code; }"
    }
}

/// Executes CLI commands for manual wake-up testing.
/// Uses ShellExecutor for command execution with timeout support.
final class CLIExecutor {
    private let shellExecutor: ShellExecutor

    /// Creates a new CLI executor with the specified timeout.
    /// - Parameter timeout: Maximum time to wait for command completion (default: 30 seconds)
    init(timeout: TimeInterval = 30) {
        self.shellExecutor = ShellExecutor(timeout: timeout)
    }

    /// Executes a CLI command for the given schedule and returns the output.
    /// Logs execution to the schedule's log file with a [TEST] marker.
    /// - Parameter schedule: The wake-up schedule containing the command to execute
    /// - Returns: The command output as a string
    /// - Throws: `WakeUpError` if execution fails
    func execute(for schedule: WakeUpSchedule) async throws -> String {
        // Build command with logging (same format as LaunchAgent, with [TEST] marker).
        let command = WakeUpCommandBuilder.buildTestCommand(for: schedule)

        do {
            return try await shellExecutor.executeString(command: command)
        } catch let error as ShellExecutorError {
            throw mapShellError(error, schedule: schedule)
        }
    }

    /// Maps ShellExecutorError to WakeUpError for domain-specific error messages.
    /// - Parameters:
    ///   - error: The shell execution error
    ///   - schedule: The schedule that was being executed (for error context)
    /// - Returns: A WakeUpError with appropriate message
    private func mapShellError(_ error: ShellExecutorError, schedule: WakeUpSchedule) -> WakeUpError {
        switch error {
        case .launchFailed:
            return .cliNotFound(command: schedule.cliCommand)
        case .timeout:
            return .timeout
        case .executionFailed(let exitCode, let stderr):
            return .executionFailed(exitCode: exitCode, stderr: stderr)
        }
    }
}

// MARK: - Schedule Store

/// Persists wake-up schedules to UserDefaults
final class WakeUpScheduleStore {
    private let userDefaults: UserDefaults
    private let key = "wake_up_schedules"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Loads all schedules from storage
    func loadSchedules() -> [UsageProvider: WakeUpSchedule] {
        guard let data = userDefaults.data(forKey: key),
              let schedules = try? JSONDecoder().decode([WakeUpSchedule].self, from: data) else {
            return makeDefaultSchedules()
        }
        return Dictionary(uniqueKeysWithValues: schedules.map { ($0.provider, $0) })
    }

    /// Saves all schedules to storage
    func saveSchedules(_ schedules: [UsageProvider: WakeUpSchedule]) {
        let array = Array(schedules.values)
        if let data = try? JSONEncoder().encode(array) {
            userDefaults.set(data, forKey: key)
        }
    }

    /// Creates default schedules for all providers
    private func makeDefaultSchedules() -> [UsageProvider: WakeUpSchedule] {
        Dictionary(uniqueKeysWithValues: UsageProvider.allCases.map {
            ($0, WakeUpSchedule.defaultSchedule(for: $0))
        })
    }
}

// MARK: - Wake Up Scheduler

/// Manages scheduled wake-up calls for AI coding assistants via LaunchAgent
@MainActor
final class WakeUpScheduler: ObservableObject {
    static let shared = WakeUpScheduler()

    /// Providers that support WakeUp CLI scheduling
    static let supportedProviders: [UsageProvider] = UsageProvider.allCases.filter { $0 != .githubCopilot }

    @Published private(set) var schedules: [UsageProvider: WakeUpSchedule]
    @Published private(set) var lastWakeUpResults: [UsageProvider: WakeUpResult] = [:]
    @Published private(set) var isTestRunning: [UsageProvider: Bool] = [:]
    @Published private(set) var scheduleErrors: [UsageProvider: WakeUpError] = [:]

    private let launchAgentManager: LaunchAgentManager
    private let executor: CLIExecutor
    private let store: WakeUpScheduleStore

    convenience init() {
        self.init(
            launchAgentManager: LaunchAgentManager(),
            executor: CLIExecutor(),
            store: WakeUpScheduleStore(),
            syncOnInit: true
        )
    }

    convenience init(
        launchAgentManager: LaunchAgentManager,
        store: WakeUpScheduleStore,
        syncOnInit: Bool = true
    ) {
        self.init(
            launchAgentManager: launchAgentManager,
            executor: CLIExecutor(),
            store: store,
            syncOnInit: syncOnInit
        )
    }

    init(
        launchAgentManager: LaunchAgentManager,
        executor: CLIExecutor,
        store: WakeUpScheduleStore,
        syncOnInit: Bool = true
    ) {
        self.launchAgentManager = launchAgentManager
        self.executor = executor
        self.store = store
        self.schedules = store.loadSchedules()

        // Initialize isTestRunning
        for provider in UsageProvider.allCases {
            isTestRunning[provider] = false
        }

        if syncOnInit {
            syncLaunchAgents()
        }
    }

    /// Returns whether a LaunchAgent is installed for a provider
    func isLaunchAgentInstalled(for provider: UsageProvider) -> Bool {
        guard let schedule = schedules[provider] else { return false }
        return launchAgentManager.isInstalled(for: schedule)
    }

    /// Updates schedule for a provider and syncs LaunchAgent
    func updateSchedule(_ schedule: WakeUpSchedule) {
        Logger.wakeup.debug("WakeUpScheduler: updateSchedule provider=\(schedule.provider.rawValue) isEnabled=\(schedule.isEnabled) hours=\(schedule.enabledHours.count)")
        do {
            if schedule.isEnabled && !schedule.enabledHours.isEmpty {
                try launchAgentManager.install(schedule: schedule)
            } else {
                try launchAgentManager.uninstall(schedule: schedule)
            }
            // Commit UI and persistence only after launchd reached the requested state.
            schedules[schedule.provider] = schedule
            store.saveSchedules(schedules)
            scheduleErrors[schedule.provider] = nil
        } catch {
            Logger.wakeup.error("WakeUpScheduler: Failed to update LaunchAgent: \(error.localizedDescription)")
            scheduleErrors[schedule.provider] = makeWakeUpError(error)
        }
    }

    /// Manually triggers a wake-up for testing
    func triggerWakeUp(for provider: UsageProvider) async {
        guard let schedule = schedules[provider] else { return }

        isTestRunning[provider] = true
        defer { isTestRunning[provider] = false }

        do {
            let output = try await executor.execute(for: schedule)
            lastWakeUpResults[provider] = .success(output: output)
            Logger.wakeup.info("WakeUpScheduler: Successfully tested \(provider.displayName)")
        } catch let error as WakeUpError {
            lastWakeUpResults[provider] = .failure(error: error)
            Logger.wakeup.error("WakeUpScheduler: Test failed for \(provider.displayName): \(error.localizedDescription)")
        } catch {
            let wakeUpError = WakeUpError.executionFailed(exitCode: -1, stderr: error.localizedDescription)
            lastWakeUpResults[provider] = .failure(error: wakeUpError)
            Logger.wakeup.error("WakeUpScheduler: Test failed for \(provider.displayName): \(error.localizedDescription)")
        }
    }

    /// Syncs LaunchAgents with saved schedules on startup
    private func syncLaunchAgents() {
        for provider in UsageProvider.allCases {
            guard let schedule = schedules[provider] else { continue }

            if schedule.isEnabled && !schedule.enabledHours.isEmpty {
                do {
                    try launchAgentManager.install(schedule: schedule)
                    scheduleErrors[provider] = nil
                } catch {
                    Logger.wakeup.error("WakeUpScheduler: Failed to sync LaunchAgent for \(provider.displayName): \(error.localizedDescription)")
                    scheduleErrors[provider] = makeWakeUpError(error)
                }
            } else {
                do {
                    try launchAgentManager.uninstall(schedule: schedule)
                    scheduleErrors[provider] = nil
                } catch {
                    Logger.wakeup.error("WakeUpScheduler: Failed to remove LaunchAgent for \(provider.displayName): \(error.localizedDescription)")
                    scheduleErrors[provider] = makeWakeUpError(error)
                }
            }
        }
    }

    /// Uninstalls all LaunchAgents (for app cleanup)
    func uninstallAllLaunchAgents() {
        for provider in UsageProvider.allCases {
            guard let schedule = schedules[provider] else { continue }
            do {
                try launchAgentManager.uninstall(schedule: schedule)
                scheduleErrors[provider] = nil
            } catch {
                Logger.wakeup.error("WakeUpScheduler: Failed to uninstall \(provider.displayName): \(error.localizedDescription)")
                scheduleErrors[provider] = makeWakeUpError(error)
            }
        }
    }

    private func makeWakeUpError(_ error: Error) -> WakeUpError {
        if let wakeUpError = error as? WakeUpError {
            return wakeUpError
        }
        return .launchAgentLoadFailed(error)
    }
}
