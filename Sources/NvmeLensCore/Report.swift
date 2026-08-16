import Foundation

/// The JSON shape emitted by `list` and `status`.
///
/// Kept flat and explicit so it pipes cleanly into json-to-table / data-analyzer
/// without the consumer needing to know NVMe.
public struct DriveReport: Codable, Equatable, Sendable {
    public struct Temperature: Codable, Equatable, Sendable {
        /// The value to judge on: the hottest implemented sensor, or composite
        /// when the drive implements no sensors.
        public var hotspotCelsius: Int
        /// True when `hotspotCelsius` came from composite for lack of sensors —
        /// stated rather than implied, so nobody reads it as sensor accuracy.
        public var hotspotFromCompositeOnly: Bool
        public var compositeCelsius: Int
        public var sensorsCelsius: [Int]
        public var warningThresholdCelsius: Int?
        public var criticalThresholdCelsius: Int?
        public var minutesAboveWarning: UInt32
        public var minutesAboveCritical: UInt32
    }

    public struct Endurance: Codable, Equatable, Sendable {
        public var percentageUsed: UInt8
        public var availableSparePercent: UInt8
        public var availableSpareThresholdPercent: UInt8
        public var dataUnitsWritten: UInt64
        public var bytesWritten: UInt64
        public var dataUnitsRead: UInt64
        public var bytesRead: UInt64
        public var powerOnHours: UInt64
        public var powerCycles: UInt64
        public var unsafeShutdowns: UInt64
        public var mediaAndDataIntegrityErrors: UInt64
        public var errorInformationLogEntries: UInt64
        public var criticalWarning: UInt8
    }

    public var serialNumber: String
    public var model: String
    public var firmware: String?
    public var bsdName: String
    public var interconnect: String
    public var location: String
    public var monitored: Bool
    /// Present only when `monitored` is false. Names the cause and, where one
    /// exists, the remedy.
    public var unmonitorableReason: String?
    public var temperature: Temperature?
    public var endurance: Endurance?

    public init(record: DriveRecord) {
        serialNumber = record.serialNumber
        model = record.displayName
        firmware = record.identity?.firmwareRevision
        bsdName = record.descriptor.bsdName
        interconnect = record.descriptor.physicalInterconnect
        location = record.descriptor.physicalInterconnectLocation

        switch record.state {
        case .monitored:
            monitored = true
            unmonitorableReason = nil
        case .unmonitorable(let reason):
            monitored = false
            unmonitorableReason = reason.explanation
        }

        if let health = record.health {
            temperature = Temperature(
                hotspotCelsius: health.hotspotCelsius,
                hotspotFromCompositeOnly: health.hotspotIsCompositeOnly,
                compositeCelsius: health.compositeCelsius,
                sensorsCelsius: health.sensorsCelsius,
                warningThresholdCelsius: record.identity?.warningTemperatureCelsius,
                criticalThresholdCelsius: record.identity?.criticalTemperatureCelsius,
                minutesAboveWarning: health.warningCompositeTemperatureMinutes,
                minutesAboveCritical: health.criticalCompositeTemperatureMinutes
            )
            endurance = Endurance(
                percentageUsed: health.percentageUsed,
                availableSparePercent: health.availableSparePercent,
                availableSpareThresholdPercent: health.availableSpareThresholdPercent,
                dataUnitsWritten: health.dataUnitsWritten,
                bytesWritten: SmartHealth.bytes(fromDataUnits: health.dataUnitsWritten),
                dataUnitsRead: health.dataUnitsRead,
                bytesRead: SmartHealth.bytes(fromDataUnits: health.dataUnitsRead),
                powerOnHours: health.powerOnHours,
                powerCycles: health.powerCycles,
                unsafeShutdowns: health.unsafeShutdowns,
                mediaAndDataIntegrityErrors: health.mediaAndDataIntegrityErrors,
                errorInformationLogEntries: health.errorInformationLogEntries,
                criticalWarning: health.criticalWarning
            )
        }
    }
}

public enum Renderer {
    public static func json(_ reports: [DriveReport]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(reports), as: UTF8.self)
    }

    public static func table(_ reports: [DriveReport]) -> String {
        guard !reports.isEmpty else { return "no drives found" }
        var lines: [String] = []
        for report in reports {
            lines.append("\(report.model)  [\(report.bsdName)]")
            lines.append("  serial       \(report.serialNumber)")
            lines.append("  interconnect \(report.interconnect) (\(report.location))")
            if let reason = report.unmonitorableReason {
                lines.append("  status       NOT MONITORED — \(reason)")
            } else if let temp = report.temperature, let wear = report.endurance {
                let sensors =
                    temp.sensorsCelsius.isEmpty
                    ? "none implemented (composite only)"
                    : temp.sensorsCelsius.map { "\($0)C" }.joined(separator: " ")
                lines.append(
                    "  temperature  hotspot \(temp.hotspotCelsius)C  composite \(temp.compositeCelsius)C"
                )
                lines.append("  sensors      \(sensors)")
                if let warning = temp.warningThresholdCelsius {
                    lines.append(
                        "  thresholds   warning \(warning)C (composite)  above-warning \(temp.minutesAboveWarning) min"
                    )
                }
                lines.append(
                    "  endurance    used \(wear.percentageUsed)%  spare \(wear.availableSparePercent)% (min \(wear.availableSpareThresholdPercent)%)"
                )
                lines.append(
                    "  written      \(format(bytes: wear.bytesWritten))  read \(format(bytes: wear.bytesRead))"
                )
                lines.append(
                    "  power        \(wear.powerOnHours) h  \(wear.powerCycles) cycles  \(wear.unsafeShutdowns) unsafe"
                )
                lines.append(
                    "  errors       media \(wear.mediaAndDataIntegrityErrors)  log \(wear.errorInformationLogEntries)  critical-warning 0x\(String(format: "%02x", wear.criticalWarning))"
                )
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    static func format(bytes: UInt64) -> String {
        let terabytes = Double(bytes) / 1_000_000_000_000
        if terabytes >= 1 { return String(format: "%.2f TB", terabytes) }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
