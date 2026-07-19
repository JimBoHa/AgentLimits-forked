import Foundation
import XCTest
@testable import AgentLimits

@MainActor
final class CCUsageDataRootTests: XCTestCase {
    func testConcurrentAccountRootsReachOnlyTheirOwnCCUsageChildren() async throws {
        let fixture = try makeFakeCodexShell()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let suiteName = "CCUsageDataRootTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fetcher = CCUsageFetcher(
            settingsStore: CCUsageSettingsStore(userDefaults: defaults),
            shellExecutor: ShellExecutor(
                timeout: 2,
                shellPath: fixture.executable.path
            )
        )
        let inheritedRoot = ProcessInfo.processInfo.environment["CODEX_HOME"]

        async let personal = tokenCount(
            fetcher: fetcher,
            root: "/profiles/personal"
        )
        async let work = tokenCount(
            fetcher: fetcher,
            root: "/profiles/work"
        )

        let tokenCounts = try await (personal, work)
        XCTAssertEqual(tokenCounts.0, 11)
        XCTAssertEqual(tokenCounts.1, 22)
        XCTAssertEqual(
            ProcessInfo.processInfo.environment["CODEX_HOME"],
            inheritedRoot
        )
    }

    func testInvalidRootFailsBeforeCCUsageChildLaunch() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLimits-ccusage-marker-\(UUID().uuidString)")
        let fixture = try makeFakeCodexShell(marker: marker)
        defer {
            try? FileManager.default.removeItem(at: fixture.directory)
            try? FileManager.default.removeItem(at: marker)
        }
        let fetcher = CCUsageFetcher(
            shellExecutor: ShellExecutor(
                timeout: 2,
                shellPath: fixture.executable.path
            )
        )

        do {
            _ = try await fetcher.fetchSnapshot(
                for: .codex,
                cliDataRoot: "relative/profile"
            )
            XCTFail("Expected invalid root")
        } catch CCUsageFetcherError.invalidArguments(let message) {
            XCTAssertTrue(message.contains("absolute path"))
        } catch {
            XCTFail("Expected invalid arguments, got \(error)")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    private func makeFakeCodexShell(
        marker: URL? = nil
    ) throws -> (directory: URL, executable: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentLimits Fake Shell \(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let executable = directory.appendingPathComponent("ccusage-shell")
        let markerCommand = marker.map {
            "/usr/bin/touch \(shellQuote($0.path))"
        } ?? ":"
        let script = """
        #!/bin/sh
        \(markerCommand)
        case "${CODEX_HOME-}" in
          /profiles/personal) tokens=11 ;;
          /profiles/work) tokens=22 ;;
          *) tokens=999 ;;
        esac
        /bin/sleep 0.05
        today=$(/bin/date +%Y-%m-%d)
        /usr/bin/printf '{"daily":[{"date":"%s","totalTokens":%s,"costUSD":1}],"totals":{"totalTokens":%s,"costUSD":1}}\n' "$today" "$tokens" "$tokens"
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: executable.path
        )
        return (directory, executable)
    }

    private func tokenCount(
        fetcher: CCUsageFetcher,
        root: String
    ) async throws -> Int {
        let snapshot = try await fetcher.fetchSnapshot(
            for: .codex,
            cliDataRoot: root
        )
        return snapshot.today.totalTokens
    }

    private func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}
