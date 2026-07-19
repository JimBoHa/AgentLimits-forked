// MARK: - ThresholdNotificationManager.swift
// Manages threshold notifications for usage limits.
// Checks usage against thresholds and sends system notifications.

import Combine
import Foundation
import OSLog
import UserNotifications

@MainActor
protocol ThresholdNotificationCenterClient {
    func isAuthorized() async -> Bool
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
final class SystemThresholdNotificationCenterClient: ThresholdNotificationCenterClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

// MARK: - Notification Identifiers

/// Identifiers for threshold notifications
private enum NotificationIdentifier {
    static func makeId(
        provider: UsageProvider,
        windowKind: UsageWindowKind,
        level: UsageThresholdLevel,
        submissionID: UUID
    ) -> String {
        "threshold-\(provider.rawValue)-\(windowKind.rawValue)-\(level.rawValue)-\(submissionID.uuidString)"
    }
}

// MARK: - Threshold Notification Manager

/// Manages usage threshold notifications
@MainActor
final class ThresholdNotificationManager: ObservableObject {
    static let shared = ThresholdNotificationManager()

    @Published private(set) var settings: [UsageProvider: ProviderThresholdSettings]
    @Published private(set) var isNotificationAuthorized: Bool = false

    private let store: ThresholdNotificationStore
    private let notificationCenter: any ThresholdNotificationCenterClient
    private let makeSubmissionID: () -> UUID

    init(
        store: ThresholdNotificationStore? = nil,
        notificationCenter: (any ThresholdNotificationCenterClient)? = nil,
        makeSubmissionID: @escaping () -> UUID = UUID.init
    ) {
        let useStore = store ?? ThresholdNotificationStore()
        self.store = useStore
        self.notificationCenter = notificationCenter ?? SystemThresholdNotificationCenterClient()
        self.makeSubmissionID = makeSubmissionID
        let loadedSettings = useStore.loadSettings()
        let sanitizedSettings = Self.sanitizeSettings(loadedSettings)
        if sanitizedSettings != loadedSettings {
            useStore.saveSettings(sanitizedSettings)
        }
        self.settings = sanitizedSettings
        syncUsageStatusThresholds(from: sanitizedSettings)

        Task {
            await checkAuthorizationStatus()
        }
    }

    // MARK: - Authorization

    /// Checks current notification authorization status
    func checkAuthorizationStatus() async {
        isNotificationAuthorized = await notificationCenter.isAuthorized()
    }

    /// Requests notification authorization from user
    @discardableResult
    func requestNotificationAuthorization() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            isNotificationAuthorized = granted
            return granted
        } catch {
            Logger.notification.error("ThresholdNotificationManager: Authorization request failed: \(error.localizedDescription)")
            isNotificationAuthorized = false
            return false
        }
    }

    // MARK: - Settings Management

    /// Updates settings for a provider
    /// Resets lastNotifiedResetAt if threshold is changed (to allow re-notification)
    func updateSettings(_ providerSettings: ProviderThresholdSettings) {
        var updatedSettings = providerSettings
        updatedSettings.primaryWindow = Self.normalizeWindowSettings(updatedSettings.primaryWindow)
        updatedSettings.secondaryWindow = Self.normalizeWindowSettings(updatedSettings.secondaryWindow)

        // Check if threshold changed and reset lastNotifiedResetAt if so
        if let oldSettings = settings[providerSettings.provider] {
            updatedSettings.primaryWindow.warning = makeResetLevelSettings(
                oldLevel: oldSettings.primaryWindow.warning,
                newLevel: updatedSettings.primaryWindow.warning
            )
            updatedSettings.primaryWindow.danger = makeResetLevelSettings(
                oldLevel: oldSettings.primaryWindow.danger,
                newLevel: updatedSettings.primaryWindow.danger
            )
            updatedSettings.secondaryWindow.warning = makeResetLevelSettings(
                oldLevel: oldSettings.secondaryWindow.warning,
                newLevel: updatedSettings.secondaryWindow.warning
            )
            updatedSettings.secondaryWindow.danger = makeResetLevelSettings(
                oldLevel: oldSettings.secondaryWindow.danger,
                newLevel: updatedSettings.secondaryWindow.danger
            )
        }

        settings[providerSettings.provider] = updatedSettings
        store.saveSettings(settings)
        syncUsageStatusThresholds(from: settings)
    }

    /// Returns settings for a provider
    func getSettings(for provider: UsageProvider) -> ProviderThresholdSettings {
        settings[provider] ?? .defaultSettings(for: provider)
    }

    /// Resets settings for a provider to defaults
    func resetSettings(for provider: UsageProvider) {
        let defaultSettings = ProviderThresholdSettings.defaultSettings(for: provider)
        settings[provider] = defaultSettings
        store.saveSettings(settings)
        syncUsageStatusThresholds(from: settings)
    }

    // MARK: - Threshold Checking

    /// Checks thresholds for a snapshot and sends notifications if needed
    func checkThresholdsIfNeeded(
        for snapshot: UsageSnapshot,
        isCurrent: @MainActor () -> Bool = { true }
    ) async {
        guard isNotificationAuthorized, isCurrent() else { return }

        let providerSettings = getSettings(for: snapshot.provider)

        // Check primary window (5h)
        if let window = snapshot.primaryWindow {
            await checkWindowThreshold(
                provider: snapshot.provider,
                window: window,
                level: .warning,
                levelSettings: providerSettings.primaryWindow.warning,
                isCurrent: isCurrent
            )
            guard isCurrent() else { return }
            await checkWindowThreshold(
                provider: snapshot.provider,
                window: window,
                level: .danger,
                levelSettings: providerSettings.primaryWindow.danger,
                isCurrent: isCurrent
            )
        }

        // Check secondary window (weekly)
        if let window = snapshot.secondaryWindow, isCurrent() {
            await checkWindowThreshold(
                provider: snapshot.provider,
                window: window,
                level: .warning,
                levelSettings: providerSettings.secondaryWindow.warning,
                isCurrent: isCurrent
            )
            guard isCurrent() else { return }
            await checkWindowThreshold(
                provider: snapshot.provider,
                window: window,
                level: .danger,
                levelSettings: providerSettings.secondaryWindow.danger,
                isCurrent: isCurrent
            )
        }
    }

    /// Checks a single window against its threshold
    private func checkWindowThreshold(
        provider: UsageProvider,
        window: UsageWindow,
        level: UsageThresholdLevel,
        levelSettings: ThresholdLevelSettings,
        isCurrent: @MainActor () -> Bool
    ) async {
        guard isCurrent() else { return }
        // Skip if disabled
        guard levelSettings.isEnabled else { return }

        // Skip if below threshold
        let usedPercent = Int(window.usedPercent)
        guard usedPercent >= levelSettings.thresholdPercent else { return }

        if shouldSkipDuplicateNotification(
            provider: provider,
            window: window,
            level: level,
            lastNotifiedResetAt: levelSettings.lastNotifiedResetAt
        ) {
            return
        }

        // Send notification
        guard isCurrent() else { return }
        let notificationIdentifier = NotificationIdentifier.makeId(
            provider: provider,
            windowKind: window.kind,
            level: level,
            submissionID: makeSubmissionID()
        )
        let didSend = await sendNotification(
            provider: provider,
            windowKind: window.kind,
            level: level,
            usedPercent: usedPercent,
            identifier: notificationIdentifier
        )
        guard didSend else { return }
        guard isCurrent() else {
            // If Clear Data invalidated this generation while add() suspended,
            // remove any notification the stale operation just submitted.
            notificationCenter.removePendingNotificationRequests(
                withIdentifiers: [notificationIdentifier]
            )
            notificationCenter.removeDeliveredNotifications(
                withIdentifiers: [notificationIdentifier]
            )
            return
        }

        // Update lastNotifiedResetAt to prevent duplicates
        if let resetAt = window.resetAt {
            store.updateLastNotifiedResetAt(
                for: provider,
                windowKind: window.kind,
                level: level,
                resetAt: resetAt
            )
            // Reload settings to update published property
            settings = store.loadSettings()
        }
    }

    private func shouldSkipDuplicateNotification(
        provider: UsageProvider,
        window: UsageWindow,
        level: UsageThresholdLevel,
        lastNotifiedResetAt: Date?
    ) -> Bool {
        // Allow 10 seconds tolerance to handle API returning slightly different timestamps
        if let lastNotified = lastNotifiedResetAt,
           let resetAt = window.resetAt {
            let lastNotifiedSeconds = Int(lastNotified.timeIntervalSince1970)
            let resetAtSeconds = Int(resetAt.timeIntervalSince1970)
            let diff = abs(lastNotifiedSeconds - resetAtSeconds)
            Logger.notification.debug("ThresholdNotificationManager: \(provider.displayName) \(window.kind.rawValue) \(level.rawValue) lastNotified=\(lastNotifiedSeconds) resetAt=\(resetAtSeconds) diff=\(diff)")
            if diff <= 10 {
                Logger.notification.debug("ThresholdNotificationManager: Skipping duplicate notification (within 10s tolerance)")
                return true
            }
            return false
        }

        Logger.notification.debug("ThresholdNotificationManager: \(provider.displayName) \(window.kind.rawValue) \(level.rawValue) lastNotified=\(lastNotifiedResetAt?.description ?? "nil") resetAt=\(window.resetAt?.description ?? "nil")")
        return false
    }

    /// Sends a notification for threshold exceeded
    private func sendNotification(
        provider: UsageProvider,
        windowKind: UsageWindowKind,
        level: UsageThresholdLevel,
        usedPercent: Int,
        identifier: String
    ) async -> Bool {
        let content = UNMutableNotificationContent()

        // Title: "Codex 使用量警告" or "Claude Code 使用量警告"
        let titleKey = level == .warning
            ? "notification.alertTitleWarning"
            : "notification.alertTitleDanger"
        content.title = String(
            format: titleKey.localized(),
            provider.displayName
        )

        // Body: window-specific message
        let bodyKey: String
        switch (provider, windowKind) {
        case (.githubCopilot, .primary):
            bodyKey = "notification.alertBodyMonth"
        case (_, .primary):
            bodyKey = "notification.alertBody5h"
        case (_, .secondary):
            bodyKey = "notification.alertBodyWeek"
        }
        content.body = String(format: bodyKey.localized(), usedPercent)

        content.sound = .default

        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil  // Deliver immediately
        )

        do {
            try await notificationCenter.add(request)
            Logger.notification.info("ThresholdNotificationManager: Sent notification for \(provider.displayName) \(windowKind.rawValue) \(level.rawValue) at \(usedPercent)%")
            return true
        } catch {
            Logger.notification.error("ThresholdNotificationManager: Failed to send notification: \(error.localizedDescription)")
            return false
        }
    }

    private func makeResetLevelSettings(
        oldLevel: ThresholdLevelSettings,
        newLevel: ThresholdLevelSettings
    ) -> ThresholdLevelSettings {
        guard shouldResetNotification(oldLevel: oldLevel, newLevel: newLevel) else { return newLevel }
        var updated = newLevel
        updated.lastNotifiedResetAt = nil
        return updated
    }

    private func shouldResetNotification(
        oldLevel: ThresholdLevelSettings,
        newLevel: ThresholdLevelSettings
    ) -> Bool {
        if oldLevel.thresholdPercent != newLevel.thresholdPercent {
            return true
        }
        if oldLevel.isEnabled == false && newLevel.isEnabled {
            return true
        }
        return false
    }

    private static func sanitizeSettings(
        _ settings: [UsageProvider: ProviderThresholdSettings]
    ) -> [UsageProvider: ProviderThresholdSettings] {
        Dictionary(uniqueKeysWithValues: settings.map { provider, providerSettings in
            if isValidProviderSettings(providerSettings, provider: provider) {
                return (provider, providerSettings)
            }
            return (provider, ProviderThresholdSettings.defaultSettings(for: provider))
        })
    }

    private static func normalizeWindowSettings(_ settings: WindowThresholdSettings) -> WindowThresholdSettings {
        var updated = settings
        let warningPercent = clampPercent(updated.warning.thresholdPercent)
        let dangerPercent = clampPercent(updated.danger.thresholdPercent)
        updated.warning.thresholdPercent = warningPercent
        updated.danger.thresholdPercent = dangerPercent
        return updated
    }

    private static func clampPercent(_ value: Int) -> Int {
        min(max(value, 1), 100)
    }

    private func syncUsageStatusThresholds(from settings: [UsageProvider: ProviderThresholdSettings]) {
        for (provider, providerSettings) in settings {
            let primaryThresholds = makeUsageStatusThresholds(from: providerSettings.primaryWindow)
            UsageStatusThresholdStore.saveThresholds(primaryThresholds, for: provider, windowKind: .primary)
            let secondaryThresholds = makeUsageStatusThresholds(from: providerSettings.secondaryWindow)
            UsageStatusThresholdStore.saveThresholds(secondaryThresholds, for: provider, windowKind: .secondary)
        }
        UsageStatusThresholdStore.bumpRevision()
    }

    private func makeUsageStatusThresholds(from settings: WindowThresholdSettings) -> UsageStatusThresholds {
        let warningPercent = Self.clampPercent(settings.warning.thresholdPercent)
        let dangerPercent = Self.clampPercent(settings.danger.thresholdPercent)
        return UsageStatusThresholds(warningPercent: warningPercent, dangerPercent: dangerPercent)
    }

    private static func isValidProviderSettings(
        _ settings: ProviderThresholdSettings,
        provider: UsageProvider
    ) -> Bool {
        guard settings.provider == provider else { return false }
        return isValidWindowSettings(settings.primaryWindow)
            && isValidWindowSettings(settings.secondaryWindow)
    }

    private static func isValidWindowSettings(_ settings: WindowThresholdSettings) -> Bool {
        guard isValidLevelSettings(settings.warning) else { return false }
        guard isValidLevelSettings(settings.danger) else { return false }
        return settings.warning.thresholdPercent <= settings.danger.thresholdPercent
    }

    private static func isValidLevelSettings(_ settings: ThresholdLevelSettings) -> Bool {
        (1...100).contains(settings.thresholdPercent)
    }

    // MARK: - Testing Support

    /// For testing: reloads settings from store
    func reloadSettings() {
        settings = store.loadSettings()
    }
}
