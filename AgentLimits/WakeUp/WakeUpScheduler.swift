// MARK: - WakeUpScheduler.swift
// Manages scheduled CLI invocations via LaunchAgent to wake up Claude Code and Codex sessions.
// Creates plist files in ~/Library/LaunchAgents/ for launchd to execute CLI commands.

import Combine
import Darwin
@preconcurrency import Dispatch
@preconcurrency import Foundation
import OSLog

// MARK: - Configuration

/// LaunchAgent configuration constants
enum LaunchAgentConfig {
    static let labelPrefix = "com.jimboha.agentlimits.macos.wakeup"
    static let launchAgentsPath = "Library/LaunchAgents"
    static let logDirectoryPath = "Library/Logs/AgentLimitsForked"
    static let logFilePrefix = "agentlimits-forked-wakeup"
    static let workingDirectoryPath = ".agentlimits-forked"
    static let cliTimeoutSeconds: Int = 30

    static func logFileName(for provider: UsageProvider) -> String {
        "\(logFilePrefix)-\(provider.rawValue).log"
    }
}

struct UnsafeWakeUpLogDirectory: LocalizedError {
    let path: String

    var errorDescription: String? {
        "Wake-up log directory is not a private, user-owned directory: \(path)"
    }
}

struct UnsafeWakeUpWorkingDirectory: LocalizedError {
    let path: String

    var errorDescription: String? {
        "Wake-up working directory is not a private, user-owned directory: \(path)"
    }
}

struct UnsafeLaunchAgentStorage: LocalizedError {
    let path: String

    var errorDescription: String? {
        "LaunchAgent storage is not private, user-owned, and free of symbolic links: \(path)"
    }
}

struct MissingLoadedLaunchAgentConfiguration: LocalizedError {
    let path: String

    var errorDescription: String? {
        "The loaded LaunchAgent has no recoverable plist at: \(path)"
    }
}

/// Performs every LaunchAgent plist mutation relative to validated directory
/// descriptors. This prevents path substitution and never publishes a plist
/// before its contents and owner-only permissions are final.
enum SecureLaunchAgentPlistStore {
    private struct MissingDirectory: Error {}

    private static let directoryComponents = ["Library", "LaunchAgents"]
    private static let privateFilePermissions: mode_t = 0o600
    private static let safeDirectoryPermissions: mode_t = 0o755
    private static let maximumPlistBytes = 1_048_576
    private static let unsafeDirectoryACLPermissions: acl_permset_mask_t =
        acl_permset_mask_t(ACL_ADD_FILE.rawValue)
        | acl_permset_mask_t(ACL_ADD_SUBDIRECTORY.rawValue)
        | acl_permset_mask_t(ACL_DELETE.rawValue)
        | acl_permset_mask_t(ACL_DELETE_CHILD.rawValue)
        | acl_permset_mask_t(ACL_WRITE_ATTRIBUTES.rawValue)
        | acl_permset_mask_t(ACL_WRITE_EXTATTRIBUTES.rawValue)
        | acl_permset_mask_t(ACL_WRITE_SECURITY.rawValue)
        | acl_permset_mask_t(ACL_CHANGE_OWNER.rawValue)

    static func ensureDirectory(homeDirectory: URL) throws {
        try withDirectory(homeDirectory: homeDirectory) { _ in }
    }

    static func readIfPresent(
        at url: URL,
        homeDirectory: URL
    ) throws -> Data? {
        try validate(url: url, homeDirectory: homeDirectory)
        return try withDirectory(homeDirectory: homeDirectory) { directoryFD in
            guard try destinationExists(
                named: url.lastPathComponent,
                in: directoryFD,
                path: url.path
            ) else {
                return nil
            }
            let descriptor = openat(
                directoryFD,
                url.lastPathComponent,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
            )
            if descriptor == -1, errno == ENOENT {
                return nil
            }
            guard descriptor >= 0 else {
                throw posixError(operation: "open", path: url.path)
            }
            defer { _ = Darwin.close(descriptor) }
            try validateFileDescriptor(descriptor, path: url.path)

            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while true {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count == 0 {
                    break
                }
                if count == -1, errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    throw posixError(operation: "read", path: url.path)
                }
                guard result.count + count <= maximumPlistBytes else {
                    throw CocoaError(
                        .fileReadTooLarge,
                        userInfo: [NSFilePathErrorKey: url.path]
                    )
                }
                result.append(buffer, count: count)
            }
            return result
        }
    }

    static func containsRegularFile(
        at url: URL,
        homeDirectory: URL
    ) throws -> Bool {
        try validate(url: url, homeDirectory: homeDirectory)
        do {
            return try withDirectory(
                homeDirectory: homeDirectory,
                createMissing: false
            ) { directoryFD in
                try destinationExists(
                    named: url.lastPathComponent,
                    in: directoryFD,
                    path: url.path
                )
            }
        } catch is MissingDirectory {
            return false
        }
    }

    static func write(
        _ data: Data,
        to url: URL,
        homeDirectory: URL,
        beforeCommit: () throws -> Void = {}
    ) throws {
        try validate(url: url, homeDirectory: homeDirectory)
        try withDirectory(homeDirectory: homeDirectory) { directoryFD in
            _ = try destinationExists(
                named: url.lastPathComponent,
                in: directoryFD,
                path: url.path
            )

            let temporaryName = ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
            var temporaryExists = false
            defer {
                if temporaryExists {
                    _ = unlinkat(directoryFD, temporaryName, 0)
                }
            }

            var descriptor = openat(
                directoryFD,
                temporaryName,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
                privateFilePermissions
            )
            guard descriptor >= 0 else {
                throw posixError(
                    operation: "create",
                    path: url.deletingLastPathComponent()
                        .appendingPathComponent(temporaryName).path
                )
            }
            temporaryExists = true
            defer {
                if descriptor >= 0 {
                    _ = Darwin.close(descriptor)
                }
            }

            // A file can inherit an allow ACL even when its POSIX mode is
            // 0600. Remove it before writing any user-entered arguments.
            try stripExtendedACL(descriptor, path: url.path)
            guard fchmod(descriptor, privateFilePermissions) == 0 else {
                throw posixError(operation: "chmod", path: url.path)
            }
            try data.withUnsafeBytes { rawBuffer in
                var written = 0
                while written < rawBuffer.count {
                    guard let baseAddress = rawBuffer.baseAddress else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let count = Darwin.write(
                        descriptor,
                        baseAddress.advanced(by: written),
                        rawBuffer.count - written
                    )
                    if count == -1, errno == EINTR {
                        continue
                    }
                    guard count > 0 else {
                        throw posixError(operation: "write", path: url.path)
                    }
                    written += count
                }
            }
            guard fsync(descriptor) == 0 else {
                throw posixError(operation: "fsync", path: url.path)
            }
            try validateFileDescriptor(
                descriptor,
                path: url.path,
                requirePrivatePermissions: true
            )

            let descriptorToClose = descriptor
            descriptor = -1
            guard Darwin.close(descriptorToClose) == 0 else {
                throw posixError(operation: "close", path: url.path)
            }

            // Re-check immediately before the atomic publication. A failure
            // here leaves the prior plist untouched and the temp file private.
            _ = try destinationExists(
                named: url.lastPathComponent,
                in: directoryFD,
                path: url.path
            )
            try beforeCommit()
            guard renameat(
                directoryFD,
                temporaryName,
                directoryFD,
                url.lastPathComponent
            ) == 0 else {
                throw posixError(operation: "rename", path: url.path)
            }
            temporaryExists = false
            // Deliberately no fallible operation after the atomic commit.
        }
    }

    static func remove(at url: URL, homeDirectory: URL) throws {
        try validate(url: url, homeDirectory: homeDirectory)
        try withDirectory(homeDirectory: homeDirectory) { directoryFD in
            guard try destinationExists(
                named: url.lastPathComponent,
                in: directoryFD,
                path: url.path
            ) else {
                throw CocoaError(
                    .fileNoSuchFile,
                    userInfo: [NSFilePathErrorKey: url.path]
                )
            }
            guard unlinkat(directoryFD, url.lastPathComponent, 0) == 0 else {
                throw posixError(operation: "unlink", path: url.path)
            }
        }
    }

    private static func withDirectory<T>(
        homeDirectory: URL,
        createMissing: Bool = true,
        body: (Int32) throws -> T
    ) throws -> T {
        var currentFD = open(
            homeDirectory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if currentFD == -1, errno == ENOENT, !createMissing {
            throw MissingDirectory()
        }
        guard currentFD >= 0 else {
            throw UnsafeLaunchAgentStorage(path: homeDirectory.path)
        }
        defer { _ = Darwin.close(currentFD) }
        try validateDirectoryDescriptor(currentFD, path: homeDirectory.path)

        var currentURL = homeDirectory
        for component in directoryComponents {
            currentURL.appendPathComponent(component, isDirectory: true)
            var nextFD = openat(
                currentFD,
                component,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
            if nextFD == -1, errno == ENOENT {
                guard createMissing else {
                    throw MissingDirectory()
                }
                guard mkdirat(
                    currentFD,
                    component,
                    safeDirectoryPermissions
                ) == 0 || errno == EEXIST else {
                    throw posixError(
                        operation: "mkdir",
                        path: currentURL.path
                    )
                }
                nextFD = openat(
                    currentFD,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard nextFD >= 0 else {
                throw UnsafeLaunchAgentStorage(path: currentURL.path)
            }
            do {
                try validateDirectoryDescriptor(nextFD, path: currentURL.path)
            } catch {
                _ = Darwin.close(nextFD)
                throw error
            }
            _ = Darwin.close(currentFD)
            currentFD = nextFD
        }
        return try body(currentFD)
    }

    private static func validate(
        url: URL,
        homeDirectory: URL
    ) throws {
        let expectedDirectory = homeDirectory
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("LaunchAgents", isDirectory: true)
            .standardizedFileURL
        guard url.deletingLastPathComponent().standardizedFileURL
                == expectedDirectory,
              !url.lastPathComponent.isEmpty,
              url.lastPathComponent != ".",
              url.lastPathComponent != "..",
              !url.lastPathComponent.contains("/") else {
            throw UnsafeLaunchAgentStorage(path: url.path)
        }
    }

    private static func validateDirectoryDescriptor(
        _ descriptor: Int32,
        path: String
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o022 == 0 else {
            throw UnsafeLaunchAgentStorage(path: path)
        }
        try ensureNoUnsafeDirectoryACL(descriptor, path: path)
    }

    private static func validateFileDescriptor(
        _ descriptor: Int32,
        path: String,
        requirePrivatePermissions: Bool = false
    ) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG,
              !requirePrivatePermissions || info.st_mode & 0o777 == 0o600 else {
            throw UnsafeLaunchAgentStorage(path: path)
        }
        if requirePrivatePermissions {
            try ensureNoExtendedACLEntries(descriptor, path: path)
        }
    }

    private static func destinationExists(
        named name: String,
        in directoryFD: Int32,
        path: String
    ) throws -> Bool {
        var info = stat()
        if fstatat(directoryFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 {
            guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG else {
                throw UnsafeLaunchAgentStorage(path: path)
            }
            return true
        } else if errno != ENOENT {
            throw posixError(operation: "stat", path: path)
        }
        return false
    }

    private static func stripExtendedACL(
        _ descriptor: Int32,
        path: String
    ) throws {
        guard let emptyACL = acl_init(0) else {
            throw posixError(operation: "initialize ACL", path: path)
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(emptyACL)) }
        guard acl_set_fd_np(descriptor, emptyACL, ACL_TYPE_EXTENDED) == 0 else {
            throw posixError(operation: "clear ACL", path: path)
        }
        try ensureNoExtendedACLEntries(descriptor, path: path)
    }

    private static func ensureNoUnsafeDirectoryACL(
        _ descriptor: Int32,
        path: String
    ) throws {
        try forEachExtendedACLEntry(descriptor, path: path) { entry in
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else {
                throw posixError(operation: "read ACL tag", path: path)
            }
            guard tag == ACL_EXTENDED_ALLOW else {
                return
            }
            // A file-inheriting allow ACE creates a disclosure window: a
            // second account can open the empty temp file before its inherited
            // ACL is cleared, retain that descriptor, then read later writes.
            if try aclFlag(
                ACL_ENTRY_FILE_INHERIT,
                isSetOn: entry,
                path: path
            ) {
                throw UnsafeLaunchAgentStorage(path: path)
            }
            var permissions: acl_permset_mask_t = 0
            guard acl_get_permset_mask_np(entry, &permissions) == 0 else {
                throw posixError(
                    operation: "read ACL permissions",
                    path: path
                )
            }
            guard permissions & unsafeDirectoryACLPermissions == 0 else {
                throw UnsafeLaunchAgentStorage(path: path)
            }
        }
    }

    private static func aclFlag(
        _ flag: acl_flag_t,
        isSetOn entry: acl_entry_t,
        path: String
    ) throws -> Bool {
        var flagSet: acl_flagset_t?
        guard acl_get_flagset_np(
            UnsafeMutableRawPointer(entry),
            &flagSet
        ) == 0, let flagSet else {
            throw posixError(operation: "read ACL flags", path: path)
        }
        let result = acl_get_flag_np(flagSet, flag)
        guard result >= 0 else {
            throw posixError(operation: "read ACL flag", path: path)
        }
        return result == 1
    }

    private static func ensureNoExtendedACLEntries(
        _ descriptor: Int32,
        path: String
    ) throws {
        try forEachExtendedACLEntry(descriptor, path: path) { _ in
            throw UnsafeLaunchAgentStorage(path: path)
        }
    }

    private static func forEachExtendedACLEntry(
        _ descriptor: Int32,
        path: String,
        body: (acl_entry_t) throws -> Void
    ) throws {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            let errorCode = errno
            if errorCode == ENOENT {
                return
            }
            throw posixError(
                operation: "read ACL",
                path: path,
                errorCode: errorCode
            )
        }
        defer { _ = acl_free(UnsafeMutableRawPointer(acl)) }

        var entryIdentifier = Int32(ACL_FIRST_ENTRY.rawValue)
        while true {
            var entry: acl_entry_t?
            if acl_get_entry(acl, entryIdentifier, &entry) == 0 {
                guard let entry else {
                    throw UnsafeLaunchAgentStorage(path: path)
                }
                try body(entry)
                entryIdentifier = Int32(ACL_NEXT_ENTRY.rawValue)
                continue
            }
            let errorCode = errno
            if errorCode == EINVAL {
                return
            }
            throw posixError(
                operation: "iterate ACL",
                path: path,
                errorCode: errorCode
            )
        }
    }

    private static func posixError(
        operation: String,
        path: String,
        errorCode: Int32 = errno
    ) -> NSError {
        return NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errorCode),
            userInfo: [
                NSFilePathErrorKey: path,
                NSLocalizedDescriptionKey: "\(operation) failed for \(path)"
            ]
        )
    }
}

enum WakeUpWorkingDirectoryResolver {
    static func workingDirectory(
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        (homeDirectory ?? WakeUpLogPathResolver.realHomeDirectory(
            fileManager: fileManager
        )).appendingPathComponent(
            LaunchAgentConfig.workingDirectoryPath,
            isDirectory: true
        )
    }

    @discardableResult
    static func ensureSecureWorkingDirectory(
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = workingDirectory(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            guard isDirectory.boolValue,
                  values.isSymbolicLink != true,
                  ownerID == getuid() else {
                throw UnsafeWakeUpWorkingDirectory(path: directory.path)
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        return directory
    }
}

enum WakeUpLogPathResolver {
    static func realHomeDirectory(fileManager: FileManager = .default) -> URL {
        if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return URL(fileURLWithPath: home, isDirectory: true)
        }
        return fileManager.homeDirectoryForCurrentUser
    }

    static func logDirectory(
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        (homeDirectory ?? realHomeDirectory(fileManager: fileManager))
            .appendingPathComponent(LaunchAgentConfig.logDirectoryPath, isDirectory: true)
    }

    static func logURL(
        for provider: UsageProvider,
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        logDirectory(homeDirectory: homeDirectory, fileManager: fileManager)
            .appendingPathComponent(LaunchAgentConfig.logFileName(for: provider))
    }

    @discardableResult
    static func ensureSecureLogDirectory(
        homeDirectory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = logDirectory(
            homeDirectory: homeDirectory,
            fileManager: fileManager
        )
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let values = try directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            let ownerID = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
            guard isDirectory.boolValue,
                  values.isSymbolicLink != true,
                  ownerID == getuid() else {
                throw UnsafeWakeUpLogDirectory(path: directory.path)
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        return directory
    }
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

    /// Returns the CLI command rendered safely for display.
    var cliCommand: String {
        do {
            return try makeCLIInvocation().shellCommand
        } catch {
            return "[\(error.localizedDescription)]"
        }
    }

    /// Builds literal argv without evaluating the additional-arguments field.
    func makeCLIInvocation() throws -> CLICommandInvocation {
        let arguments: [String]
        do {
            arguments = try CLIArgumentParser.parse(additionalArgs)
        } catch {
            throw WakeUpError.invalidArguments(error.localizedDescription)
        }
        let base: CLICommandInvocation
        do {
            base = try makeBaseCLIInvocation()
        } catch {
            throw WakeUpError.invalidExecutable(error.localizedDescription)
        }
        return CLICommandInvocation(
            executable: base.executable,
            arguments: base.arguments + arguments
        )
    }

    private func makeBaseCLIInvocation() throws -> CLICommandInvocation {
        switch provider {
        case .chatgptCodex:
            let codexExecutable = try CLICommandPathResolver.resolveExecutable(
                for: .codex,
                defaultName: "codex"
            )
            return CLICommandInvocation(
                executable: codexExecutable,
                arguments: ["exec", "--skip-git-repo-check", "hello"]
            )
        case .claudeCode:
            let claudeExecutable = try CLICommandPathResolver.resolveExecutable(
                for: .claude,
                defaultName: "claude"
            )
            return CLICommandInvocation(
                executable: claudeExecutable,
                arguments: ["-p", "hello"]
            )
        case .githubCopilot:
            return CLICommandInvocation(executable: "", arguments: [])
        }
    }

    /// Returns the log file path for this schedule
    var logPath: String {
        WakeUpLogPathResolver.logURL(for: provider).path
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
    case outputLimitExceeded(maximumBytes: Int)
    case invalidExecutable(String)
    case invalidArguments(String)
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
        case .outputLimitExceeded(let maximumBytes):
            return "CLI output exceeded the \(maximumBytes)-byte limit"
        case .invalidExecutable(let message):
            return message
        case .invalidArguments(let message):
            return "Invalid additional arguments: \(message)"
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

enum LaunchCtlProcessRunner {
    nonisolated static func run(arguments: [String]) throws -> LaunchCtlResult {
        try run(
            arguments: arguments,
            executableURL: URL(fileURLWithPath: "/bin/launchctl")
        )
    }

    nonisolated static func run(
        arguments: [String],
        executableURL: URL
    ) throws -> LaunchCtlResult {
        let process = Process()
        let standardError = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = standardError

        try process.run()
        let waiter = Thread {
            process.waitUntilExit()
            completion.signal()
        }
        waiter.name = "AgentLimits.launchctl-waiter"
        waiter.start()
        // Drain while launchctl runs so its stderr pipe cannot block completion.
        let errorData = standardError.fileHandleForReading.readDataToEndOfFile()
        // Process.waitUntilExit() spins the caller's run loop. During hosted
        // XCTest startup that can re-enter XCTest before app launch returns;
        // XCTest then waits for launch while the process waiter cannot resume.
        // Keep that call on a dedicated worker with no main-run-loop dependency.
        completion.wait()
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
    private let beforePlistCommit: () throws -> Void
    private var loadedLabels: Set<String> = []

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        launchCtlRunner: @escaping ([String]) throws -> LaunchCtlResult = LaunchCtlProcessRunner.run,
        removeItem: ((URL) throws -> Void)? = nil,
        beforePlistCommit: (() throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectoryOverride = homeDirectory
        self.launchCtlRunner = launchCtlRunner
        let secureHomeDirectory = homeDirectory
            ?? WakeUpLogPathResolver.realHomeDirectory(fileManager: fileManager)
        self.removeItem = removeItem ?? {
            try SecureLaunchAgentPlistStore.remove(
                at: $0,
                homeDirectory: secureHomeDirectory
            )
        }
        self.beforePlistCommit = beforePlistCommit ?? {}
    }

    /// Returns the real user home directory (not sandboxed container)
    private var realHomeDirectory: URL {
        if let homeDirectoryOverride {
            return homeDirectoryOverride
        }
        return WakeUpLogPathResolver.realHomeDirectory(fileManager: fileManager)
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

    func logURL(for schedule: WakeUpSchedule) -> URL {
        WakeUpLogPathResolver.logURL(
            for: schedule.provider,
            homeDirectory: realHomeDirectory,
            fileManager: fileManager
        )
    }

    /// Checks if a LaunchAgent is installed for the given schedule
    func isInstalled(for schedule: WakeUpSchedule) -> Bool {
        guard let url = plistURL(for: schedule) else { return false }
        guard (try? SecureLaunchAgentPlistStore.containsRegularFile(
            at: url,
            homeDirectory: realHomeDirectory
        )) == true else {
            return false
        }
        return loadedLabels.contains(schedule.launchAgentLabel)
    }

    /// Installs or updates a LaunchAgent for the given schedule
    func install(schedule: WakeUpSchedule) throws {
        guard let url = plistURL(for: schedule) else {
            Logger.wakeup.error("LaunchAgentManager: homeDirectoryNotFound")
            throw WakeUpError.homeDirectoryNotFound
        }

        do {
            try WakeUpWorkingDirectoryResolver.ensureSecureWorkingDirectory(
                homeDirectory: realHomeDirectory,
                fileManager: fileManager
            )
            try SecureLaunchAgentPlistStore.ensureDirectory(
                homeDirectory: realHomeDirectory
            )
        } catch {
            throw WakeUpError.launchAgentWriteFailed(error)
        }

        Logger.wakeup.info("LaunchAgentManager: Installing plist at \(url.path)")
        let wasServiceLoaded = try serviceIsLoaded(schedule)
        updateCachedLoadedState(wasServiceLoaded, for: schedule)
        let previousPlistData: Data?
        do {
            previousPlistData = try SecureLaunchAgentPlistStore.readIfPresent(
                at: url,
                homeDirectory: realHomeDirectory
            )
        } catch {
            throw WakeUpError.launchAgentWriteFailed(error)
        }
        if wasServiceLoaded, previousPlistData == nil {
            // A failed replacement cannot restore a loaded job whose original
            // configuration is already missing. Refuse before publishing or
            // stopping anything so the existing process state stays intact.
            throw WakeUpError.launchAgentWriteFailed(
                MissingLoadedLaunchAgentConfiguration(path: url.path)
            )
        }

        // Generate and stage the new plist before stopping a working service.
        let plistData: Data
        do {
            plistData = try generatePlist(for: schedule)
        } catch let error as WakeUpError {
            throw error
        } catch {
            throw WakeUpError.launchAgentWriteFailed(error)
        }
        Logger.wakeup.info("LaunchAgentManager: Generated plist data (\(plistData.count) bytes)")

        do {
            try WakeUpLogPathResolver.ensureSecureLogDirectory(
                homeDirectory: realHomeDirectory,
                fileManager: fileManager
            )
        } catch {
            Logger.wakeup.error("LaunchAgentManager: Unsafe log directory: \(error.localizedDescription)")
            throw WakeUpError.launchAgentWriteFailed(error)
        }

        // Write plist file
        do {
            try writePrivatePlist(plistData, to: url)
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
                    wasServiceLoaded: wasServiceLoaded,
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
        do {
            try SecureLaunchAgentPlistStore.ensureDirectory(
                homeDirectory: realHomeDirectory
            )
            previousPlistData = try SecureLaunchAgentPlistStore.readIfPresent(
                at: url,
                homeDirectory: realHomeDirectory
            )
        } catch {
            throw WakeUpError.launchAgentWriteFailed(error)
        }

        // Never remove the plist while launchd may still be running the job.
        let wasServiceLoaded = try serviceIsLoaded(schedule)
        updateCachedLoadedState(wasServiceLoaded, for: schedule)
        try unload(schedule: schedule)
        do {
            if try SecureLaunchAgentPlistStore.containsRegularFile(
                at: url,
                homeDirectory: realHomeDirectory
            ) {
                try removeItem(url)
            }
        } catch {
            let removalError = WakeUpError.launchAgentWriteFailed(error)
            do {
                guard let previousPlistData else {
                    throw CocoaError(
                        .fileNoSuchFile,
                        userInfo: [NSFilePathErrorKey: url.path]
                    )
                }
                // Always republish the verified prior bytes. Never bootstrap
                // an unknown regular file that appeared during a failed remove.
                try writePrivatePlist(previousPlistData, to: url)
                try restoreServiceState(
                    wasLoaded: wasServiceLoaded,
                    schedule: schedule
                )
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
        wasServiceLoaded: Bool,
        schedule: WakeUpSchedule
    ) throws {
        if let previousData {
            try writePrivatePlist(previousData, to: url)
            try restoreServiceState(
                wasLoaded: wasServiceLoaded,
                schedule: schedule
            )
        } else {
            if try serviceIsLoaded(schedule) {
                try unload(schedule: schedule)
            }
            if try SecureLaunchAgentPlistStore.containsRegularFile(
                at: url,
                homeDirectory: realHomeDirectory
            ) {
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

    private func restoreServiceState(
        wasLoaded: Bool,
        schedule: WakeUpSchedule
    ) throws {
        if try serviceIsLoaded(schedule) {
            // A failed bootstrap can still leave an unknown configuration
            // loaded. Stop it before restoring the verified prior state.
            try unload(schedule: schedule)
        }
        if wasLoaded {
            try load(schedule: schedule)
        } else {
            guard try !serviceIsLoaded(schedule) else {
                throw LaunchCtlCommandFailure(
                    operation: "rollback verification",
                    terminationStatus: -1,
                    standardError: "service became loaded"
                )
            }
            updateCachedLoadedState(false, for: schedule)
        }
    }

    /// LaunchAgent arguments can contain user-entered values. Keep every
    /// generated or restored plist readable only by its owning account.
    private func writePrivatePlist(_ data: Data, to url: URL) throws {
        try SecureLaunchAgentPlistStore.write(
            data,
            to: url,
            homeDirectory: realHomeDirectory,
            beforeCommit: beforePlistCommit
        )
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
        let fullCommand = try WakeUpCommandBuilder.buildLaunchAgentCommand(for: schedule)

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
            "ProgramArguments": [GeneratedCommandShell.executablePath]
                + GeneratedCommandShell.optionArguments
                + [fullCommand],
            "StartCalendarInterval": calendarIntervals,
            "StandardOutPath": logURL(for: schedule).path,
            "StandardErrorPath": logURL(for: schedule).path,
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
    static func buildLaunchAgentCommand(for schedule: WakeUpSchedule) throws -> String {
        let invocation = try schedule.makeCLIInvocation()
        let prefixedCommand = ShellCommandPathPrefixer.prefixIfNeeded(
            command: invocation.shellCommand
        )
        let guardedCommand = wrapWithTimeout(command: prefixedCommand)
        return buildCommand(for: schedule, command: guardedCommand, marker: nil)
    }

    static func buildTestCommand(
        for schedule: WakeUpSchedule,
        logPath: String? = nil
    ) throws -> String {
        let invocation = try schedule.makeCLIInvocation()
        return buildTestCommand(
            for: schedule,
            invocation: invocation,
            logPath: logPath
        )
    }

    static func buildTestCommand(
        for schedule: WakeUpSchedule,
        invocation: CLICommandInvocation,
        logPath: String? = nil
    ) -> String {
        let baseCommand = buildCommand(
            for: schedule,
            command: invocation.shellCommand,
            marker: "[TEST]"
        )
        return buildLoggedTestCommand(
            command: baseCommand,
            logPath: logPath ?? schedule.logPath
        )
    }

    static func buildLoggedTestCommand(command: String, logPath: String) -> String {
        "set -o pipefail; { \(command); } 2>&1 | tee -a \(shellQuote(logPath))"
    }

    private static func buildCommand(
        for schedule: WakeUpSchedule,
        command: String,
        marker: String?
    ) -> String {
        let markerSuffix = marker.map { " \($0)" } ?? ""
        let workingDirectory = "$HOME/\(LaunchAgentConfig.workingDirectoryPath)"
        let prepareDirectory = "umask 077; working_directory=\"\(workingDirectory)\"; if [ -L \"$working_directory\" ]; then exit 73; fi; mkdir -p \"$working_directory\" && chmod 700 \"$working_directory\" && [ -d \"$working_directory\" ] && [ -O \"$working_directory\" ] && cd \"$working_directory\""
        return "\(prepareDirectory) && echo \"=== $(date)\(markerSuffix) ===\" && \(command)"
    }

    private static func wrapWithTimeout(command: String) -> String {
        let timeout = LaunchAgentConfig.cliTimeoutSeconds
        return "{ \(command) & pid=$!; ( sleep \(timeout); if kill -0 $pid 2>/dev/null; then kill $pid; sleep 2; kill -0 $pid 2>/dev/null && kill -9 $pid; fi ) & watchdog=$!; wait $pid; exit_code=$?; kill -9 $watchdog 2>/dev/null; exit $exit_code; }"
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// Executes CLI commands for manual wake-up testing.
/// Uses ShellExecutor for command execution with timeout support.
final class CLIExecutor {
    private let shellExecutor: ShellExecutor
    private let fileManager: FileManager
    private let homeDirectoryOverride: URL?

    /// Creates a new CLI executor with the specified timeout.
    /// - Parameter timeout: Maximum time to wait for command completion (default: 30 seconds)
    init(
        timeout: TimeInterval = 30,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil,
        shellPath: String = ShellExecutor.defaultShellPath
    ) {
        self.shellExecutor = ShellExecutor(timeout: timeout, shellPath: shellPath)
        self.fileManager = fileManager
        self.homeDirectoryOverride = homeDirectory
    }

    /// Executes a CLI command for the given schedule and returns the output.
    /// Logs execution to the schedule's log file with a [TEST] marker.
    /// - Parameter schedule: The wake-up schedule containing the command to execute
    /// - Returns: The command output as a string
    /// - Throws: `WakeUpError` if execution fails
    func execute(for schedule: WakeUpSchedule) async throws -> String {
        let logDirectory: URL
        do {
            try WakeUpWorkingDirectoryResolver.ensureSecureWorkingDirectory(
                homeDirectory: homeDirectoryOverride,
                fileManager: fileManager
            )
            logDirectory = try WakeUpLogPathResolver.ensureSecureLogDirectory(
                homeDirectory: homeDirectoryOverride,
                fileManager: fileManager
            )
        } catch {
            throw WakeUpError.launchAgentWriteFailed(error)
        }
        let logPath = logDirectory
            .appendingPathComponent(
                LaunchAgentConfig.logFileName(for: schedule.provider)
            )
            .path
        // Build command with logging (same format as LaunchAgent, with [TEST] marker).
        let invocation: CLICommandInvocation
        let command: String
        do {
            invocation = try schedule.makeCLIInvocation()
            command = WakeUpCommandBuilder.buildTestCommand(
                for: schedule,
                invocation: invocation,
                logPath: logPath
            )
        } catch let error as WakeUpError {
            throw error
        } catch {
            throw WakeUpError.invalidArguments(error.localizedDescription)
        }

        do {
            return try await shellExecutor.executeString(command: command)
        } catch let error as ShellExecutorError {
            throw mapShellError(error, executable: invocation.executable)
        }
    }

    /// Maps ShellExecutorError to WakeUpError for domain-specific error messages.
    /// - Parameters:
    ///   - error: The shell execution error
    ///   - executable: The non-secret executable used for error context
    /// - Returns: A WakeUpError with appropriate message
    private func mapShellError(_ error: ShellExecutorError, executable: String) -> WakeUpError {
        switch error {
        case .launchFailed:
            return .cliNotFound(command: executable)
        case .timeout:
            return .timeout
        case .outputLimitExceeded(let maximumBytes):
            return .outputLimitExceeded(maximumBytes: maximumBytes)
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

    init(userDefaults: UserDefaults = AppDefaults.shared) {
        self.userDefaults = userDefaults
    }

    /// Loads all schedules from storage
    func loadSchedules() -> [UsageProvider: WakeUpSchedule] {
        guard let data = userDefaults.data(forKey: key),
              let schedules = try? JSONDecoder().decode([WakeUpSchedule].self, from: data) else {
            return makeDefaultSchedules()
        }

        var recoveredSchedules = makeDefaultSchedules()
        let schedulesByProvider = Dictionary(grouping: schedules, by: \.provider)
        for provider in UsageProvider.allCases {
            guard let savedSchedules = schedulesByProvider[provider],
                  savedSchedules.count == 1,
                  let savedSchedule = savedSchedules.first else {
                // Missing providers stay disabled. Duplicate providers are
                // ambiguous, so never choose an order-dependent configuration.
                continue
            }
            recoveredSchedules[provider] = savedSchedule
        }
        return recoveredSchedules
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
    static let shared: WakeUpScheduler = {
#if DEBUG
        if AppRuntimeEnvironment.isUITesting,
           let containerURL =
            AppRuntimeEnvironment.uiTestingContainerURL {
            let homeDirectory = containerURL.appendingPathComponent(
                "home",
                isDirectory: true
            )
            return WakeUpScheduler(
                launchAgentManager: LaunchAgentManager(
                    homeDirectory: homeDirectory,
                    launchCtlRunner: { _ in
                        LaunchCtlResult(
                            terminationStatus: 0,
                            standardError: ""
                        )
                    }
                ),
                executor: CLIExecutor(
                    timeout: 1,
                    homeDirectory: homeDirectory,
                    shellPath: "/usr/bin/false"
                ),
                store: WakeUpScheduleStore(
                    userDefaults: AppDefaults.shared
                ),
                syncOnInit: false
            )
        }
#endif
        return WakeUpScheduler()
    }()

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
