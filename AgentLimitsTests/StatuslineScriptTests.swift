import Foundation
import XCTest

final class StatuslineScriptTests: XCTestCase {
    func testMissingPrimaryWindowRendersUnavailableValue() throws {
        let output = try runStatusline(
            primaryWindow: nil,
            secondaryWindow: window(usedPercent: 42, resetAt: "2026-07-26T00:00:00Z")
        )

        XCTAssertTrue(output.contains("5h: --%"), output)
        XCTAssertTrue(output.contains("1w: 42%"), output)
    }

    func testMissingSecondaryWindowRendersUnavailableValue() throws {
        let output = try runStatusline(
            primaryWindow: window(usedPercent: 17, resetAt: "2026-07-19T07:00:00Z"),
            secondaryWindow: nil
        )

        XCTAssertTrue(output.contains("5h: 17%"), output)
        XCTAssertTrue(output.contains("1w: --%"), output)
    }

    private func runStatusline(
        primaryWindow: [String: Any]?,
        secondaryWindow: [String: Any]?
    ) throws -> String {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("AgentLimitsStatuslineTests-(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporaryHome) }

        let snapshotDirectory = temporaryHome
            .appendingPathComponent(
                "Library/Group Containers/group.com.jimboha.agentlimits.macos"
            )
            .appendingPathComponent("Library/Application Support/AgentLimitsForked")
        try fileManager.createDirectory(
            at: snapshotDirectory,
            withIntermediateDirectories: true
        )

        let snapshot: [String: Any] = [
            "primaryWindow": primaryWindow ?? NSNull(),
            "secondaryWindow": secondaryWindow ?? NSNull(),
            "fetchedAt": "2026-07-19T02:20:00Z",
            "displayMode": "used"
        ]
        try JSONSerialization.data(withJSONObject: snapshot).write(
            to: snapshotDirectory.appendingPathComponent("usage_snapshot_claude.json")
        )

        let mockBin = temporaryHome.appendingPathComponent("bin")
        try fileManager.createDirectory(at: mockBin, withIntermediateDirectories: true)
        let mockDefaults = mockBin.appendingPathComponent("defaults")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: mockDefaults)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: mockDefaults.path
        )

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scriptURL = repositoryRoot
            .appendingPathComponent("AgentLimits/Scripts/agentlimits_statusline_claude.sh")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, "-en"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = temporaryHome.path
        environment["PATH"] = "(mockBin.path):/usr/bin:/bin"
        process.environment = environment

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()

        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: outputData, as: UTF8.self)
        let error = String(decoding: errorData, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, error)
        return stripANSIEscapes(from: output)
    }

    private func window(usedPercent: Int, resetAt: String) -> [String: Any] {
        ["usedPercent": usedPercent, "resetAt": resetAt]
    }

    private func stripANSIEscapes(from string: String) -> String {
        string.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*m",
            with: "",
            options: .regularExpression
        )
    }
}
