import NvmeLensCore
import SwiftUI

/// A separate window, not a sheet and not a menu section. Settings that lived in
/// the menu read as bolted on, because a menu is a list of commands and these
/// are persistent choices.
struct SettingsView: View {
    @ObservedObject var model: AppModel

    // Bounded choices rather than free number fields: every value offered is one
    // the tool behaves sensibly at, and the list documents the range without
    // prose. The defaults come from measurement (a drive idling at 69°C).
    static let warningChoices = [70, 74, 78, 80, 82]
    static let criticalChoices = [80, 83, 85, 88, 90]
    static let minuteChoices = [1, 3, 5, 10, 15]
    static let usedChoices = [50, 70, 80, 90, 95]
    static let cycleChoices = [1, 2, 5, 10]

    /// Writes through to preferences and re-evaluates at once, so the effect of
    /// a change is visible without waiting for the next sample.
    private func binding(
        _ keyPath: ReferenceWritableKeyPath<Preferences, Int>, choices: [Int]
    ) -> Binding<Int> {
        Binding(
            get: {
                let value = model.preferences[keyPath: keyPath]
                return choices.contains(value) ? value : (choices.first ?? value)
            },
            set: {
                model.preferences[keyPath: keyPath] = $0
                model.alertingChanged()
            })
    }

    var body: some View {
        Form {
            Section("Menu bar") {
                if model.presentation.drives.isEmpty {
                    Text("No monitorable drive detected.").foregroundStyle(.secondary)
                }
                ForEach(model.presentation.drives, id: \.serialNumber) { drive in
                    Toggle(
                        isOn: Binding(
                            get: { drive.isShownInMenuBar },
                            set: { _ in model.toggleWatched(drive.serialNumber) })
                    ) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(drive.name)
                            Text(drive.serialNumber).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(
                    "Pinned drives show their temperature in the menu bar and their history in the panel. With none pinned, the hottest drive is shown."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            // Listed here rather than in the panel. Someone whose drive is
            // missing looks for it in settings; putting it in the glance view
            // spent a third of that view explaining what the tool cannot do.
            if !model.presentation.unmonitorable.isEmpty {
                Section("Detected but not monitored") {
                    ForEach(model.presentation.unmonitorable, id: \.name) { entry in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name)
                            Text(entry.fullReason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Startup") {
                Toggle(
                    isOn: Binding(
                        get: { model.loginItem.isOn },
                        set: { model.setLoginItem(enabled: $0) })
                ) {
                    Text(model.loginItem.title)
                }
                // Never disabled, whatever the status reports: an ambiguous
                // status must not remove the only control that would resolve it.
                .disabled(!model.loginItem.isControlEnabled)

                if let note = model.loginItem.note {
                    Label(note, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = model.loginItemMessage {
                    // Shown in the window the action was taken in, not somewhere
                    // else where it would look like nothing happened.
                    Label(message, systemImage: "xmark.octagon.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                Text(
                    "This application is the collector. Without opening at login, the history has a gap after every restart."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("Notifications") {
                Toggle(
                    isOn: Binding(
                        get: { model.notificationsEnabled },
                        set: { model.setNotifications(enabled: $0) })
                ) {
                    Text("Notify on alerts")
                }
                if let problem = model.notificationProblem {
                    // Says what the system actually answered, rather than
                    // letting a switch reading "on" promise a delivery that
                    // will not happen.
                    HStack {
                        Label(problem, systemImage: "bell.slash")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Settings") { model.openNotificationSettings() }
                            .controlSize(.small)
                    }
                }
                Text("Permission is asked for when this is switched on, not when the first alert happens — otherwise the app never appears in the system's notification list.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sampling") {
                Picker(
                    "Sample every",
                    selection: Binding(
                        get: { model.samplingIntervalSeconds },
                        set: { model.samplingIntervalSeconds = $0 })
                ) {
                    ForEach(Preferences.intervalChoices, id: \.self) { seconds in
                        Text(Preferences.intervalLabel(seconds)).tag(seconds)
                    }
                }
                Text("Takes effect immediately; no restart.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Alerting") {
                Picker(
                    "Warn above",
                    selection: binding(\.temperatureWarning, choices: Self.warningChoices)
                ) {
                    ForEach(Self.warningChoices, id: \.self) { Text("\($0)°C").tag($0) }
                }
                Picker(
                    "Critical above",
                    selection: binding(\.temperatureCritical, choices: Self.criticalChoices)
                ) {
                    ForEach(Self.criticalChoices, id: \.self) { Text("\($0)°C").tag($0) }
                }
                Picker(
                    "Sustained for", selection: binding(\.sustainedMinutes, choices: Self.minuteChoices)
                ) {
                    ForEach(Self.minuteChoices, id: \.self) { Text("\($0) min").tag($0) }
                }
                Text(
                    "Judged on the hottest sensor, not the composite value, and only once the heat persists — a spike during a file copy stays quiet."
                )
                .font(.caption).foregroundStyle(.secondary)

                Picker(
                    "Warn when used reaches",
                    selection: binding(\.percentageUsedWarning, choices: Self.usedChoices)
                ) {
                    ForEach(Self.usedChoices, id: \.self) { Text("\($0)%").tag($0) }
                }
                Picker(
                    "Power cycles above",
                    selection: binding(\.powerCyclesPerHour, choices: Self.cycleChoices)
                ) {
                    ForEach(Self.cycleChoices, id: \.self) { Text("\($0) per hour").tag($0) }
                }
                Text(
                    "A USB enclosure was measured driving 7.3 power cycles an hour through disk sleep; the same drive on Thunderbolt does none."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            Section("History") {
                Picker(
                    "Keep temperature for",
                    selection: binding(\.retentionDays, choices: Preferences.retentionChoices)
                ) {
                    ForEach(Preferences.retentionChoices, id: \.self) { Text("\($0) days").tag($0) }
                }
                Text("Wear snapshots are kept indefinitely: they are small, and their long-term trend is the point.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Restore Defaults") {
                    model.preferences.resetAlerting()
                    model.alertingChanged()
                }
                .controlSize(.small)
            }

            Section {
                LabeledContent("Version", value: Version.current)
            }
        }
        .formStyle(.grouped)
        // A floor and an ideal rather than a fixed size: sections were added
        // after this window was first sized, and a hard height simply cropped
        // them. The form scrolls past the ideal, and the window resizes.
        .frame(minWidth: 460, idealWidth: 460, minHeight: 480, idealHeight: 720)
    }
}
