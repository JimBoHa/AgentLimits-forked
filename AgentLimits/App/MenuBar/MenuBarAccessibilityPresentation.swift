import Foundation

/// The selected account is retained only to validate session snapshots. Its
/// label and local data path must never be included in accessibility output.
struct MenuBarAccessibilityProviderState {
    let account: ProviderAccount
    let usageSnapshot: UsageSnapshot?
    let sessionSnapshot: SessionActivitySnapshot?
}

/// Builds concise, localized VoiceOver values for image-only menu bar UI.
enum MenuBarAccessibilityPresentation {
    static let statusItemLabel = "AgentLimits"

    static func statusValue(
        states: [MenuBarAccessibilityProviderState],
        displayMode: UsageDisplayMode
    ) -> String {
        guard !states.isEmpty else {
            return "accessibility.menuBar.noProviders".localized()
        }

        return states.map { state in
            let usage = usageValue(
                provider: state.account.provider,
                snapshot: state.usageSnapshot,
                displayMode: displayMode
            )
            var components = [
                state.account.provider.displayName,
                usage,
            ]
            if state.account.provider == .githubCopilot {
                let activity = SessionActivityPresentation.summary(
                    for: state.account,
                    snapshot: state.sessionSnapshot
                )
                components.append(
                    "\("activity.title".localized()): \(activity)"
                )
            }
            return components.joined(separator: ". ")
        }
        .joined(separator: "; ")
    }

    static func dashboardLabel(provider: UsageProvider) -> String {
        provider.displayName
    }

    static func dashboardValue(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        displayMode: UsageDisplayMode
    ) -> String {
        usageValue(
            provider: provider,
            snapshot: snapshot,
            displayMode: displayMode
        )
    }

    static func dashboardMenuItemTitle(
        provider: UsageProvider,
        snapshot: UsageSnapshot,
        displayMode: UsageDisplayMode
    ) -> String {
        let label = dashboardLabel(provider: provider)
        let value = dashboardValue(
            provider: provider,
            snapshot: snapshot,
            displayMode: displayMode
        )
        return "\(label). \(value)"
    }

    private static func usageValue(
        provider: UsageProvider,
        snapshot: UsageSnapshot?,
        displayMode: UsageDisplayMode
    ) -> String {
        guard let snapshot, snapshot.provider == provider else {
            return "status.notFetched".localized()
        }

        var windows: [String] = []
        if snapshot.isSingleMonthlyWindow {
            if let primaryWindow = snapshot.primaryWindow {
                windows.append(
                    windowValue(
                        label: "content.month".localized(),
                        window: primaryWindow,
                        displayMode: displayMode
                    )
                )
            }
        } else {
            if let primaryWindow = snapshot.primaryWindow {
                windows.append(
                    windowValue(
                        label: "content.5hours".localized(),
                        window: primaryWindow,
                        displayMode: displayMode
                    )
                )
            }
            if let secondaryWindow = snapshot.secondaryWindow {
                windows.append(
                    windowValue(
                        label: "content.week".localized(),
                        window: secondaryWindow,
                        displayMode: displayMode
                    )
                )
            }
        }

        guard !windows.isEmpty else {
            return "status.notFetched".localized()
        }
        return "\(displayMode.localizedDisplayName): \(windows.joined(separator: ", "))"
    }

    private static func windowValue(
        label: String,
        window: UsageWindow,
        displayMode: UsageDisplayMode
    ) -> String {
        let percent = displayMode.displayPercent(
            from: window.usedPercent,
            window: window
        )
        return "\(label) \(UsagePercentFormatter.formatPercentText(percent))"
    }
}
