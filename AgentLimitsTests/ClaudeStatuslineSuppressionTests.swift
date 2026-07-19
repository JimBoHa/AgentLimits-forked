import XCTest

final class ClaudeStatuslineSuppressionTests: XCTestCase {
    func testSuppressedSnapshotIsTreatedAsMissing() throws {
        let fileManager = FileManager.default
        let temporaryRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "ClaudeStatuslineSuppressionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: temporaryRoot) }

        let homeDirectory = temporaryRoot.appendingPathComponent("home", isDirectory: true)
        let snapshotURL = homeDirectory
            .appendingPathComponent(
                "Library/Group Containers/group.com.jimboha.agentlimits.macos"
            )
            .appendingPathComponent("Library/Application Support/AgentLimitsForked")
            .appendingPathComponent("usage_snapshot_claude.json")
        try fileManager.createDirectory(
            at: snapshotURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "{\"primaryWindow\":{\"usedPercent\":87}}".write(
            to: snapshotURL,
            atomically: true,
            encoding: .utf8
        )

        let fakeBinDirectory = temporaryRoot.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(
            at: fakeBinDirectory,
            withIntermediateDirectories: true
        )
        let fakeDefaultsURL = fakeBinDirectory.appendingPathComponent("defaults")
        try Self.fakeDefaultsScript.write(
            to: fakeDefaultsURL,
            atomically: true,
            encoding: .utf8
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: fakeDefaultsURL.path
        )

        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let statuslineScript = repositoryRoot
            .appendingPathComponent("AgentLimits/Scripts/agentlimits_statusline_claude.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [statuslineScript.path, "-en"]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = homeDirectory.path
        environment["PATH"] = "\(fakeBinDirectory.path):\(environment["PATH"] ?? "")"
        process.environment = environment

        let standardOutput = Pipe()
        let standardError = Pipe()
        process.standardOutput = standardOutput
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let output = String(
            data: standardOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let errorOutput = String(
            data: standardError.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertNotEqual(process.terminationStatus, 0)
        XCTAssertTrue(output.isEmpty)
        XCTAssertTrue(errorOutput.contains("Snapshot file not found"))
        XCTAssertFalse(errorOutput.contains("87"))
    }

    private static let fakeDefaultsScript = """
    #!/bin/bash
    if [[ "$*" == *"snapshot_suppressed.usage_snapshot_claude.json"* ]]; then
        echo true
    elif [[ "$*" == *"AppleLanguages"* ]]; then
        echo '("en")'
    else
        echo ''
    fi
    """
}
