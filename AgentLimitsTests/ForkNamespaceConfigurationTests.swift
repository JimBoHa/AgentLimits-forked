import Foundation
import XCTest
@testable import AgentLimits

final class ForkNamespaceConfigurationTests: XCTestCase {
    func testConfiguredAppGroupUsesForkNamespace() {
        XCTAssertEqual(
            AppGroupConfig.resolveGroupIdentifier(
                "group.com.jimboha.agentlimits.macos",
                isRunningTests: false
            ),
            "group.com.jimboha.agentlimits.macos"
        )
        XCTAssertEqual(
            Bundle.main.object(
                forInfoDictionaryKey: AppGroupConfig.infoDictionaryKey
            ) as? String,
            AppGroupConfig.forkGroupIdentifier
        )
    }

    func testInstalledProductNameCannotReplaceUpstreamApp() {
        XCTAssertEqual(
            Bundle.main.bundleIdentifier,
            "com.jimboha.agentlimits.macos"
        )
        XCTAssertEqual(Bundle.main.bundleURL.lastPathComponent, "AgentLimitsForked.app")
        XCTAssertEqual(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName")
                as? String,
            "AgentLimits Forked"
        )
    }

    func testMissingProductionAppGroupFailsClosed() {
        XCTAssertNil(
            AppGroupConfig.resolveGroupIdentifier(nil, isRunningTests: false)
        )
    }

    func testMissingTestAppGroupUsesForkOnlyFallback() {
        XCTAssertEqual(
            AppGroupConfig.resolveGroupIdentifier(nil, isRunningTests: true),
            AppGroupConfig.forkGroupIdentifier
        )
    }

    func testUnexpectedAppGroupFailsClosedEvenDuringTests() {
        XCTAssertNil(
            AppGroupConfig.resolveGroupIdentifier(
                "group.example.untrusted",
                isRunningTests: true
            )
        )
    }

    func testWidgetDeepLinksUseForkScheme() {
        XCTAssertEqual(
            UsageProvider.chatgptCodex.widgetDeepLinkURL.scheme,
            "agentlimits-forked"
        )
        XCTAssertEqual(
            TokenUsageProvider.codex.widgetDeepLinkURL.scheme,
            "agentlimits-forked"
        )
    }

    func testRegisteredDeepLinkSchemeMatchesRuntimeScheme() throws {
        let urlTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
                as? [[String: Any]]
        )
        let schemes = urlTypes.flatMap {
            $0["CFBundleURLSchemes"] as? [String] ?? []
        }

        XCTAssertTrue(schemes.contains(DeepLinkConfig.scheme))
    }

    func testLaunchAgentNamespaceAndPathsAreForkOwned() {
        let schedule = WakeUpSchedule(
            provider: .claudeCode,
            enabledHours: [9],
            isEnabled: true
        )

        XCTAssertEqual(
            schedule.launchAgentLabel,
            "com.jimboha.agentlimits.macos.wakeup-claudeCode"
        )
        XCTAssertEqual(
            LaunchAgentConfig.logDirectoryPath,
            "Library/Logs/AgentLimitsForked"
        )
        XCTAssertEqual(
            LaunchAgentConfig.logFileName(for: .claudeCode),
            "agentlimits-forked-wakeup-claudeCode.log"
        )
    }

    func testCredentialAndUpdaterPoliciesCannotInheritUpstreamTrust() {
        XCTAssertEqual(
            SessionActivityCredentialStore.service,
            "com.jimboha.agentlimits-forked.session-activity.github-agent-tasks"
        )
        XCTAssertFalse(ForkUpdatePolicy.allowsAutomaticUpdates)
    }
}
