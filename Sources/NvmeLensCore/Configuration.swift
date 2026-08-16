import Foundation

/// Thresholds and intervals, with defaults chosen from measurement rather than
/// from round numbers.
public struct Configuration: Equatable, Sendable {
    public struct Temperature: Equatable, Sendable {
        /// Hotspot threshold in Celsius.
        ///
        /// A measured drive idles with its hotspot at 69 °C, so a naive "warn at
        /// 70" fires forever. 78 sits above idle and below the 84 °C composite
        /// warning threshold typical of these drives.
        public var warningCelsius: Int = 78
        public var criticalCelsius: Int = 83
        /// How long the hotspot must stay above the threshold before alerting.
        /// Sustained heat is what throttles and ages a drive; a transient peak
        /// during a file copy is not worth waking anyone for.
        public var sustainedMinutes: Int = 5
        public var enabled: Bool = true
    }

    public struct Endurance: Equatable, Sendable {
        /// Alert when Percentage Used reaches this.
        public var percentageUsedWarning: Int = 80
        /// Alert when Available Spare drops to within this many points of the
        /// drive's own Available Spare Threshold.
        public var spareMarginPoints: Int = 5
        public var enabled: Bool = true
    }

    public struct Anomaly: Equatable, Sendable {
        /// Power cycles per powered hour above which the enclosure or power
        /// management is suspect. Measured: a USB enclosure drove 7.3 cycles per
        /// hour through disk sleep; the same drive on Thunderbolt does 0.
        public var powerCyclesPerHourWarning: Double = 2.0
        /// Any increase in media errors alerts; this only gates the check.
        public var mediaErrorsEnabled: Bool = true
        public var enabled: Bool = true
    }

    public struct Sampling: Equatable, Sendable {
        public var temperatureIntervalSeconds: Int = 60
        public var wearIntervalSeconds: Int = 3600
        public var temperatureRetentionDays: Int = 90
    }

    public var temperature = Temperature()
    public var endurance = Endurance()
    public var anomaly = Anomaly()
    public var sampling = Sampling()

    public init() {}

    /// Default location. macOS applications are expected to look in
    /// `~/.config` too, not only in Application Support.
    public static var defaultPath: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/nvme-lens/config.toml")
    }

    /// Reads a config file. A missing file is not an error — defaults apply.
    /// A malformed file *is* an error: silently falling back to defaults would
    /// mean the operator's thresholds stopped applying without anyone saying so.
    public static func load(from url: URL = Configuration.defaultPath) throws -> Configuration {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return Configuration()
        }
        return try Configuration(toml: text)
    }

    public init(toml text: String) throws {
        self.init()
        let table = try TOMLLite.parse(text)

        if let section = table["temperature"] {
            temperature.warningCelsius = section["warning_celsius"]?.integerValue
                ?? temperature.warningCelsius
            temperature.criticalCelsius = section["critical_celsius"]?.integerValue
                ?? temperature.criticalCelsius
            temperature.sustainedMinutes = section["sustained_minutes"]?.integerValue
                ?? temperature.sustainedMinutes
            temperature.enabled = section["enabled"]?.booleanValue ?? temperature.enabled
        }
        if let section = table["endurance"] {
            endurance.percentageUsedWarning = section["percentage_used_warning"]?.integerValue
                ?? endurance.percentageUsedWarning
            endurance.spareMarginPoints = section["spare_margin_points"]?.integerValue
                ?? endurance.spareMarginPoints
            endurance.enabled = section["enabled"]?.booleanValue ?? endurance.enabled
        }
        if let section = table["anomaly"] {
            if let value = section["power_cycles_per_hour_warning"]?.integerValue {
                anomaly.powerCyclesPerHourWarning = Double(value)
            }
            anomaly.mediaErrorsEnabled = section["media_errors_enabled"]?.booleanValue
                ?? anomaly.mediaErrorsEnabled
            anomaly.enabled = section["enabled"]?.booleanValue ?? anomaly.enabled
        }
        if let section = table["sampling"] {
            sampling.temperatureIntervalSeconds = section["temperature_interval_seconds"]?
                .integerValue ?? sampling.temperatureIntervalSeconds
            sampling.wearIntervalSeconds = section["wear_interval_seconds"]?.integerValue
                ?? sampling.wearIntervalSeconds
            sampling.temperatureRetentionDays = section["temperature_retention_days"]?.integerValue
                ?? sampling.temperatureRetentionDays
        }
    }
}
