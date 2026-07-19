import SwiftUI

struct MobilePrivacyView: View {
    private static let policyURL = URL(
        string: "https://github.com/JimBoHa/AgentLimits-forked/blob/main/PRIVACY.md"
    )!

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                privacySection(
                    title: "No Tracking or Collection",
                    text: "AgentLimits has no advertising, analytics, telemetry, or cross-app tracking. The app maintainer does not collect your accounts, credentials, usage information, or session counts."
                )

                privacySection(
                    title: "GitHub Credential",
                    text: "Your GitHub credential is stored in this device's non-synchronizing Keychain. It does not sync through iCloud and is never sent to Apple Watch. When you refresh Copilot session counts, the credential is sent directly to api.github.com over HTTPS and never to the app maintainer."
                )

                privacySection(
                    title: "Local Data",
                    text: "Account names, preferences, cached counts, and timestamps stay in app storage on your device. Apple Watch receives only display information, aggregate counts, availability, and timestamps—not credentials or provider cookies."
                )

                privacySection(
                    title: "Delete Your Data",
                    text: "Remove an account to delete its saved session credential and cached activity. Clear Session Data removes all GitHub session credentials and counts while keeping account names. Use these controls before uninstalling because Keychain items can survive app removal."
                )

                Link(destination: Self.policyURL) {
                    Label(
                        "Read Full Privacy Policy",
                        systemImage: "arrow.up.right.square"
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier("mobile.privacyPolicyLink")
                .accessibilityHint("Opens the full policy on GitHub")
            }
            .padding()
        }
        .accessibilityIdentifier("mobile.privacyPolicy")
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func privacySection(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            Text(text)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        MobilePrivacyView()
    }
}
