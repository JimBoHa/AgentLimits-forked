import AppKit
import SwiftUI

/// Account management sheet for the selected usage provider. Mutations flow
/// through UsageViewModel so snapshots, widgets, and live WebViews stay bound
/// to the same immutable account UUID.
struct ProviderAccountsSettingsView: View {
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var viewModel: UsageViewModel
    @ObservedObject var sessionActivityViewModel: SessionActivityViewModel
    let removalManager: ProviderAccountRemovalManager

    @State private var selectedProvider: UsageProvider
    @State private var editorConfiguration: AccountEditorConfiguration?
    @State private var activityCredentialAccount: ProviderAccount?
    @State private var removalCandidate: ProviderAccount?
    @State private var pendingRemovalAccountID: UUID?
    @State private var alertMessage: String?

    init(
        viewModel: UsageViewModel,
        sessionActivityViewModel: SessionActivityViewModel,
        removalManager: ProviderAccountRemovalManager,
        initialProvider: UsageProvider
    ) {
        self.viewModel = viewModel
        self.sessionActivityViewModel = sessionActivityViewModel
        self.removalManager = removalManager
        self._selectedProvider = State(initialValue: initialProvider)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            HStack {
                Text("accounts.title".localized())
                    .font(.title2.bold())
                Spacer()
                Button {
                    editorConfiguration = AccountEditorConfiguration(
                        provider: selectedProvider,
                        account: nil
                    )
                } label: {
                    Label("accounts.add".localized(), systemImage: "plus")
                }
                .settingsButtonStyle(.primary)
                .disabled(isBusy || !viewModel.webSessionsCanBeManaged)
                .accessibilityIdentifier("mac.accounts.add")

                Button("content.popupClose".localized()) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isBusy)
                .accessibilityIdentifier("mac.accounts.close")
            }

            Picker("content.provider".localized(), selection: $selectedProvider) {
                ForEach(UsageProvider.allCases) { provider in
                    Text(provider.displayName)
                        .tag(provider)
                        .accessibilityIdentifier(
                            "mac.accounts.provider.\(provider.rawValue)"
                        )
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("mac.accounts.providerPicker")

            List {
                ForEach(accounts) { account in
                    accountRow(account)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))

            if !viewModel.webSessionsCanBeManaged {
                Text("accounts.newerVersionReadOnly".localized())
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if accounts.count == 1 {
                Text("accounts.lastRequired".localized())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(DesignTokens.Spacing.large)
        .frame(minWidth: 760, minHeight: 430)
        .interactiveDismissDisabled(isBusy)
        .accessibilityIdentifier("mac.accounts.root")
        .sheet(item: $editorConfiguration) { configuration in
            ProviderAccountEditorView(configuration: configuration) {
                label, isEnabled, cliDataRoot in
                if let account = configuration.account {
                    _ = try viewModel.updateAccount(
                        id: account.id,
                        label: label,
                        isEnabled: isEnabled,
                        cliDataRoot: cliDataRoot
                    )
                } else {
                    _ = try viewModel.addAndSelectAccount(
                        id: configuration.id,
                        provider: configuration.provider,
                        label: label,
                        cliDataRoot: cliDataRoot
                    )
                }
            }
        }
        .sheet(item: $activityCredentialAccount) { account in
            GitHubActivityCredentialView(
                account: account,
                viewModel: sessionActivityViewModel
            )
        }
        .confirmationDialog(
            "accounts.removeTitle".localized(),
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { isPresented in
                    if !isPresented { removalCandidate = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            Button("accounts.remove".localized(), role: .destructive) {
                guard let account = removalCandidate else { return }
                removalCandidate = nil
                startRemoval(account)
            }
            .accessibilityIdentifier("mac.accounts.confirmRemove")
            Button("accounts.cancel".localized(), role: .cancel) {
                removalCandidate = nil
            }
        } message: {
            if let removalCandidate {
                Text(removalMessage(for: removalCandidate))
            }
        }
        .alert(
            "accounts.title".localized(),
            isPresented: Binding(
                get: { alertMessage != nil },
                set: { isPresented in
                    if !isPresented { alertMessage = nil }
                }
            )
        ) {
            Button("accounts.ok".localized(), role: .cancel) {
                alertMessage = nil
            }
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private var accounts: [ProviderAccount] {
        viewModel.accounts(for: selectedProvider)
    }

    private var isBusy: Bool {
        pendingRemovalAccountID != nil
    }

    @ViewBuilder
    private func accountRow(_ account: ProviderAccount) -> some View {
        HStack(spacing: DesignTokens.Spacing.medium) {
            Button {
                do {
                    _ = try viewModel.selectAccount(id: account.id)
                } catch {
                    alertMessage = error.localizedDescription
                }
            } label: {
                Image(
                    systemName: isSelected(account)
                        ? "checkmark.circle.fill"
                        : "circle"
                )
                .font(.title3)
            }
            .buttonStyle(.plain)
            .disabled(isBusy || !viewModel.webSessionsCanBeManaged)
            .accessibilityLabel(
                Text("accounts.selectFormat".localized(account.label))
            )
            .accessibilityIdentifier(
                "mac.accounts.select.\(account.id.uuidString.lowercased())"
            )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(account.label)
                        .fontWeight(isSelected(account) ? .semibold : .regular)
                    if isSelected(account) {
                        Text("accounts.selected".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(
                                Text(
                                    "\("accounts.selected".localized()) — "
                                        + account.label
                                )
                            )
                            .accessibilityIdentifier(
                                "mac.accounts.selected."
                                    + account.id.uuidString.lowercased()
                            )
                    }
                }
                Text(sessionDescription(for: account))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(
                    SessionActivityPresentation.summary(
                        for: account,
                        snapshot: sessionActivityViewModel.snapshot(
                            for: account.id
                        )
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if account.provider.tokenUsageProvider?.isCLIBased == true {
                    Text(
                        "accounts.cliDataRootFormat".localized(
                            account.cliDataRoot
                                ?? "accounts.cliDataRootDefault".localized()
                        )
                    )
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if pendingRemovalAccountID == account.id {
                ProgressView()
                    .controlSize(.small)
            }

            if account.provider == .githubCopilot {
                if sessionActivityViewModel.isFetching(
                    accountID: account.id
                ) {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    Task {
                        await sessionActivityViewModel.refresh(
                            account: account
                        )
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(
                    isBusy
                        || sessionActivityViewModel.isFetching(
                            accountID: account.id
                        )
                )
                .help("activity.refresh".localized())

                Button {
                    activityCredentialAccount = account
                } label: {
                    Image(systemName: "key")
                }
                .disabled(isBusy)
                .help("activity.credentialTitle".localized())
                .accessibilityLabel(
                    "\("activity.manageCredential".localized()) — \(account.label)"
                )
            }

            Toggle(
                "accounts.autoRefresh".localized(),
                isOn: Binding(
                    get: { account.isEnabled },
                    set: { isEnabled in
                        do {
                            _ = try viewModel.updateAccount(
                                id: account.id,
                                label: account.label,
                                isEnabled: isEnabled
                            )
                        } catch {
                            alertMessage = error.localizedDescription
                        }
                    }
                )
            )
            .toggleStyle(.checkbox)
            .disabled(isBusy || !viewModel.webSessionsCanBeManaged)

            Button {
                editorConfiguration = AccountEditorConfiguration(
                    provider: account.provider,
                    account: account
                )
            } label: {
                Image(systemName: "pencil")
            }
            .disabled(isBusy || !viewModel.webSessionsCanBeManaged)
            .help("accounts.edit".localized())

            Button(role: .destructive) {
                removalCandidate = account
            } label: {
                Image(systemName: "trash")
            }
            .disabled(
                isBusy
                    || accounts.count <= 1
                    || !viewModel.webSessionsCanBeManaged
            )
            .help(
                accounts.count <= 1
                    ? "accounts.lastRequired".localized()
                    : "accounts.remove".localized()
            )
            .accessibilityLabel(
                Text(
                    "\("accounts.remove".localized()) — \(account.label)"
                )
            )
            .accessibilityIdentifier(
                "mac.accounts.remove.\(account.id.uuidString.lowercased())"
            )
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier(
            "mac.accounts.row.\(account.id.uuidString.lowercased())"
        )
    }

    private func isSelected(_ account: ProviderAccount) -> Bool {
        viewModel.selectedAccount(for: account.provider).id == account.id
    }

    private func sessionDescription(for account: ProviderAccount) -> String {
        switch account.webKitStorage {
        case .isolated:
            return "accounts.isolatedSession".localized()
        case .legacyDefault:
            return "accounts.legacySession".localized()
        }
    }

    private func removalMessage(for account: ProviderAccount) -> String {
        switch account.webKitStorage {
        case .isolated:
            if account.provider == .githubCopilot {
                return "accounts.removeGitHubMessage".localized(
                    account.label
                )
            }
            return "accounts.removeMessage".localized(account.label)
        case .legacyDefault:
            if account.provider == .githubCopilot {
                return "accounts.removeLegacyGitHubMessage".localized(
                    account.label
                )
            }
            return "accounts.removeLegacyMessage".localized(account.label)
        }
    }

    private func startRemoval(_ account: ProviderAccount) {
        guard pendingRemovalAccountID == nil else { return }
        pendingRemovalAccountID = account.id
        Task { await remove(account) }
    }

    private func remove(_ account: ProviderAccount) async {
        defer {
            pendingRemovalAccountID = nil
            // prepareRemoval may change selection before later cleanup fails.
            viewModel.reloadAccounts()
        }
        do {
            let outcome = try await removalManager.removeAccount(id: account.id)
            if outcome == .removedWithPendingCleanup {
                alertMessage = "accounts.pendingCleanup".localized()
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }
}

private struct AccountEditorConfiguration: Identifiable {
    let id = UUID()
    let provider: UsageProvider
    let account: ProviderAccount?
}

private struct ProviderAccountEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let configuration: AccountEditorConfiguration
    let onSave: (String, Bool, String?) throws -> Void

    @State private var label: String
    @State private var isEnabled: Bool
    @State private var cliDataRoot: String
    @State private var errorMessage: String?

    init(
        configuration: AccountEditorConfiguration,
        onSave: @escaping (String, Bool, String?) throws -> Void
    ) {
        self.configuration = configuration
        self.onSave = onSave
        self._label = State(initialValue: configuration.account?.label ?? "")
        self._isEnabled = State(
            initialValue: configuration.account?.isEnabled ?? true
        )
        self._cliDataRoot = State(
            initialValue: configuration.account?.cliDataRoot ?? ""
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text(
                configuration.account == nil
                    ? "accounts.add".localized()
                    : "accounts.edit".localized()
            )
            .font(.title2.bold())

            Form {
                LabeledContent("content.provider".localized()) {
                    Text(configuration.provider.displayName)
                }
                TextField("accounts.label".localized(), text: $label)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mac.accounts.editor.label")
                if usesCLIDataRoot {
                    LabeledContent("accounts.cliDataRoot".localized()) {
                        HStack {
                            TextField(
                                "accounts.cliDataRootPlaceholder".localized(),
                                text: $cliDataRoot
                            )
                            .textFieldStyle(.roundedBorder)
                            Button("accounts.chooseFolder".localized()) {
                                chooseCLIDataRoot()
                            }
                        }
                    }
                    Text("accounts.cliDataRootHelp".localized())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if configuration.account != nil {
                    Toggle(
                        "accounts.autoRefresh".localized(),
                        isOn: $isEnabled
                    )
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("accounts.cancel".localized()) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("mac.accounts.editor.cancel")
                Button("accounts.save".localized()) {
                    do {
                        let trimmedRoot = cliDataRoot.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        )
                        let resolvedRoot = usesCLIDataRoot
                            && !trimmedRoot.isEmpty
                            ? trimmedRoot
                            : nil
                        if let tokenProvider = configuration.provider
                            .tokenUsageProvider,
                           tokenProvider.isCLIBased {
                            _ = try tokenProvider
                                .resolveCLIDataRootEnvironment(resolvedRoot)
                        }
                        try onSave(
                            label,
                            isEnabled,
                            resolvedRoot
                        )
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
                .keyboardShortcut(.defaultAction)
                .settingsButtonStyle(.primary)
                .accessibilityIdentifier("mac.accounts.editor.save")
                .disabled(
                    label.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                )
            }
        }
        .padding(DesignTokens.Spacing.large)
        .frame(width: 430)
        .accessibilityIdentifier("mac.accounts.editor.root")
        .alert(
            "accounts.title".localized(),
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { isPresented in
                    if !isPresented { errorMessage = nil }
                }
            )
        ) {
            Button("accounts.ok".localized(), role: .cancel) {
                errorMessage = nil
            }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var usesCLIDataRoot: Bool {
        configuration.provider.tokenUsageProvider?.isCLIBased == true
    }

    private func chooseCLIDataRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "accounts.chooseFolder".localized()
        if panel.runModal() == .OK, let url = panel.url {
            cliDataRoot = url.path
        }
    }
}
