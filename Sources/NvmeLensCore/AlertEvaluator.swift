import Foundation

public enum AlertSeverity: String, Equatable, Sendable, Codable {
    case warning
    case critical
}

public struct Alert: Equatable, Sendable, Codable {
    public var serialNumber: String
    public var model: String
    public var severity: AlertSeverity
    public var kind: String
    public var message: String
}

/// One temperature observation, as stored.
public struct TemperaturePoint: Equatable, Sendable {
    public var timestamp: Date
    public var hotspotCelsius: Int
    public init(timestamp: Date, hotspotCelsius: Int) {
        self.timestamp = timestamp
        self.hotspotCelsius = hotspotCelsius
    }
}

/// The previous wear snapshot for a drive, used to detect movement.
public struct WearBaseline: Equatable, Sendable {
    public var timestamp: Date
    public var percentageUsed: UInt8
    public var mediaErrors: UInt64
    public var powerCycles: UInt64
    public var powerOnHours: UInt64
    public var unsafeShutdowns: UInt64

    public init(
        timestamp: Date, percentageUsed: UInt8, mediaErrors: UInt64, powerCycles: UInt64,
        powerOnHours: UInt64, unsafeShutdowns: UInt64
    ) {
        self.timestamp = timestamp
        self.percentageUsed = percentageUsed
        self.mediaErrors = mediaErrors
        self.powerCycles = powerCycles
        self.powerOnHours = powerOnHours
        self.unsafeShutdowns = unsafeShutdowns
    }
}

/// Decides what deserves a notification.
///
/// Pure by construction: it is handed the current reading, the recent
/// temperature history, and the previous wear snapshot, and returns alerts. No
/// clock, no store, no device — so every rule can be tested directly.
public enum AlertEvaluator {
    public static func evaluate(
        record: DriveRecord,
        now: Date,
        temperatureHistory: [TemperaturePoint],
        wearBaseline: WearBaseline?,
        configuration: Configuration
    ) -> [Alert] {
        guard let health = record.health, record.state.isMonitored else { return [] }
        let baseline = wearBaseline
        var alerts: [Alert] = []

        func alert(_ severity: AlertSeverity, _ kind: String, _ message: String) {
            alerts.append(
                Alert(
                    serialNumber: record.serialNumber, model: record.displayName,
                    severity: severity, kind: kind, message: message))
        }

        // 1. Temperature: sustained, not instantaneous.
        if configuration.temperature.enabled {
            let hotspot = health.hotspotCelsius
            let sustained = sustainedSeconds(
                history: temperatureHistory, now: now, atOrAbove: configuration.temperature.criticalCelsius)
            let requiredSeconds = configuration.temperature.sustainedMinutes * 60

            if hotspot >= configuration.temperature.criticalCelsius && sustained >= requiredSeconds {
                alert(
                    .critical, "temperature",
                    "hotspot \(hotspot)C has been at or above \(configuration.temperature.criticalCelsius)C for \(sustained / 60) min"
                )
            } else {
                let warmSustained = sustainedSeconds(
                    history: temperatureHistory, now: now,
                    atOrAbove: configuration.temperature.warningCelsius)
                if hotspot >= configuration.temperature.warningCelsius
                    && warmSustained >= requiredSeconds
                {
                    alert(
                        .warning, "temperature",
                        "hotspot \(hotspot)C has been at or above \(configuration.temperature.warningCelsius)C for \(warmSustained / 60) min"
                    )
                }
            }
        }

        // 2. Endurance.
        if configuration.endurance.enabled {
            if Int(health.percentageUsed) >= configuration.endurance.percentageUsedWarning {
                alert(
                    .warning, "endurance",
                    "percentage used is \(health.percentageUsed)% (threshold \(configuration.endurance.percentageUsedWarning)%)"
                )
            }
            let margin =
                Int(health.availableSparePercent) - Int(health.availableSpareThresholdPercent)
            if health.availableSparePercent <= health.availableSpareThresholdPercent {
                alert(
                    .critical, "endurance",
                    "available spare \(health.availableSparePercent)% has reached the drive's own threshold (\(health.availableSpareThresholdPercent)%)"
                )
            } else if health.availableSparePercent < 100
                && margin <= configuration.endurance.spareMarginPoints
            {
                // The `< 100` guard is not cosmetic. Available Spare Threshold is
                // whatever the vendor chose: 5% on one measured drive, 10% on
                // another, and 99% on Apple's internal SSD. On that last one a
                // bare margin test fires while spare is still full and nothing
                // is wrong, so depletion must actually have started before
                // proximity means anything.
                alert(
                    .warning, "endurance",
                    "available spare \(health.availableSparePercent)% is within \(margin) point(s) of the drive's own threshold (\(health.availableSpareThresholdPercent)%)"
                )
            }
            if let baseline, baseline.percentageUsed < health.percentageUsed {
                alert(
                    .warning, "endurance",
                    "percentage used rose from \(baseline.percentageUsed)% to \(health.percentageUsed)%"
                )
            }
        }

        // 3. Media errors: the increment itself is the event, so no threshold.
        if configuration.anomaly.enabled && configuration.anomaly.mediaErrorsEnabled {
            if let baseline, health.mediaAndDataIntegrityErrors > baseline.mediaErrors {
                let delta = health.mediaAndDataIntegrityErrors - baseline.mediaErrors
                alert(
                    .critical, "media-error",
                    "media and data integrity errors increased by \(delta) (now \(health.mediaAndDataIntegrityErrors))"
                )
            }
        }

        // 4. Power-cycle rate. Exposes an enclosure or power-management problem
        //    that no other indicator surfaces.
        if configuration.anomaly.enabled, let baseline {
            let cycleDelta = health.powerCycles &- baseline.powerCycles
            let hourDelta = health.powerOnHours &- baseline.powerOnHours
            if cycleDelta > 0 && hourDelta > 0 {
                let rate = Double(cycleDelta) / Double(hourDelta)
                if rate >= configuration.anomaly.powerCyclesPerHourWarning {
                    alert(
                        .warning, "power-cycle",
                        String(
                            format:
                                "%.1f power cycles per powered hour (%llu cycles over %llu h) — the enclosure or power management may be cycling the drive",
                            rate, cycleDelta, hourDelta))
                }
            }
            if health.unsafeShutdowns > baseline.unsafeShutdowns {
                let delta = health.unsafeShutdowns - baseline.unsafeShutdowns
                alert(
                    .warning, "power-cycle",
                    "unsafe shutdowns increased by \(delta) (now \(health.unsafeShutdowns))")
            }
        }

        return alerts
    }

    /// How long the hotspot has been continuously at or above `threshold`,
    /// looking backwards from `now`. Returns 0 if the most recent point is below
    /// it, so a drive that just cooled does not keep alerting.
    public static func sustainedSeconds(
        history: [TemperaturePoint], now: Date, atOrAbove threshold: Int
    ) -> Int {
        let ordered = history.sorted { $0.timestamp < $1.timestamp }
        guard let last = ordered.last, last.hotspotCelsius >= threshold else { return 0 }

        var start = last.timestamp
        for point in ordered.reversed() {
            if point.hotspotCelsius >= threshold {
                start = point.timestamp
            } else {
                break
            }
        }
        return max(0, Int(now.timeIntervalSince(start)))
    }
}
