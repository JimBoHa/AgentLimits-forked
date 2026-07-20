import SwiftUI

struct MobileRootView: View {
    @Environment(\.scenePhase) private var scenePhase

    let model: MobileAppModel
    @ObservedObject private var accountStore: MobileAccountStore
    @ObservedObject private var activityController: MobileSessionActivityController

    @State private var editorConfiguration: MobileAccountEditorConfiguration?
    @State private var credentialAccount: MobileProviderAccount?
    @State private var removalCandidate: MobileProviderAccount?
    @State private var isShowingClearConfirmation = false
    @State private var errorMessage: String?

    init(model: MobileAppModel) {
        self.model = model
        self._accountStore = ObservedObject(wrappedValue: model.accountStore)
        self._activityController = ObservedObject(
            wrappedValue: model.activityController
        )
    }

    var body: some View {
        NavigationStack {
            List {
                if let unsupportedVersion = accountStore.unsupportedStoredVersion {
                    Section {
                        Label(
                            "Accounts were saved by newer app version \(unsupportedVersion). Editing is disabled.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                if let recoveryFailure = accountStore.recoveryFailure {
                    Section {
                        Label(
                            recoveryFailure.localizedDescription,
                            systemImage: "exclamationmark.shield.fill"
                        )
                        .foregroundStyle(.red)
                    } footer: {
                        Text(
                            "Account editing is disabled. Restart AgentLimits to retry secure cleanup."
                        )
                    }
                } else if accountStore.didRecoverCorruptData {
                    Section {
                        Label(
                            accountStore.didClearCredentialsDuringRecovery
                                ? "Damaged account data was repaired. Saved session credentials were cleared to prevent unreachable secrets."
                                : "Damaged account data was repaired. Saved session credentials remain available.",
                            systemImage: "checkmark.shield.fill"
                        )
                        .foregroundStyle(.orange)
                    }
                }

                ForEach(MobileProvider.allCases) { provider in
                    providerSection(provider)
                }

                Section("Security") {
                    Button(role: .destructive) {
                        isShowingClearConfirmation = true
                    } label: {
                        Label("Clear Session Data", systemImage: "key.slash")
                    }
                    .accessibilityHint(
                        "Deletes all saved GitHub credentials and current-session counts, but keeps account names."
                    )
                }

                Section("About") {
                    NavigationLink {
                        MobilePrivacyView()
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                    .accessibilityIdentifier("mobile.privacy")
                }
            }
            .accessibilityIdentifier("mobile.accountList")
            .navigationTitle("AgentLimits")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ForEach(MobileProvider.allCases) { provider in
                            Button(provider.displayName) {
                                editorConfiguration =
                                    MobileAccountEditorConfiguration(
                                        provider: provider,
                                        account: nil
                                    )
                            }
                            .accessibilityIdentifier(
                                "mobile.addAccount.\(provider.rawValue)"
                            )
                        }
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .disabled(!accountStore.canMutate)
                    .accessibilityIdentifier("mobile.addAccount")
                }
            }
            .sheet(item: $editorConfiguration) { configuration in
                MobileAccountEditorView(configuration: configuration) {
                    label, isEnabled in
                    if let account = configuration.account {
                        _ = try model.updateAccount(
                            id: account.id,
                            label: label,
                            isEnabled: isEnabled
                        )
                    } else {
                        let account = try model.addAccount(
                            provider: configuration.provider,
                            label: label
                        )
                        if !isEnabled {
                            _ = try model.updateAccount(
                                id: account.id,
                                label: account.label,
                                isEnabled: false
                            )
                        }
                    }
                }
            }
            .sheet(item: $credentialAccount) { account in
                MobileCredentialEditorView(
                    account: account,
                    activityController: activityController
                )
            }
            .confirmationDialog(
                "Remove account?",
                isPresented: Binding(
                    get: { removalCandidate != nil },
                    set: { if !$0 { removalCandidate = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove Account", role: .destructive) {
                    removeCandidate()
                }
                Button("Cancel", role: .cancel) {
                    removalCandidate = nil
                }
            } message: {
                if let removalCandidate {
                    Text(
                        "Remove \(removalCandidate.label)? Its saved session credential and counts will also be deleted."
                    )
                }
            }
            .confirmationDialog(
                "Clear all session data?",
                isPresented: $isShowingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear Session Data", role: .destructive) {
                    clearSessionData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This deletes every saved GitHub credential and current-session count. Account names remain."
                )
            }
            .alert(
                "AgentLimits",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "")
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await model.refreshEnabledAccounts()
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(
                            for: MobileSessionRefreshConfig.automaticInterval
                        )
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await model.refreshEnabledAccounts()
                }
            }
        }
    }

    @ViewBuilder
    private func providerSection(_ provider: MobileProvider) -> some View {
        Section {
            ForEach(accountStore.accounts(for: provider)) { account in
                accountRow(account)
            }
        } header: {
            Text(provider.displayName)
        } footer: {
            if !provider.supportsCurrentSessions {
                Text(
                    "Current-session counts are unavailable for \(provider.displayName)."
                )
            }
        }
    }

    @ViewBuilder
    private func accountRow(_ account: MobileProviderAccount) -> some View {
        let snapshot = activityController.snapshot(for: account)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.label)
                        .font(.headline)
                    Text(activitySummary(snapshot))
                        .font(.subheadline)
                        .foregroundStyle(activityColor(snapshot))
                    if let observedAt = snapshot.observedAt {
                        Text("Observed \(observedAt, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let retryAt = snapshot.retryAt {
                        Text("Automatic retry \(retryAt, style: .relative)")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Spacer()

                if activityController.isFetching(accountID: account.id) {
                    ProgressView()
                        .accessibilityLabel("Refreshing \(account.label)")
                }

                Menu {
                    Button {
                        editorConfiguration = MobileAccountEditorConfiguration(
                            provider: account.provider,
                            account: account
                        )
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    if account.provider == .copilot {
                        Button {
                            credentialAccount = account
                        } label: {
                            Label("Session Credential", systemImage: "key")
                        }
                    }

                    Button(role: .destructive) {
                        removalCandidate = account
                    } label: {
                        Label("Remove", systemImage: "trash")
                    }
                    .disabled(
                        accountStore.accounts(for: account.provider).count <= 1
                            || !accountStore.canMutate
                    )
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .imageScale(.large)
                }
                .accessibilityLabel("Actions for \(account.label)")
            }

            ViewThatFits(in: .horizontal) {
                HStack {
                    refreshToggle(for: account)
                    if account.provider == .copilot {
                        Spacer()
                        refreshButton(for: account)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    refreshToggle(for: account)
                    if account.provider == .copilot {
                        refreshButton(for: account)
                    }
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            "mobile.account.\(account.id.uuidString.lowercased())"
        )
    }

    private func refreshToggle(
        for account: MobileProviderAccount
    ) -> some View {
        Toggle(
            "Refresh when active",
            isOn: Binding(
                get: { account.isEnabled },
                set: { isEnabled in
                    updateEnabled(account, isEnabled: isEnabled)
                }
            )
        )
        .disabled(!accountStore.canMutate)
        .accessibilityLabel("Refresh \(account.label) when active")
    }

    private func refreshButton(
        for account: MobileProviderAccount
    ) -> some View {
        Button {
            Task {
                await activityController.refresh(accountID: account.id)
            }
        } label: {
            Label("Refresh", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.bordered)
        .disabled(activityController.isFetching(accountID: account.id))
        .accessibilityLabel("Refresh \(account.label)")
        .accessibilityIdentifier(
            "mobile.refresh.\(account.id.uuidString.lowercased())"
        )
    }

    private func activitySummary(
        _ snapshot: MobileSessionActivitySnapshot
    ) -> String {
        switch snapshot.availability {
        case .available:
            return countsSummary(snapshot)
        case .stale:
            return "Last known: \(countsSummary(snapshot))"
        case .unsupported:
            return "Current sessions unavailable"
        case .authenticationRequired:
            return "Credential unavailable"
        case .insufficientPermissions:
            return "Agent tasks read permission required"
        case .rateLimited:
            if snapshot.open != nil {
                return "Last known: \(countsSummary(snapshot))"
            }
            return "GitHub rate limit reached"
        case .unavailable:
            return "Current sessions unavailable"
        case .notChecked:
            return "Current sessions not checked"
        }
    }

    private func countsSummary(
        _ snapshot: MobileSessionActivitySnapshot
    ) -> String {
        guard let open = snapshot.open,
              let working = snapshot.working,
              let waiting = snapshot.waiting else {
            return "Current sessions unavailable"
        }
        return "\(open) open · \(working) working · \(waiting) waiting"
    }

    private func activityColor(
        _ snapshot: MobileSessionActivitySnapshot
    ) -> Color {
        switch snapshot.availability {
        case .available:
            return .primary
        case .stale, .authenticationRequired, .insufficientPermissions,
             .rateLimited:
            return .orange
        case .notChecked, .unsupported, .unavailable:
            return .secondary
        }
    }

    private func updateEnabled(
        _ account: MobileProviderAccount,
        isEnabled: Bool
    ) {
        do {
            _ = try model.updateAccount(
                id: account.id,
                label: account.label,
                isEnabled: isEnabled
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeCandidate() {
        guard let candidate = removalCandidate else { return }
        removalCandidate = nil
        do {
            try model.removeAccount(id: candidate.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func clearSessionData() {
        do {
            try model.clearAllSessionData()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
