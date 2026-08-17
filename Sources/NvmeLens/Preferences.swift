import AppKit
import Foundation
import NvmeLensCore

/// Every setting the tool has.
///
/// There is no configuration file. Thresholds decide when to *notify*, and the
/// resident application is the only thing that notifies; sampling cadence and
/// retention are its lifecycle. None of it binds the command line, which records
/// one sample per invocation and reads back what was recorded. A shared file
/// existed only because the command line was written before the application was,
/// and it turned every threshold into a row the settings window could show but
/// not change.
@MainActor
final class Preferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    // MARK: - Menu bar selection

    private static let selectionKey = "menuBarDrives"

    var menuBarDrives: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.selectionKey) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Self.selectionKey) }
    }

    // MARK: - Sampling interval

    private static let intervalKey = "samplingIntervalSeconds"

    /// The choices offered. A bounded picker rather than a free number field:
    /// every value here is one the tool actually behaves sensibly at, and the
    /// list documents the trade-off without prose.
    static let intervalChoices = [30, 60, 120, 300, 600]
    static let defaultInterval = 60

    var samplingIntervalSeconds: Int {
        get {
            let stored = defaults.integer(forKey: Self.intervalKey)
            return Self.intervalChoices.contains(stored) ? stored : Self.defaultInterval
        }
        set { defaults.set(newValue, forKey: Self.intervalKey) }
    }

    static func intervalLabel(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) seconds" : "\(seconds / 60) minute\(seconds == 60 ? "" : "s")"
    }

    // MARK: - Notifications

    private static let notificationsKey = "notificationsEnabled"

    /// Defaults to on. The application exists to tell you when a drive is in
    /// trouble; shipping that switched off would make the first alert arrive
    /// only in a panel nobody had open.
    var notificationsEnabled: Bool {
        get { defaults.object(forKey: Self.notificationsKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.notificationsKey) }
    }

    // MARK: - Alerting and retention

    private enum Key {
        static let warning = "temperatureWarningCelsius"
        static let critical = "temperatureCriticalCelsius"
        static let sustained = "temperatureSustainedMinutes"
        static let usedWarning = "endurancePercentageUsedWarning"
        static let spareMargin = "enduranceSpareMarginPoints"
        static let cycleRate = "anomalyPowerCyclesPerHour"
        static let retention = "temperatureRetentionDays"
    }

    static let retentionChoices = [30, 60, 90, 180, 365]

    private func int(_ key: String, default fallback: Int) -> Int {
        defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key)
    }

    /// Assembled from the stored values, with the measured defaults behind them.
    var configuration: Configuration {
        var config = Configuration()
        config.temperature.warningCelsius = int(
            Key.warning, default: config.temperature.warningCelsius)
        config.temperature.criticalCelsius = int(
            Key.critical, default: config.temperature.criticalCelsius)
        config.temperature.sustainedMinutes = int(
            Key.sustained, default: config.temperature.sustainedMinutes)
        config.endurance.percentageUsedWarning = int(
            Key.usedWarning, default: config.endurance.percentageUsedWarning)
        config.endurance.spareMarginPoints = int(
            Key.spareMargin, default: config.endurance.spareMarginPoints)
        config.anomaly.powerCyclesPerHourWarning = Double(
            int(Key.cycleRate, default: Int(config.anomaly.powerCyclesPerHourWarning)))
        config.sampling.temperatureRetentionDays = int(
            Key.retention, default: config.sampling.temperatureRetentionDays)
        return config
    }

    var temperatureWarning: Int {
        get { configuration.temperature.warningCelsius }
        set { defaults.set(newValue, forKey: Key.warning) }
    }
    var temperatureCritical: Int {
        get { configuration.temperature.criticalCelsius }
        set { defaults.set(newValue, forKey: Key.critical) }
    }
    var sustainedMinutes: Int {
        get { configuration.temperature.sustainedMinutes }
        set { defaults.set(newValue, forKey: Key.sustained) }
    }
    var percentageUsedWarning: Int {
        get { configuration.endurance.percentageUsedWarning }
        set { defaults.set(newValue, forKey: Key.usedWarning) }
    }
    var powerCyclesPerHour: Int {
        get { Int(configuration.anomaly.powerCyclesPerHourWarning) }
        set { defaults.set(newValue, forKey: Key.cycleRate) }
    }
    var retentionDays: Int {
        get { configuration.sampling.temperatureRetentionDays }
        set { defaults.set(newValue, forKey: Key.retention) }
    }

    func resetAlerting() {
        for key in [
            Key.warning, Key.critical, Key.sustained, Key.usedWarning, Key.spareMargin,
            Key.cycleRate, Key.retention,
        ] {
            defaults.removeObject(forKey: key)
        }
    }
}

