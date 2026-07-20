import SwiftUI

struct MobileAccountEditorConfiguration: Identifiable {
    let id = UUID()
    let provider: MobileProvider
    let account: MobileProviderAccount?
}

struct MobileAccountEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let configuration: MobileAccountEditorConfiguration
    let onSave: (String, Bool) throws -> Void

    @State private var label: String
    @State private var isEnabled: Bool
    @State private var errorMessage: String?
    @FocusState private var isLabelFocused: Bool

    init(
        configuration: MobileAccountEditorConfiguration,
        onSave: @escaping (String, Bool) throws -> Void
    ) {
        self.configuration = configuration
        self.onSave = onSave
        self._label = State(initialValue: configuration.account?.label ?? "")
        self._isEnabled = State(
            initialValue: configuration.account?.isEnabled ?? true
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Text(configuration.provider.displayName)
                }
                Section("Account") {
                    TextField("Account name", text: $label)
                        .textContentType(.name)
                        .autocorrectionDisabled()
                        .focused($isLabelFocused)
                        .accessibilityIdentifier("mobile.accountNameField")
                    Toggle("Refresh when the app is active", isOn: $isEnabled)
                }
            }
            .navigationTitle(configuration.account == nil ? "Add Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
                    }
                    .disabled(trimmedLabel.isEmpty)
                    .accessibilityIdentifier("mobile.saveAccount")
                }
            }
            .alert(
                "Account",
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
        .presentationDetents([.medium])
        .onAppear {
            #if DEBUG
            if configuration.account == nil,
               MobileAppRuntime.isUITesting() {
                isLabelFocused = true
            }
            #endif
        }
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func save() {
        do {
            try onSave(trimmedLabel, isEnabled)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
