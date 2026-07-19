import Foundation
import Darwin
import XCTest
@testable import AgentLimits

final class CLIInvocationSecurityTests: XCTestCase {
    func testArgumentParserSupportsQuotedAndEscapedLiteralValues() throws {
        let arguments = try CLIArgumentParser.parse(
            "--model \"work profile\" --label='Jim O' empty=\"\" escaped\\ value"
        )

        XCTAssertEqual(arguments, [
            "--model",
            "work profile",
            "--label=Jim O",
            "empty=",
            "escaped value"
        ])
    }

    func testArgumentParserPreservesNonspecialBackslashesInsideDoubleQuotes() throws {
        let arguments = try CLIArgumentParser.parse(
            #"--pattern "\d+" --literal "a\qb" --special "\$\`\"\\""#
        )

        XCTAssertEqual(arguments, ["--pattern", #"\d+"#, "--literal", #"a\qb"#, "--special", "$`\"\\"])
    }

    func testArgumentParserRejectsIncompleteOrNullInput() {
        XCTAssertThrowsError(try CLIArgumentParser.parse("'unfinished")) { error in
            XCTAssertEqual(error as? CLIArgumentParserError, .unterminatedSingleQuote)
        }
        XCTAssertThrowsError(try CLIArgumentParser.parse("\"unfinished")) { error in
            XCTAssertEqual(error as? CLIArgumentParserError, .unterminatedDoubleQuote)
        }
        XCTAssertThrowsError(try CLIArgumentParser.parse("unfinished\\")) { error in
            XCTAssertEqual(error as? CLIArgumentParserError, .trailingEscape)
        }
        XCTAssertThrowsError(try CLIArgumentParser.parse("bad\0value")) { error in
            XCTAssertEqual(error as? CLIArgumentParserError, .nullByte)
        }
    }

    func testShellRenderingDoesNotEvaluateArgumentMetacharacters() async throws {
        let sentinel = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLimits-CLI-injection-\(UUID().uuidString)")
        defer { _ = unlink(sentinel.path) }
        let payload = "safe; /usr/bin/touch \(sentinel.path); $(/usr/bin/id)"
        let invocation = CLICommandInvocation(
            executable: "/usr/bin/printf",
            arguments: ["%s", payload]
        )

        let output = try await ShellExecutor(
            timeout: 2,
            shellPath: "/bin/zsh"
        ).executeString(command: invocation.shellCommand)

        XCTAssertEqual(output, payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sentinel.path))
    }

    func testCCUsageBuildsStructuredArgumentsInExpectedOrder() throws {
        let settings = CCUsageSettings(
            provider: .codex,
            isEnabled: true,
            additionalArgs: "--timezone \"America/Los Angeles\" ';' $(touch)"
        )

        let invocation = try settings.makeCLIInvocation(startDate: "20260701")

        XCTAssertEqual(invocation.arguments, [
            "codex",
            "daily",
            "--timezone",
            "America/Los Angeles",
            ";",
            "$(touch)",
            "--since",
            "20260701",
            "-j"
        ])
        XCTAssertTrue(invocation.shellCommand.contains("';'"))
        XCTAssertTrue(invocation.shellCommand.contains("'$(touch)'"))
    }

    func testWakeUpBuildsStructuredArgumentsWithoutCommandSeparators() throws {
        let schedule = WakeUpSchedule(
            provider: .claudeCode,
            enabledHours: [9],
            isEnabled: true,
            additionalArgs: "--model \"work profile\" ; /usr/bin/touch /tmp/not-run"
        )

        let invocation = try schedule.makeCLIInvocation()
        let command = try WakeUpCommandBuilder.buildLaunchAgentCommand(for: schedule)

        XCTAssertEqual(invocation.arguments, [
            "-p",
            "hello",
            "--model",
            "work profile",
            ";",
            "/usr/bin/touch",
            "/tmp/not-run"
        ])
        XCTAssertTrue(command.contains("';'"))
        XCTAssertFalse(command.contains("; /usr/bin/touch /tmp/not-run"))
    }

    func testInvalidExecutableOverrideFailsClosed() throws {
        let suiteName = "CLIInvocationSecurityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            "/tmp/missing; /usr/bin/touch /tmp/not-run",
            forKey: CLICommandPathKeys.ccusage
        )

        XCTAssertThrowsError(try CLICommandPathResolver.resolveExecutable(
            for: .ccusage,
            defaultName: "ccusage",
            userDefaults: defaults
        )) { error in
            XCTAssertEqual(
                error as? CLICommandPathResolverError,
                .invalidConfiguredPath(command: .ccusage)
            )
        }
    }

    func testUnsetExecutableOverrideUsesDefaultCommandName() throws {
        let suiteName = "CLIInvocationSecurityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let resolved = try CLICommandPathResolver.resolveExecutable(
            for: .ccusage,
            defaultName: "ccusage",
            userDefaults: defaults
        )

        XCTAssertEqual(resolved, "ccusage")
    }

    func testValidExecutableOverrideWithSpacesIsPreservedAndQuoted() throws {
        let suiteName = "CLIInvocationSecurityTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLimits CLI \(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("ccusage tool")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )
        defaults.set(executable.path, forKey: CLICommandPathKeys.ccusage)

        let resolved = try CLICommandPathResolver.resolveExecutable(
            for: .ccusage,
            defaultName: "ccusage",
            userDefaults: defaults
        )
        let command = CLICommandInvocation(
            executable: resolved,
            arguments: ["daily"]
        ).shellCommand

        XCTAssertEqual(resolved, executable.path)
        XCTAssertTrue(command.hasPrefix("'\(executable.path)' "))
    }

    func testWakeUpArgumentsDraftAllowsQuotedInputBeforeApplying() {
        var draft = WakeUpArgumentsDraft(committedValue: "")

        draft.update("--model=\"work")
        XCTAssertNil(draft.validatedValue())
        XCTAssertNotNil(draft.validationMessage)

        draft.update("--model=\"work profile\"")
        XCTAssertEqual(draft.validatedValue(), "--model=\"work profile\"")
        XCTAssertNil(draft.validationMessage)
    }

    @MainActor
    func testWakeUpLaunchFailureDoesNotExposeAdditionalArguments() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLimitsWakeUpLaunchFailure-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let executor = CLIExecutor(
            timeout: 1,
            homeDirectory: home,
            shellPath: "/definitely/missing/agentlimits-shell"
        )
        let schedule = WakeUpSchedule(
            provider: .claudeCode,
            enabledHours: [9],
            isEnabled: true,
            additionalArgs: "--api-key sensitive-value"
        )

        do {
            _ = try await executor.execute(for: schedule)
            XCTFail("Expected the missing shell to fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("claude"))
            XCTAssertFalse(error.localizedDescription.contains("sensitive-value"))
            XCTAssertFalse(error.localizedDescription.contains("--api-key"))
        }
    }
}
