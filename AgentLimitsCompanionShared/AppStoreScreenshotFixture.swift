#if DEBUG
import Foundation

/// Fictional, local-only data used to capture deterministic App Store images.
/// This file compiles to no declarations in Release builds.
nonisolated enum AppStoreScreenshotFixture {
    static let launchArgument = "-ui-testing-sample-data"
    static let releaseGuardMarker =
        "agentlimits-app-store-screenshot-fixture-v1"

    static let personalCodexID = UUID(
        uuidString: "A6100000-0000-4000-8000-000000000001"
    )!
    static let personalClaudeID = UUID(
        uuidString: "A6100000-0000-4000-8000-000000000002"
    )!
    static let personalCopilotID = UUID(
        uuidString: "A6100000-0000-4000-8000-000000000003"
    )!
    static let workCopilotID = UUID(
        uuidString: "A6100000-0000-4000-8000-000000000004"
    )!

    static let personalCodexLabel = "Personal Codex"
    static let personalClaudeLabel = "Personal Claude"
    static let personalCopilotLabel = "Personal Copilot"
    static let workCopilotLabel = "Work Copilot"

    static let personalCopilotCredentialMarker =
        "app-store-screenshot-personal-copilot-v1"
    static let workCopilotCredentialMarker =
        "app-store-screenshot-work-copilot-v1"

    static let personalCopilotWorking = 3
    static let personalCopilotWaiting = 2
    static let workCopilotWorking = 6
    static let workCopilotWaiting = 2

    static func makeWatchEnvelope(
        generatedAt: Date
    ) throws -> WatchCompanionEnvelope {
        try WatchCompanionEnvelope(
            generatedAt: generatedAt,
            accounts: [
                try status(
                    id: personalCodexID,
                    provider: .codex,
                    label: personalCodexLabel,
                    availability: .unsupported,
                    generatedAt: generatedAt
                ),
                try status(
                    id: personalClaudeID,
                    provider: .claude,
                    label: personalClaudeLabel,
                    availability: .unsupported,
                    generatedAt: generatedAt
                ),
                try status(
                    id: personalCopilotID,
                    provider: .copilot,
                    label: personalCopilotLabel,
                    availability: .available,
                    working: personalCopilotWorking,
                    waiting: personalCopilotWaiting,
                    generatedAt: generatedAt
                ),
                try status(
                    id: workCopilotID,
                    provider: .copilot,
                    label: workCopilotLabel,
                    availability: .available,
                    working: workCopilotWorking,
                    waiting: workCopilotWaiting,
                    generatedAt: generatedAt
                )
            ]
        )
    }

    private static func status(
        id: UUID,
        provider: WatchCompanionProvider,
        label: String,
        availability: WatchCompanionAvailability,
        working: Int? = nil,
        waiting: Int? = nil,
        generatedAt: Date
    ) throws -> WatchCompanionAccountStatus {
        let open = working.flatMap { working in
            waiting.map { working + $0 }
        }
        return try WatchCompanionAccountStatus(
            id: id,
            provider: provider,
            label: label,
            isEnabled: true,
            availability: availability,
            working: working,
            waiting: waiting,
            open: open,
            observedAt: open == nil ? nil : generatedAt,
            retryAt: nil
        )
    }
}
#endif
