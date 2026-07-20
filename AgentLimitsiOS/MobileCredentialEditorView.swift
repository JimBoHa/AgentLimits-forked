import SwiftUI

struct MobileCredentialEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let account: MobileProviderAccount
    @ObservedObject var activityController: MobileSessionActivityController

    @State private var credential = ""
    @State private var hasStoredCredential = false
    @State private var storedCredentialIsInvalid = false
    @State private var isSaving = false
    @State private var isShowingRemoveConfirmation = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Name", value: account.label)
                }

                Section {
                    SecureField("Fine-grained token", text: $credential)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .privacySensitive()
                        .accessibilityIdentifier("mobile.credentialField")

                    Text(credentialStatusText)
                        .foregroundStyle(credentialStatusColor)
                        .accessibilityLabel("Credential status: \(credentialStatusText)")
                } header: {
                    Text("GitHub credential")
                } footer: {
                    Text(
                        "Use a fine-grained personal access token or GitHub App user token with only Agent tasks read permission. The token is stored in this device's non-synchronizing Keychain and sent directly to api.github.com over HTTPS when you refresh."
                    )
                }

                Section {
                    Link(
                        "GitHub Agent Tasks API documentation",
                        destination: URL(
                            string: "https://docs.github.com/en/rest/agent-tasks/agent-tasks"
                        )!
                    )
                    NavigationLink {
                        MobilePrivacyView()
                    } label: {
                        Label("Privacy", systemImage: "hand.raised")
                    }
                }

                if hasStoredCredential || storedCredentialIsInvalid {
                    Section {
                        Button("Remove Credential", role: .destructive) {
                            isShowingRemoveConfirmation = true
                        }
                        .disabled(isSaving)
                    }
                }
            }
            .navigationTitle("Session Credential")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCredential()
                    }
                    .disabled(isSaving || trimmedCredential.isEmpty)
                    .accessibilityIdentifier("mobile.saveCredential")
                }
            }
            .interactiveDismissDisabled(isSaving)
            .onAppear(perform: loadCredentialStatus)
            .confirmationDialog(
                "Remove this credential?",
                isPresented: $isShowingRemoveConfirmation,
                titleVisibility: .visible
            ) {
                Button("Remove Credential", role: .destructive) {
                    removeCredential()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Current-session counts for this account will become unavailable.")
            }
            .alert(
                "Session Credential",
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
        }
    }

    private var trimmedCredential: String {
        credential.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var credentialStatusText: String {
        if storedCredentialIsInvalid {
            return "Saved credential is invalid"
        }
        return hasStoredCredential
            ? "Credential saved on this device"
            : "No credential saved"
    }

    private var credentialStatusColor: Color {
        if storedCredentialIsInvalid {
            return .orange
        }
        return hasStoredCredential ? .green : .secondary
    }

    private func loadCredentialStatus() {
        do {
            hasStoredCredential = try activityController.hasCredential(
                for: account.id
            )
            storedCredentialIsInvalid = false
        } catch MobileSessionCredentialStoreError.invalidStoredCredential {
            hasStoredCredential = false
            storedCredentialIsInvalid = true
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveCredential() {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await activityController.saveCredential(
                    trimmedCredential,
                    for: account.id
                )
                credential = ""
                hasStoredCredential = true
                storedCredentialIsInvalid = false
                dismiss()
                Task { @MainActor in
                    await activityController.refresh(accountID: account.id)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func removeCredential() {
        guard !isSaving else { return }
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await activityController.deleteCredential(for: account.id)
                credential = ""
                hasStoredCredential = false
                storedCredentialIsInvalid = false
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
