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
    var body: some View {
#if DEBUG
        if AppRuntimeEnvironment.isUITesting {
            UITestingUpdateSettingsView()
        } else {
            ProductionUpdateSettingsView()
        }
#else
        ProductionUpdateSettingsView()
#endif
    }
}

private struct ProductionUpdateSettingsView: View {

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
        .accessibilityIdentifier("mac.update.root")
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
                    .accessibilityHidden(true)
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
                    .accessibilityHidden(true)
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

#if DEBUG
/// Static presentation avoids constructing Sparkle or observing its standard
/// defaults domain while UI tests exercise settings navigation.
private struct UITestingUpdateSettingsView: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("update.currentVersion".localized()) {
                    Text(versionString)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("update.lastChecked".localized()) {
                    Text("update.neverChecked".localized())
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button("update.checkNow".localized()) {}
                    .disabled(true)
                Toggle(
                    "update.automaticChecks".localized(),
                    isOn: .constant(false)
                )
                .disabled(true)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("tab.update".localized())
        .accessibilityIdentifier("mac.update.root")
    }

    private var versionString: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? "—"
        return "\(version) (\(build))"
    }
}
#endif
