import Darwin
import XCTest
@testable import AgentLimits

final class ShellExecutorTests: XCTestCase {
    private let shellPath = "/bin/zsh"

    func testProductionWrapperInterpreterIsFixedZshWithoutStartupFiles() async throws {
        XCTAssertEqual(ShellExecutor.defaultShellPath, "/bin/zsh")
        XCTAssertEqual(GeneratedCommandShell.optionArguments, ["-f", "-c"])

        let output = try await ShellExecutor(timeout: 1).executeString(
            command: "[[ -n $ZSH_VERSION ]] && print -r -- fixed-zsh"
        )

        XCTAssertEqual(output, "fixed-zsh\n")
    }

    func testChildEnvironmentOverrideDoesNotMutateParent() async throws {
        let name = "AGENTLIMITS_CHILD_"
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        XCTAssertNil(ProcessInfo.processInfo.environment[name])

        let output = try await makeExecutor(timeout: 1).executeString(
            command: "print -r -- \"$\(name)\"",
            environment: ShellExecutionEnvironment(
                overrides: [name: "child-only"]
            )
        )

        XCTAssertEqual(output, "child-only\n")
        XCTAssertNil(ProcessInfo.processInfo.environment[name])
    }

    func testChildEnvironmentCanExplicitlyUnsetInheritedValue() async throws {
        let variableName = "AGENTLIMITS_INHERITED_ONLY"
        let executor = ShellExecutor(
            timeout: 1,
            inheritedEnvironment: [variableName: "parent"]
        )

        let output = try await executor.executeString(
            command: "if [[ -v \(variableName) ]]; then print inherited; else print unset; fi",
            environment: ShellExecutionEnvironment(unsets: [variableName])
        )

        XCTAssertEqual(output, "unset\n")
        XCTAssertNil(ProcessInfo.processInfo.environment[variableName])
    }

    func testConcurrentChildEnvironmentOverridesStayIsolated() async throws {
        let executor = makeExecutor(timeout: 2)
        let name = "AGENTLIMITS_CONCURRENT_ROOT"
        let command = "/bin/sleep 0.05; print -r -- \"$\(name)\""

        async let personal = executor.executeString(
            command: command,
            environment: ShellExecutionEnvironment(
                overrides: [name: "/profiles/personal"]
            )
        )
        async let work = executor.executeString(
            command: command,
            environment: ShellExecutionEnvironment(
                overrides: [name: "/profiles/work"]
            )
        )

        let outputs = try await (personal, work)
        XCTAssertEqual(outputs.0, "/profiles/personal\n")
        XCTAssertEqual(outputs.1, "/profiles/work\n")
        XCTAssertNil(ProcessInfo.processInfo.environment[name])
    }

    func testInvalidChildEnvironmentFailsBeforeLaunch() async throws {
        for invalidName in ["BAD=NAME", "BAD NAME", "9BAD", "BAD-NAME", ""] {
            do {
                _ = try await makeExecutor(timeout: 1).executeString(
                    command: "true",
                    environment: ShellExecutionEnvironment(
                        overrides: [invalidName: "value"]
                    )
                )
                XCTFail("Expected invalid environment failure")
            } catch let error as ShellExecutionEnvironmentError {
                XCTAssertEqual(error, .invalidVariableName)
            } catch {
                XCTFail("Expected invalid environment failure, got \(error)")
            }
        }
    }

    func testDrainsLargeConcurrentStandardOutputAndError() async throws {
        let byteCount = 2_500_000
        let executor = makeExecutor(timeout: 5)
        let command = """
        ( /usr/bin/yes O | /usr/bin/head -c \(byteCount) ) &
        ( /usr/bin/yes E | /usr/bin/head -c \(byteCount) >&2 ) &
        wait
        """

        let result = try await executor.executeWithResult(command: command)

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdout.count, byteCount)
        XCTAssertEqual(result.stderr.count, byteCount)
    }

    func testTimeoutEscalatesPastIgnoredTermSignal() async throws {
        let timeout: TimeInterval = 0.15
        let grace: TimeInterval = 0.1
        let executor = makeExecutor(timeout: timeout, grace: grace)
        let startedAt = ProcessInfo.processInfo.systemUptime

        do {
            _ = try await executor.executeString(
                command: "trap '' TERM; while :; do :; done"
            )
            XCTFail("Expected timeout")
        } catch ShellExecutorError.timeout {
            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            XCTAssertGreaterThanOrEqual(elapsed, timeout)
            XCTAssertLessThan(elapsed, 2)
        } catch {
            XCTFail("Expected timeout, got \(error)")
        }
    }

    func testTimeoutKillsIgnoringDescendant() async throws {
        let pidFile = temporaryPIDFile()
        defer { _ = Darwin.unlink(pidFile.path) }

        let childScript = """
        trap '' TERM
        echo $$ > \(shellQuote(pidFile.path))
        while :; do /bin/sleep 1; done
        """
        let command = "/bin/sh -c \(shellQuote(childScript)) & wait"
        let executor = makeExecutor(timeout: 0.3, grace: 0.1)

        do {
            _ = try await executor.executeString(command: command)
            XCTFail("Expected timeout")
        } catch ShellExecutorError.timeout {
            // Expected.
        } catch {
            XCTFail("Expected timeout, got \(error)")
        }

        let childPID = try readPID(from: pidFile)
        let descendantIsGone = await waitUntilProcessIsGone(childPID)
        XCTAssertTrue(
            descendantIsGone,
            "Descendant \(childPID) survived timeout cleanup"
        )
    }

    func testTimeoutKillsIgnoringDescendantWithClosedStreams() async throws {
        let pidFile = temporaryPIDFile()
        defer { _ = Darwin.unlink(pidFile.path) }

        let childScript = """
        trap '' TERM
        echo $$ > \(shellQuote(pidFile.path))
        exec </dev/null >/dev/null 2>&1
        while :; do /bin/sleep 1; done
        """
        let command = "/bin/sh -c \(shellQuote(childScript)) & wait"
        let executor = makeExecutor(timeout: 0.3, grace: 0.1)

        do {
            _ = try await executor.executeString(command: command)
            XCTFail("Expected timeout")
        } catch ShellExecutorError.timeout {
            // Expected.
        } catch {
            XCTFail("Expected timeout, got \(error)")
        }

        let childPID = try readPID(from: pidFile)
        let descendantIsGone = await waitUntilProcessIsGone(childPID)
        XCTAssertTrue(
            descendantIsGone,
            "Closed-stream descendant \(childPID) survived timeout cleanup"
        )
    }

    func testCancellationKillsProcessAndThrowsCancellationError() async throws {
        let pidFile = temporaryPIDFile()
        defer { _ = Darwin.unlink(pidFile.path) }

        let executor = makeExecutor(timeout: 10, grace: 0.05)
        let task = Task {
            try await executor.executeString(
                command: "trap '' TERM; echo $$ > \(shellQuote(pidFile.path)); while :; do :; done"
            )
        }

        let processID = await waitForPID(at: pidFile)
        XCTAssertNotNil(processID, "Subprocess did not publish its PID")
        guard let processID else {
            task.cancel()
            _ = try? await task.value
            return
        }

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let processIsGone = await waitUntilProcessIsGone(processID)
        XCTAssertTrue(
            processIsGone,
            "Process \(processID) survived cancellation cleanup"
        )
        assertChildWasReaped(processID)
    }

    func testOutputLimitTerminatesProcessWithSpecificError() async throws {
        let pidFile = temporaryPIDFile()
        defer { _ = Darwin.unlink(pidFile.path) }

        let maximumOutputBytes = 64 * 1024
        let executor = makeExecutor(
            timeout: 5,
            grace: 0.05,
            maximumOutputBytes: maximumOutputBytes
        )
        let task = Task {
            try await executor.executeString(
                command: "trap '' TERM; echo $$ > \(shellQuote(pidFile.path)); while :; do printf 0123456789abcdef; done"
            )
        }

        let processID = await waitForPID(at: pidFile)
        XCTAssertNotNil(processID, "Subprocess did not publish its PID")
        guard let processID else {
            task.cancel()
            _ = try? await task.value
            return
        }

        do {
            _ = try await task.value
            XCTFail("Expected output limit failure")
        } catch ShellExecutorError.outputLimitExceeded(let actualLimit) {
            XCTAssertEqual(actualLimit, maximumOutputBytes)
        } catch {
            XCTFail("Expected output limit failure, got \(error)")
        }

        let processIsGone = await waitUntilProcessIsGone(processID)
        XCTAssertTrue(processIsGone, "Process \(processID) survived output cleanup")
        assertChildWasReaped(processID)
    }

    func testAllowsOutputExactlyAtLimit() async throws {
        let executor = makeExecutor(timeout: 1, maximumOutputBytes: 4)

        let result = try await executor.executeWithResult(command: "printf 1234")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString, "1234")
    }

    func testRejectsFiniteOutputPastLimit() async throws {
        let executor = makeExecutor(timeout: 1, maximumOutputBytes: 4)

        do {
            _ = try await executor.executeWithResult(command: "printf 12345")
            XCTFail("Expected output limit failure")
        } catch ShellExecutorError.outputLimitExceeded(let actualLimit) {
            XCTAssertEqual(actualLimit, 4)
        } catch {
            XCTFail("Expected output limit failure, got \(error)")
        }
    }

    func testRejectsLargeFiniteOutputPastLimit() async throws {
        let maximumOutputBytes = 64 * 1024
        let executor = makeExecutor(
            timeout: 2,
            maximumOutputBytes: maximumOutputBytes
        )

        do {
            _ = try await executor.executeWithResult(
                command: "/usr/bin/yes X | /usr/bin/head -c 1100000"
            )
            XCTFail("Expected output limit failure")
        } catch ShellExecutorError.outputLimitExceeded(let actualLimit) {
            XCTAssertEqual(actualLimit, maximumOutputBytes)
        } catch {
            XCTFail("Expected output limit failure, got \(error)")
        }
    }

    func testDoesNotInheritUnrelatedDescriptor() async throws {
        let sourceDescriptor = Darwin.open("/dev/null", O_RDONLY)
        XCTAssertGreaterThanOrEqual(sourceDescriptor, 0)
        guard sourceDescriptor >= 0 else { return }
        defer { _ = Darwin.close(sourceDescriptor) }

        let unrelatedDescriptor = fcntl(sourceDescriptor, F_DUPFD, 200)
        XCTAssertGreaterThanOrEqual(unrelatedDescriptor, 200)
        guard unrelatedDescriptor >= 200 else { return }
        defer { _ = Darwin.close(unrelatedDescriptor) }

        let executor = makeExecutor(timeout: 1)
        let result = try await executor.executeWithResult(
            command: "test ! -e /dev/fd/\(unrelatedDescriptor)"
        )

        XCTAssertEqual(result.exitCode, 0, "Child inherited descriptor \(unrelatedDescriptor)")
    }

    func testSignalExitIsFailureRatherThanTimeout() async throws {
        let executor = makeExecutor(timeout: 2)

        let result = try await executor.executeWithResult(command: "kill -KILL $$")

        XCTAssertEqual(result.exitCode, 128 + SIGKILL)
        XCTAssertFalse(result.isSuccess)
    }

    func testFastCommandCompletesNormally() async throws {
        let executor = makeExecutor(timeout: 1)

        let result = try await executor.executeWithResult(command: "printf fast")

        XCTAssertEqual(result.exitCode, 0)
        XCTAssertEqual(result.stdoutString, "fast")
        XCTAssertEqual(result.stderr, Data())
    }

    func testInvalidShellReportsLaunchFailure() async throws {
        let executor = ShellExecutor(
            timeout: 1,
            shellPath: "/definitely/missing/agentlimits-shell",
            terminationGracePeriod: 0.05
        )

        do {
            _ = try await executor.executeString(command: "true")
            XCTFail("Expected launch failure")
        } catch ShellExecutorError.launchFailed(let underlying) {
            XCTAssertEqual((underlying as NSError).code, Int(ENOENT))
        } catch {
            XCTFail("Expected launch failure, got \(error)")
        }
    }

    private func makeExecutor(
        timeout: TimeInterval,
        grace: TimeInterval = 0.05,
        maximumOutputBytes: Int = ShellExecutor.defaultMaximumOutputBytes
    ) -> ShellExecutor {
        ShellExecutor(
            timeout: timeout,
            shellPath: shellPath,
            terminationGracePeriod: grace,
            maximumOutputBytes: maximumOutputBytes
        )
    }

    private func temporaryPIDFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLimits-ShellExecutor-\(UUID().uuidString).pid")
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }

    private func readPID(from url: URL) throws -> pid_t {
        let contents = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(contents))
    }

    private func waitForPID(at url: URL) async -> pid_t? {
        for _ in 0..<200 {
            if let contents = try? String(contentsOf: url, encoding: .utf8),
               let processID = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return processID
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

    private func waitUntilProcessIsGone(_ processID: pid_t) async -> Bool {
        for _ in 0..<200 {
            if !processExists(processID) {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return !processExists(processID)
    }

    private func processExists(_ processID: pid_t) -> Bool {
        if Darwin.kill(processID, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    private func assertChildWasReaped(
        _ processID: pid_t,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var status: Int32 = 0
        errno = 0
        let result = waitpid(processID, &status, WNOHANG)
        XCTAssertEqual(result, -1, file: file, line: line)
        XCTAssertEqual(errno, ECHILD, file: file, line: line)
    }
}
