// MARK: - UpdateSettingsView.swift
// アップデート設定タブ。Sparkle によるアップデートチェック状態の表示と手動チェックを提供する。

import SwiftUI

nonisolated enum UpdateSettingsLinks {
    static let releases = URL(
        string: "https://github.com/JimBoHa/AgentLimits-forked/releases"
    )!
    static let privacyPolicy = URL(
        string: "https://github.com/JimBoHa/AgentLimits-forked/blob/main/PRIVACY.md"
    )!
}

/// アップデート設定タブ UI
struct UpdateSettingsView: View {

    @ObservedObject private var updateController = AppUpdateController.shared

    var body: some View {
        Form {
            Section {
                currentVersionRow
                lastCheckedRow
            }

            Section {
                checkNowButton
                automaticChecksToggle
            }

            Section {
                releasesLink
                privacyPolicyLink
            }
        }
        .formStyle(.grouped)
        .navigationTitle("tab.update".localized())
    }

    // MARK: - Rows

    private var currentVersionRow: some View {
        LabeledContent("update.currentVersion".localized()) {
            Text(versionString)
                .foregroundStyle(.secondary)
        }
    }

    private var lastCheckedRow: some View {
        LabeledContent("update.lastChecked".localized()) {
            Text(lastCheckedText)
                .foregroundStyle(.secondary)
        }
    }

    private var checkNowButton: some View {
        Button("update.checkNow".localized()) {
            updateController.checkForUpdates()
        }
        .disabled(!updateController.canCheckForUpdates)
    }

    private var automaticChecksToggle: some View {
        Toggle(
            "update.automaticChecks".localized(),
            isOn: Binding(
                get: { updateController.automaticChecksEnabled },
                set: { updateController.setAutomaticChecksEnabled($0) }
            )
        )
        .disabled(!updateController.isConfigured)
    }

    private var releasesLink: some View {
        Link(destination: UpdateSettingsLinks.releases) {
            HStack {
                Text("update.releasesPage".localized())
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var privacyPolicyLink: some View {
        Link(destination: UpdateSettingsLinks.privacyPolicy) {
            HStack {
                Text("update.privacyPolicy".localized())
                Spacer()
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("update.privacyPolicyLink")
    }

    // MARK: - Helpers

    private var versionString: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var lastCheckedText: String {
        guard let date = updateController.lastUpdateCheckDate else {
            return "update.neverChecked".localized()
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
