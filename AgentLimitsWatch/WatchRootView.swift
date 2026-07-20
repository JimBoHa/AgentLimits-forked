import SwiftUI

struct WatchRootView: View {
    @ObservedObject var store: WatchCompanionStore

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                List {
                    if !store.isPhoneReachable {
                        Section {
                            Label(
                                "iPhone unavailable",
                                systemImage: "iphone.slash"
                            )
                            .foregroundStyle(.orange)
                        } footer: {
                            Text("Cached data remains available. Open AgentLimits on iPhone for live refresh.")
                        }
                    }

                    if let error = store.lastError {
                        Section {
                            Label(
                                error.localizedDescription,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .foregroundStyle(.orange)
                        }
                    }

                    if !store.hasData {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("No iPhone Data", systemImage: "iphone")
                                    .font(.headline)
                                Text("Open AgentLimits on your paired iPhone to sync account activity.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("watch.noData")
                        }
                    } else {
                        if store.isDataStale(at: context.date) {
                            Section {
                                Label(
                                    "Synced data is stale",
                                    systemImage: "clock.badge.exclamationmark"
                                )
                                .foregroundStyle(.orange)
                            }
                        }

                        ForEach(WatchCompanionProvider.allCases, id: \.self) {
                            provider in
                            providerSection(provider, at: context.date)
                        }

                        if let generatedAt = store.envelope?.generatedAt {
                            Section {
                                Text("Synced \(generatedAt, style: .relative)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("watch.root")
            }
            .navigationTitle("AgentLimits")
        }
    }

    @ViewBuilder
    private func providerSection(
        _ provider: WatchCompanionProvider,
        at date: Date
    ) -> some View {
        let accounts = store.accounts(for: provider, at: date)
        if !accounts.isEmpty {
            Section(provider.displayName) {
                ForEach(accounts) { account in
                    NavigationLink {
                        WatchAccountDetailView(
                            store: store,
                            accountID: account.id
                        )
                    } label: {
                        WatchAccountRow(account: account)
                    }
                    .accessibilityIdentifier(
                        "watch.account.\(account.id.uuidString.lowercased())"
                    )
                }
            }
        }
    }
}

private struct WatchAccountRow: View {
    let account: WatchCompanionAccountPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(account.status.label)
                    .font(.headline)
                Spacer(minLength: 4)
                if !account.status.isEnabled {
                    Image(systemName: "pause.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Automatic refresh paused")
                }
            }
            Text(WatchActivityText.summary(for: account))
                .font(.caption)
                .foregroundStyle(WatchActivityText.color(for: account.availability))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(account.status.label), \(WatchActivityText.summary(for: account))"
        )
    }
}

private struct WatchAccountDetailView: View {
    @ObservedObject var store: WatchCompanionStore
    let accountID: UUID

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if let account = store.account(id: accountID, at: context.date) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.status.provider.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text(WatchActivityText.summary(for: account))
                            .font(.headline)
                            .foregroundStyle(
                                WatchActivityText.color(
                                    for: account.availability
                                )
                            )

                        if let open = account.status.open,
                           let working = account.status.working,
                           let waiting = account.status.waiting {
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: 10) {
                                    metric("Open", value: open)
                                    metric("Working", value: working)
                                    metric("Waiting", value: waiting)
                                }
                                VStack(alignment: .leading, spacing: 6) {
                                    metric("Open", value: open)
                                    metric("Working", value: working)
                                    metric("Waiting", value: waiting)
                                }
                            }
                        }

                        if let observedAt = account.status.observedAt {
                            Label {
                                Text("Observed \(observedAt, style: .relative)")
                            } icon: {
                                Image(systemName: "clock")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }

                        if let retryAt = account.status.retryAt {
                            Label {
                                Text("Retry \(retryAt, style: .relative)")
                            } icon: {
                                Image(systemName: "arrow.clockwise")
                            }
                            .font(.caption2)
                            .foregroundStyle(.orange)
                        }

                        if account.status.provider == .copilot,
                           account.status.isEnabled {
                            Button {
                                store.requestRefresh(accountID: account.id)
                            } label: {
                                Label(
                                    "Refresh on iPhone",
                                    systemImage: "arrow.clockwise"
                                )
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!store.isPhoneReachable)
                            .accessibilityIdentifier("watch.refreshAccount")

                            if !store.isPhoneReachable {
                                Text("Open AgentLimits on your paired iPhone to refresh.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
                .navigationTitle(account.status.label)
            } else {
                ContentUnavailableView(
                    "Account Unavailable",
                    systemImage: "person.crop.circle.badge.questionmark"
                )
            }
        }
    }

    private func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value, format: .number)
                .font(.title3.monospacedDigit().bold())
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(value)")
    }
}

private enum WatchActivityText {
    static func summary(
        for account: WatchCompanionAccountPresentation
    ) -> String {
        switch account.availability {
        case .available:
            return countSummary(prefix: nil, open: account.status.open)
        case .stale:
            return countSummary(prefix: "Stale", open: account.status.open)
        case .notChecked:
            return "Not checked"
        case .unsupported:
            return "Session count unavailable"
        case .authenticationRequired:
            return "Sign in on iPhone"
        case .insufficientPermissions:
            return "Permission required"
        case .rateLimited:
            return countSummary(prefix: "Rate limited", open: account.status.open)
        case .unavailable:
            return "Unavailable"
        }
    }

    static func color(for availability: WatchCompanionAvailability) -> Color {
        switch availability {
        case .available:
            return .green
        case .stale, .rateLimited:
            return .orange
        case .authenticationRequired, .insufficientPermissions:
            return .red
        case .notChecked, .unsupported, .unavailable:
            return .secondary
        }
    }

    private static func countSummary(prefix: String?, open: Int?) -> String {
        let count = open.map { "\($0) open" } ?? "Count unavailable"
        guard let prefix else { return count }
        return "\(prefix) · \(count)"
    }
}
