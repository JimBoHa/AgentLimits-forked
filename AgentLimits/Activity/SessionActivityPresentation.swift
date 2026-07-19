import SwiftUI

enum SessionActivityPresentation {
    static func summary(
        for account: ProviderAccount,
        snapshot: SessionActivitySnapshot?
    ) -> String {
        guard account.provider == .githubCopilot else {
            return "activity.unsupported".localized()
        }
        guard let snapshot,
              snapshot.accountID == account.id,
              snapshot.provider == account.provider else {
            return "activity.notChecked".localized()
        }

        switch snapshot.availability {
        case .available:
            guard let open = snapshot.open,
                  let working = snapshot.working,
                  let waiting = snapshot.waiting else {
                return "activity.unavailable".localized()
            }
            return "activity.summaryFormat".localized(
                open,
                working,
                waiting
            )
        case .stale:
            guard let open = snapshot.open,
                  let working = snapshot.working,
                  let waiting = snapshot.waiting else {
                return "activity.unavailable".localized()
            }
            return "activity.staleSummaryFormat".localized(
                open,
                working,
                waiting
            )
        case .authenticationRequired:
            return "activity.authenticationRequired".localized()
        case .unsupported:
            return "activity.unsupported".localized()
        case .error:
            return "activity.unavailable".localized()
        }
    }
}

struct SessionActivitySummaryView: View {
    let account: ProviderAccount
    let snapshot: SessionActivitySnapshot?
    let isFetching: Bool
    let onRefresh: () -> Void
    let onManageCredential: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            HStack(spacing: DesignTokens.Spacing.medium) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(
                        SessionActivityPresentation.summary(
                            for: account,
                            snapshot: snapshot
                        )
                    )
                    .font(.subheadline)

                    if account.provider == .githubCopilot {
                        Text("activity.scopeGitHub".localized())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let snapshot,
                           snapshot.accountID == account.id,
                           snapshot.availability == .available
                            || snapshot.availability == .stale {
                            HStack(spacing: 4) {
                                Text("activity.observed".localized())
                                Text(snapshot.observedAt, style: .relative)
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if isFetching {
                    ProgressView()
                        .controlSize(.small)
                }

                Button("activity.refresh".localized(), action: onRefresh)
                    .disabled(
                        account.provider != .githubCopilot || isFetching
                    )
                    .settingsButtonStyle(.secondary)

                if let onManageCredential,
                   account.provider == .githubCopilot {
                    Button(action: onManageCredential) {
                        Image(systemName: "key")
                    }
                    .help("activity.credentialTitle".localized())
                }
            }
        }
    }
}

struct GitHubActivityCredentialView: View {
    @Environment(\.dismiss) private var dismiss

    let account: ProviderAccount
    @ObservedObject var viewModel: SessionActivityViewModel

    @State private var credential = ""
    @State private var hasStoredCredential = false
    @State private var storedCredentialIsInvalid = false
    @State private var isSaving = false
    @State private var isShowingRemoveConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Text("activity.credentialTitle".localized())
                .font(.title2.bold())

            Form {
                LabeledContent("content.account".localized()) {
                    Text(account.label)
                }
                SecureField(
                    "activity.credentialPlaceholder".localized(),
                    text: $credential
                )
                .textFieldStyle(.roundedBorder)

                Text("activity.credentialHelp".localized())
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text(
                    credentialStatusText
                )
                .font(.footnote)
                .foregroundStyle(
                    storedCredentialIsInvalid
                        ? Color.orange
                        : hasStoredCredential
                            ? Color.green
                            : Color.secondary
                )

                Link(
                    "activity.apiDocumentation".localized(),
                    destination: URL(
                        string: "https://docs.github.com/en/rest/agent-tasks/agent-tasks"
                    )!
                )
                .font(.footnote)
            }
            .formStyle(.grouped)

            HStack {
                if hasStoredCredential || storedCredentialIsInvalid {
                    Button(
                        "activity.removeCredential".localized(),
                        role: .destructive
                    ) {
                        isShowingRemoveConfirmation = true
                    }
                    .disabled(isSaving)
                }

                Spacer()

                Button("accounts.cancel".localized()) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)

                Button("activity.saveCredential".localized()) {
                    saveCredential()
                }
                .keyboardShortcut(.defaultAction)
                .settingsButtonStyle(.primary)
                .disabled(
                    isSaving
                        || credential.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                )
            }
        }
        .padding(DesignTokens.Spacing.large)
        .frame(width: 520)
        .interactiveDismissDisabled(isSaving)
        .onAppear(perform: loadCredentialStatus)
        .confirmationDialog(
            "activity.removeCredentialTitle".localized(),
            isPresented: $isShowingRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button(
                "activity.removeCredential".localized(),
                role: .destructive
            ) {
                removeCredential()
            }
            Button("accounts.cancel".localized(), role: .cancel) {}
        } message: {
            Text("activity.removeCredentialMessage".localized())
        }
        .alert(
            "activity.credentialTitle".localized(),
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

    private func loadCredentialStatus() {
        do {
            hasStoredCredential = try viewModel.hasCredential(for: account)
            storedCredentialIsInvalid = false
        } catch {
            if let credentialError = error
                as? SessionActivityCredentialStoreError,
               credentialError == .invalidStoredCredential {
                // The Keychain item exists but cannot be read as a safe token.
                // Keep removal available so the user can recover.
                hasStoredCredential = false
                storedCredentialIsInvalid = true
            }
            errorMessage = error.localizedDescription
        }
    }

    private func saveCredential() {
        guard !isSaving else { return }
        isSaving = true
        do {
            try viewModel.saveCredential(credential, for: account)
            credential = ""
            hasStoredCredential = true
            storedCredentialIsInvalid = false
            isSaving = false
            Task {
                await viewModel.refresh(account: account)
            }
            dismiss()
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }

    private func removeCredential() {
        guard !isSaving else { return }
        isSaving = true
        do {
            try viewModel.deleteCredential(for: account)
            credential = ""
            hasStoredCredential = false
            storedCredentialIsInvalid = false
            isSaving = false
        } catch {
            isSaving = false
            errorMessage = error.localizedDescription
        }
    }

    private var credentialStatusText: String {
        if storedCredentialIsInvalid {
            return "activity.errorInvalidStoredCredential".localized()
        }
        return hasStoredCredential
            ? "activity.credentialStored".localized()
            : "activity.noCredential".localized()
    }
}
