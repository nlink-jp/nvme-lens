import Foundation

/// Thresholds and retention, with defaults chosen from measurement rather than
/// from round numbers.
///
/// A plain value: the application owns these and stores them itself. They decide
/// when to notify, and the application is the only thing that notifies.
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
        public var temperatureRetentionDays: Int = 90
    }

    public var temperature = Temperature()
    public var endurance = Endurance()
    public var anomaly = Anomaly()
    public var sampling = Sampling()

    public init() {}

}
