import AppKit
import Foundation

final class MenuBarDashboardMenuItem: NSMenuItem {
    override func accessibilityPerformPress() -> Bool {
        performConfiguredAction()
    }

    func performConfiguredAction() -> Bool {
        guard isEnabled, let action else { return false }
        return NSApplication.shared.sendAction(
            action,
            to: target,
            from: self
        )
    }
}

enum MenuBarDashboardActivation {
    static func configure(
        _ item: NSMenuItem,
        provider: UsageProvider,
        target: AnyObject,
        action: Selector
    ) {
        item.representedObject = provider
        item.target = target
        item.action = action
        item.isEnabled = true
    }

    static func provider(from item: NSMenuItem) -> UsageProvider? {
        item.representedObject as? UsageProvider
    }
}

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
        displayMode: UsageDisplayMode,
        now: Date = Date()
    ) -> String {
        var components = [usageValue(
            provider: provider,
            snapshot: snapshot,
            displayMode: displayMode
        )]
        if let timing = dashboardTimingValue(snapshot: snapshot, now: now) {
            components.append(timing)
        }
        return components.joined(separator: ". ")
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

    private static func dashboardTimingValue(
        snapshot: UsageSnapshot,
        now: Date
    ) -> String? {
        if snapshot.isSingleMonthlyWindow {
            guard let resetAt = snapshot.primaryWindow?.resetAt else {
                return nil
            }
            return resetDescription(
                windowLabel: "content.month".localized(),
                resetAt: resetAt,
                now: now
            )
        }

        var components: [String] = []
        if let resetAt = snapshot.primaryWindow?.resetAt {
            components.append(resetDescription(
                windowLabel: "content.5hours".localized(),
                resetAt: resetAt,
                now: now
            ))
        }
        if let resetAt = snapshot.secondaryWindow?.resetAt {
            components.append(resetDescription(
                windowLabel: "content.week".localized(),
                resetAt: resetAt,
                now: now
            ))
        }
        return components.isEmpty ? nil : components.joined(separator: ", ")
    }

    private static func resetDescription(
        windowLabel: String,
        resetAt: Date,
        now: Date
    ) -> String {
        "\(windowLabel) \("content.reset".localized()) \(resetText(resetAt, now: now))"
    }

    private static func resetText(_ resetAt: Date, now: Date) -> String {
        let remaining = resetAt.timeIntervalSince(now)
        if remaining <= 60 {
            return "menu.dashboard.soon".localized()
        }
        if remaining >= 86_400 {
            return String(
                format: "menu.dashboard.resetDaysLater".localized(),
                remaining / 86_400
            )
        }
        if remaining >= 3_600 {
            return String(
                format: "menu.dashboard.resetHoursLater".localized(),
                remaining / 3_600
            )
        }
        return String(
            format: "menu.dashboard.resetMinutesLater".localized(),
            max(1, Int(remaining) / 60)
        )
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
