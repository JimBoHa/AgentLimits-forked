import Foundation
import XCTest
@testable import AgentLimits

final class WakeUpCommandBuilderTests: XCTestCase {
    func testLoggedPipelinePreservesCommandFailureStatus() throws {
        let result = try runLoggedCommand("printf 'failed\\n'; exit 23")

        XCTAssertEqual(result.status, 23)
        XCTAssertEqual(result.output, "failed\n")
        XCTAssertEqual(result.log, "failed\n")
    }

    func testLoggedPipelineReturnsSuccessWhenCommandSucceeds() throws {
        let result = try runLoggedCommand("printf 'ok\\n'")

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "ok\n")
        XCTAssertEqual(result.log, "ok\n")
    }

    private func runLoggedCommand(_ command: String) throws -> (
        status: Int32,
        output: String,
        log: String
    ) {
        let fileManager = FileManager.default
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("AgentLimitsWakeUpTests-(UUID().uuidString)")
        try fileManager.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        let logURL = temporaryDirectory.appendingPathComponent("wake-up.log")
        let wrappedCommand = WakeUpCommandBuilder.buildLoggedTestCommand(
            command: command,
            logPath: logURL.path
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", wrappedCommand]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = stdout
        try process.run()
        process.waitUntilExit()

        let output = String(
            decoding: stdout.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        let log = String(
            decoding: try Data(contentsOf: logURL),
            as: UTF8.self
        )
        return (process.terminationStatus, output, log)
    }
}
