// MARK: - WakeUpSettingsView.swift
// Settings UI for configuring wake-up schedules via LaunchAgent.
// Allows users to select hours for CLI execution and manage login items.

import SwiftUI

// MARK: - Wake Up Settings View

/// Settings view for configuring wake-up schedules
@MainActor
struct WakeUpSettingsView: View {
    @ObservedObject private var scheduler: WakeUpScheduler
    @State private var selectedProvider: UsageProvider = .chatgptCodex

    init(scheduler: WakeUpScheduler) {
        self.scheduler = scheduler
    }

    var body: some View {
        Form {
            SettingsFormSection {
                LabeledContent("wakeUp.provider".localized()) {
                    providerPicker
                }
            }

            SettingsFormSection(title: "wakeUp.schedule".localized()) {
                scheduleSection
            }

            SettingsFormSection(title: "wakeUp.status".localized()) {
                statusSection
                lastResultView
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Provider Picker

    private var providerPicker: some View {
        Picker("", selection: $selectedProvider) {
            ForEach(WakeUpScheduler.supportedProviders) { provider in
                Text(provider.displayName).tag(provider)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 260)
        .labelsHidden()
        .accessibilityLabel(Text("wakeUp.provider".localized()))
    }

    // MARK: - Schedule Section

    private var scheduleSection: some View {
        Group {
            if let schedule = scheduler.schedules[selectedProvider] {
                ProviderScheduleView(
                    schedule: schedule,
                    isTestRunning: scheduler.isTestRunning[selectedProvider] ?? false,
                    onEnabledChange: { newEnabled in
                        var updated = schedule
                        updated.isEnabled = newEnabled
                        scheduler.updateSchedule(updated)
                    },
                    onUpdate: { updatedSchedule in
                        // Use current isEnabled to avoid race condition with TextField
                        guard let current = scheduler.schedules[selectedProvider] else { return }
                        var merged = updatedSchedule
                        merged.isEnabled = current.isEnabled
                        scheduler.updateSchedule(merged)
                    },
                    onTestWakeUp: {
                        Task { await scheduler.triggerWakeUp(for: selectedProvider) }
                    }
                )
                .id(selectedProvider)
            }
        }
    }

    // MARK: - Status Section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
            ForEach(WakeUpScheduler.supportedProviders) { provider in
                providerStatusRow(for: provider)
            }
        }
    }

    private func providerStatusRow(for provider: UsageProvider) -> some View {
        HStack(spacing: DesignTokens.Spacing.small) {
            SettingsStatusIndicator(
                text: provider.displayName,
                level: statusLevel(for: provider)
            )
            Spacer()

            if let schedule = scheduler.schedules[provider],
               schedule.isEnabled,
               !schedule.enabledHours.isEmpty {
                Text(scheduleText(for: schedule))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("wakeUp.notScheduled".localized())
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var lastResultView: some View {
        Group {
            if let scheduleError = scheduler.scheduleErrors[selectedProvider] {
                HStack {
                    Text("wakeUp.lastResult".localized())
                        .font(.footnote)
                    Label(scheduleError.localizedDescription, systemImage: "xmark.circle.fill")
                        .foregroundColor(.red)
                        .font(.footnote)
                        .lineLimit(2)
                }
            } else if let result = scheduler.lastWakeUpResults[selectedProvider] {
                HStack {
                    Text("wakeUp.lastResult".localized())
                        .font(.footnote)
                    switch result {
                    case .success:
                        Label("wakeUp.success".localized(), systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.footnote)
                    case .failure(let error):
                        Label(error.localizedDescription, systemImage: "xmark.circle.fill")
                            .foregroundColor(.red)
                            .font(.footnote)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func statusLevel(for provider: UsageProvider) -> SettingsStatusLevel {
        // Gray when disabled/no hours, green when installed, orange when pending install.
        if scheduler.scheduleErrors[provider] != nil {
            return .error
        }
        guard let schedule = scheduler.schedules[provider],
              schedule.isEnabled,
              !schedule.enabledHours.isEmpty else {
            return .inactive
        }
        return scheduler.isLaunchAgentInstalled(for: provider) ? .success : .warning
    }

    private func scheduleText(for schedule: WakeUpSchedule) -> String {
        let hours = schedule.enabledHours.sorted()
        if hours.count <= 3 {
            // Show explicit hour list for small selections.
            return hours.map { "\($0):00" }.joined(separator: ", ")
        } else {
            // Fall back to count summary for large selections.
            return "\(hours.count) " + "wakeUp.hoursSelected".localized()
        }
    }
}

// MARK: - Provider Schedule View

struct WakeUpArgumentsDraft: Equatable {
    private(set) var text: String
    private(set) var validationMessage: String?

    init(committedValue: String) {
        self.text = committedValue
    }

    mutating func update(_ newValue: String) {
        text = newValue
        validationMessage = nil
    }

    mutating func validatedValue() -> String? {
        do {
            _ = try CLIArgumentParser.parse(text)
            validationMessage = nil
            return text
        } catch {
            validationMessage = error.localizedDescription
            return nil
        }
    }

    mutating func synchronize(with committedValue: String) {
        text = committedValue
        validationMessage = nil
    }

    func hasChanges(comparedTo committedValue: String) -> Bool {
        text != committedValue
    }
}

/// Schedule configuration for a single provider
private struct ProviderScheduleView: View {
    let schedule: WakeUpSchedule
    let isTestRunning: Bool
    let onEnabledChange: (Bool) -> Void
    let onUpdate: (WakeUpSchedule) -> Void
    let onTestWakeUp: () -> Void
    @State private var argumentsDraft: WakeUpArgumentsDraft

    init(
        schedule: WakeUpSchedule,
        isTestRunning: Bool,
        onEnabledChange: @escaping (Bool) -> Void,
        onUpdate: @escaping (WakeUpSchedule) -> Void,
        onTestWakeUp: @escaping () -> Void
    ) {
        self.schedule = schedule
        self.isTestRunning = isTestRunning
        self.onEnabledChange = onEnabledChange
        self.onUpdate = onUpdate
        self.onTestWakeUp = onTestWakeUp
        _argumentsDraft = State(
            initialValue: WakeUpArgumentsDraft(
                committedValue: schedule.additionalArgs
            )
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.medium) {
            Toggle("wakeUp.enabled".localized(), isOn: enabledBinding)

            if schedule.isEnabled {
                Text("wakeUp.selectHours".localized())
                    .font(.body)

                HourGridView(
                    selectedHours: schedule.enabledHours,
                    onToggle: { hour in
                        var newHours = schedule.enabledHours
                        if newHours.contains(hour) {
                            newHours.remove(hour)
                        } else {
                            newHours.insert(hour)
                        }
                        onUpdate(WakeUpSchedule(
                            provider: schedule.provider,
                            enabledHours: newHours,
                            isEnabled: schedule.isEnabled,
                            additionalArgs: schedule.additionalArgs
                        ))
                    }
                )

                LabeledContent("wakeUp.command".localized()) {
                    Text(schedule.cliCommand)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(DesignTokens.Spacing.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(DesignTokens.CornerRadius.small)
                        .textSelection(.enabled)
                }

                LabeledContent("wakeUp.additionalArgs".localized()) {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.small) {
                        HStack(spacing: DesignTokens.Spacing.small) {
                            TextField(
                                "",
                                text: additionalArgsBinding,
                                prompt: Text("wakeUp.additionalArgsPlaceholder".localized())
                            )
                            .textFieldStyle(.roundedBorder)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityLabel(Text("wakeUp.additionalArgs".localized()))
                            .onSubmit(applyAdditionalArgs)

                            Button("tab.update".localized(), action: applyAdditionalArgs)
                                .disabled(!argumentsDraft.hasChanges(
                                    comparedTo: schedule.additionalArgs
                                ))
                                .settingsButtonStyle(.secondary)
                        }

                        if let validationMessage = argumentsDraft.validationMessage {
                            Text(validationMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        Label(
                            "wakeUp.additionalArgsSecurityWarning".localized(),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(
                            "wakeup.additionalArgsSecurityWarning"
                        )
                    }
                }

                HStack(spacing: DesignTokens.Spacing.small) {
                    Text("wakeUp.selectedHours".localized())
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(selectedHoursText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: DesignTokens.Spacing.small) {
                    Button("wakeUp.testNow".localized()) {
                        onTestWakeUp()
                    }
                    .disabled(isTestRunning)
                    .settingsButtonStyle(.secondary)

                    if isTestRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
        }
        .onChange(of: schedule.additionalArgs) { _, newValue in
            argumentsDraft.synchronize(with: newValue)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { schedule.isEnabled },
            set: { newValue in
                onEnabledChange(newValue)
            }
        )
    }

    private var additionalArgsBinding: Binding<String> {
        Binding(
            get: { argumentsDraft.text },
            set: { newValue in
                argumentsDraft.update(newValue)
            }
        )
    }

    private func applyAdditionalArgs() {
        guard argumentsDraft.hasChanges(comparedTo: schedule.additionalArgs) else {
            return
        }
        guard let value = argumentsDraft.validatedValue() else { return }
        onUpdate(WakeUpSchedule(
            provider: schedule.provider,
            enabledHours: schedule.enabledHours,
            isEnabled: schedule.isEnabled,
            additionalArgs: value
        ))
    }

    private var selectedHoursText: String {
        if schedule.enabledHours.isEmpty {
            return "wakeUp.noHoursSelected".localized()
        }
        return schedule.enabledHours.sorted().map { "\($0):00" }.joined(separator: ", ")
    }
}

// MARK: - Hour Grid View

/// Grid for selecting hours (0-23)
private struct HourGridView: View {
    let selectedHours: Set<Int>
    let onToggle: (Int) -> Void

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 6)

    var body: some View {
        LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.small) {
            ForEach(0..<24, id: \.self) { hour in
                Button {
                    onToggle(hour)
                } label: {
                    Text(String(format: "%02d", hour))
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignTokens.Spacing.small)
                        .background(
                            selectedHours.contains(hour)
                                ? Color.accentColor
                                : Color.secondary.opacity(0.2)
                        )
                        .foregroundColor(
                            selectedHours.contains(hour) ? .white : .primary
                        )
                        .cornerRadius(DesignTokens.CornerRadius.small)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("wakeUp.hour".localized(hour)))
                .accessibilityValue(Text(selectedHours.contains(hour) ? "wakeUp.selected".localized() : "wakeUp.notSelected".localized()))
                .accessibilityAddTraits(selectedHours.contains(hour) ? .isSelected : [])
            }
        }
    }
}

// MARK: - Preview

#Preview {
    WakeUpSettingsView(scheduler: .shared)
}
