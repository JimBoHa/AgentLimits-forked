// MARK: - CLICommandSettingsView.swift
// Detailed settings for overriding CLI command full paths.

import SwiftUI

@MainActor
struct CLICommandSettingsView: View {
    @AppStorage(
        CLICommandPathKeys.codex,
        store: AppGroupDefaults.shared
    ) private var codexCommandPathText: String = ""

    @AppStorage(
        CLICommandPathKeys.claude,
        store: AppGroupDefaults.shared
    ) private var claudeCommandPathText: String = ""

    @AppStorage(
        CLICommandPathKeys.ccusage,
        store: AppGroupDefaults.shared
    ) private var ccusageCommandPathText: String = ""

    @State private var resolvedPaths: [CLICommandKind: String] = [:]
    @State private var scriptCopyFeedback: Bool = false
    @State private var widgetTapAction: WidgetTapAction = WidgetTapActionStore.loadAction()
    @AppStorage(
        UserDefaultsKeys.menuBarIconHidden,
        store: AppDefaults.shared
    ) private var menuBarIconHidden = false

    private var statusLineScriptPath: String? {
        Bundle.main.path(forResource: "agentlimits_statusline_claude", ofType: "sh")
    }

    var body: some View {
        Form {
            SettingsFormSection(title: "cliPaths.sectionTitle".localized(),
                                footerText: "cliPaths.note".localized()) {
                commandPathSection
            }

            SettingsFormSection(title: "scripts.title".localized(),
                                footerText: "scripts.claudeCode.note".localized()) {
                scriptsSection
            }

            SettingsFormSection(title: "widgetTapAction.title".localized(),
                                footerText: "widgetTapAction.note".localized()) {
                widgetTapActionSection
            }

            SettingsFormSection(title: "settings.menuBar.sectionTitle".localized(),
                                footerText: "settings.hideMenuBarIcon.hint".localized()) {
                menuBarIconSection
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshAllResolvedPaths() }
        .onChange(of: codexCommandPathText) { refreshResolvedPath(for: .codex) }
        .onChange(of: claudeCommandPathText) { refreshResolvedPath(for: .claude) }
        .onChange(of: ccusageCommandPathText) { refreshResolvedPath(for: .ccusage) }
        .accessibilityIdentifier("mac.advanced.root")
    }

    private struct CommandPathDescriptor: Identifiable {
        let kind: CLICommandKind
        let titleKey: String
        let placeholderKey: String

        var id: String { kind.rawValue }
    }

    private var commandPathDescriptors: [CommandPathDescriptor] {
        [
            CommandPathDescriptor(
                kind: .codex,
                titleKey: "cliPaths.codex",
                placeholderKey: "cliPaths.codex.placeholder"
            ),
            CommandPathDescriptor(
                kind: .claude,
                titleKey: "cliPaths.claude",
                placeholderKey: "cliPaths.claude.placeholder"
            ),
            CommandPathDescriptor(
                kind: .ccusage,
                titleKey: "cliPaths.ccusage",
                placeholderKey: "cliPaths.ccusage.placeholder"
            )
        ]
    }

    private var commandPathSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            ForEach(Array(commandPathDescriptors.enumerated()), id: \.element.id) { index, descriptor in
                if index > 0 {
                    Divider()
                }
                CommandPathRow(
                    title: descriptor.titleKey.localized(),
                    placeholder: descriptor.placeholderKey.localized(),
                    commandPathText: makeCommandPathBinding(for: descriptor.kind),
                    resolvedPathText: makeResolvedPathText(for: descriptor.kind),
                    isResolved: isResolvedPath(for: descriptor.kind)
                )
            }
        }
    }

    private var scriptsSection: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.small) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                Text("scripts.claudeCode.title".localized())
                    .font(.body)
                if let path = statusLineScriptPath {
                    Text(path)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("scripts.notFound".localized())
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if statusLineScriptPath != nil {
                Button {
                    copyScriptPath()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: scriptCopyFeedback ? "checkmark" : "doc.on.doc")
                        Text(scriptCopyFeedback ? "scripts.copied".localized() : "scripts.copy".localized())
                    }
                }
                .settingsButtonStyle(.secondary)
            }
        }
    }

    private var menuBarIconSection: some View {
        Toggle("settings.hideMenuBarIcon".localized(), isOn: $menuBarIconHidden)
            .toggleStyle(.checkbox)
    }

    private var widgetTapActionSection: some View {
        Picker("", selection: $widgetTapAction) {
            ForEach(WidgetTapAction.allCases) { action in
                Text(action.localizationKey.localized()).tag(action)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .onChange(of: widgetTapAction) { _, newValue in
            WidgetTapActionStore.saveAction(newValue)
        }
    }

    private func copyScriptPath() {
        guard let path = statusLineScriptPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        scriptCopyFeedback = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            scriptCopyFeedback = false
        }
    }

    private func makeResolvedPathText(for kind: CLICommandKind) -> String {
        resolvedPaths[kind] ?? "cliPaths.notFound".localized()
    }

    private func isResolvedPath(for kind: CLICommandKind) -> Bool {
        resolvedPaths[kind] != nil
    }

    private func refreshAllResolvedPaths() {
        for descriptor in commandPathDescriptors {
            refreshResolvedPath(for: descriptor.kind)
        }
    }

    private func refreshResolvedPath(for kind: CLICommandKind) {
#if DEBUG
        guard !AppRuntimeEnvironment.isUITesting else {
            resolvedPaths.removeValue(forKey: kind)
            return
        }
#endif
        let trimmedOverride = CLICommandPathValidator.normalizeOverridePath(
            loadOverrideText(for: kind)
        )
        Task {
            let resolvedPath: String?
            if let trimmedOverride {
                resolvedPath = CLICommandPathValidator.isExecutablePathValid(trimmedOverride)
                    ? trimmedOverride
                    : nil
            } else {
                resolvedPath = await CLICommandPathResolver.resolveExecutablePath(for: kind)
            }
            await MainActor.run {
                resolvedPaths[kind] = resolvedPath
            }
        }
    }

    private func loadOverrideText(for kind: CLICommandKind) -> String {
        switch kind {
        case .codex:
            return codexCommandPathText
        case .claude:
            return claudeCommandPathText
        case .ccusage:
            return ccusageCommandPathText
        }
    }

    private func makeCommandPathBinding(for kind: CLICommandKind) -> Binding<String> {
        switch kind {
        case .codex:
            return $codexCommandPathText
        case .claude:
            return $claudeCommandPathText
        case .ccusage:
            return $ccusageCommandPathText
        }
    }

}

private struct CommandPathRow: View {
    let title: String
    let placeholder: String
    @Binding var commandPathText: String
    let resolvedPathText: String
    let isResolved: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            LabeledContent(title) {
                TextField(
                    "",
                    text: $commandPathText,
                    prompt: Text(placeholder)
                )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(title))
            }

            HStack(spacing: DesignTokens.Spacing.small) {
                SettingsStatusIndicator(
                    text: "cliPaths.resolvedLabel".localized(),
                    level: isResolved ? .success : .error
                )
                Text(resolvedPathText)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
            }
        }
    }
}

#Preview {
    CLICommandSettingsView()
}
