import Foundation

/// Everything the menu bar shows, derived from the current readings.
///
/// Pure, so the wording — the verdict, and especially the wording for the states
/// where the tool deliberately shows nothing — can be tested without launching
/// an application.
///
/// The shape is deliberately *not* a flat list of every field. A monitor answers
/// "is anything wrong?" first; the numbers are what you ask for afterwards, and
/// they live one level down.
public struct MenuBarPresentation: Equatable, Sendable {
    /// The status-item text: temperatures only. Severity is carried by the
    /// symbol beside it, not by punctuation glued onto the number — a colour is
    /// read at a glance where "!!" has to be decoded.
    public var title: String
    /// Worst severity across every monitored drive, or nil when all is well.
    public var overallSeverity: AlertSeverity?
    /// The single line at the top of the menu. A verdict, not a statistic.
    public var verdict: String
    public var drives: [DriveEntry]
    public var unmonitorable: [UnmonitorableEntry]

    public init(
        title: String, verdict: String, drives: [DriveEntry],
        unmonitorable: [UnmonitorableEntry], overallSeverity: AlertSeverity? = nil
    ) {
        self.title = title
        self.overallSeverity = overallSeverity
        self.verdict = verdict
        self.drives = drives
        self.unmonitorable = unmonitorable
    }

    public struct DetailRow: Equatable, Sendable {
        public var label: String
        public var value: String
    }

    public struct DetailSection: Equatable, Sendable {
        public var title: String
        public var rows: [DetailRow]
    }

    public struct DriveEntry: Equatable, Sendable {
        public var serialNumber: String
        public var name: String
        public var temperatureCelsius: Int
        /// Whether this drive's temperature appears in the menu bar itself.
        public var isShownInMenuBar: Bool
        public var severity: AlertSeverity?
        /// Shown only when the drive's row is opened.
        public var sections: [DetailSection]
        /// Alert messages for this drive, if any.
        public var alertMessages: [String]
    }

    public struct UnmonitorableEntry: Equatable, Sendable {
        public var name: String
        /// One short clause, not the full paragraph — the long form belongs in
        /// the README, not in a menu.
        public var shortReason: String
        public var fullReason: String
    }

    /// Collapsed summary line for the unmonitorable group.
    public var unmonitorableSummary: String? {
        guard !unmonitorable.isEmpty else { return nil }
        return unmonitorable.count == 1
            ? "1 drive not monitored" : "\(unmonitorable.count) drives not monitored"
    }

    public static func make(
        records: [DriveRecord],
        alerts: [Alert] = [],
        selectedSerials: Set<String> = [],
        configuration: Configuration = Configuration()
    ) -> MenuBarPresentation {
        var alertsBySerial: [String: [Alert]] = [:]
        for alert in alerts { alertsBySerial[alert.serialNumber, default: []].append(alert) }

        var drives: [DriveEntry] = []
        var unmonitorable: [UnmonitorableEntry] = []

        for record in records {
            switch record.state {
            case .monitored:
                guard let health = record.health else { continue }
                let driveAlerts = alertsBySerial[record.serialNumber] ?? []
                drives.append(
                    DriveEntry(
                        serialNumber: record.serialNumber,
                        name: record.displayName,
                        temperatureCelsius: health.hotspotCelsius,
                        isShownInMenuBar: selectedSerials.contains(record.serialNumber),
                        severity: driveAlerts.contains { $0.severity == .critical }
                            ? .critical : (driveAlerts.isEmpty ? nil : .warning),
                        sections: sections(for: record, health: health),
                        alertMessages: driveAlerts.map { "\($0.kind): \($0.message)" }))
            case .unmonitorable(let reason):
                unmonitorable.append(
                    UnmonitorableEntry(
                        name: record.displayName, shortReason: reason.shortLabel,
                        fullReason: reason.explanation))
            }
        }

        return MenuBarPresentation(
            title: title(drives: drives, alerts: alerts),
            verdict: verdict(drives: drives, unmonitorable: unmonitorable, alerts: alerts),
            drives: drives, unmonitorable: unmonitorable,
            overallSeverity: alerts.contains { $0.severity == .critical }
                ? .critical : (alerts.isEmpty ? nil : .warning))
    }

    // MARK: - Pieces

    static func title(drives: [DriveEntry], alerts: [Alert]) -> String {
        // Empty: the symbol alone says "nothing to report", and a placeholder
        // string beside it would only add noise.
        guard !drives.isEmpty else { return "" }

        // Whatever the user picked, in the order the drives are listed. With
        // nothing picked, fall back to the single hottest drive: a zero-config
        // default that is still meaningful.
        var shown = drives.filter(\.isShownInMenuBar)
        if shown.isEmpty, let hottest = drives.max(by: { $0.temperatureCelsius < $1.temperatureCelsius }) {
            shown = [hottest]
        }

        // "71°" alone reads as an angle in a menu bar. The unit costs about
        // eight points per drive and removes the ambiguity.
        return shown.map { "\($0.temperatureCelsius)°C" }.joined(separator: " ")
    }

    static func verdict(
        drives: [DriveEntry], unmonitorable: [UnmonitorableEntry], alerts: [Alert]
    ) -> String {
        guard !drives.isEmpty else {
            return unmonitorable.isEmpty
                ? "No drives detected"
                : "No monitorable NVMe drive"
        }
        guard !alerts.isEmpty else {
            return drives.count == 1 ? "1 drive healthy" : "All \(drives.count) drives healthy"
        }
        let affected = Set(alerts.map(\.serialNumber)).count
        let worst = alerts.contains { $0.severity == .critical } ? "critical" : "warning"
        return affected == 1
            ? "1 drive needs attention (\(worst))"
            : "\(affected) drives need attention (\(worst))"
    }

    static func sections(for record: DriveRecord, health: SmartHealth) -> [DetailSection] {
        var temperature: [DetailRow] = []
        if health.hotspotIsCompositeOnly {
            temperature.append(
                DetailRow(label: "hotspot", value: "\(health.hotspotCelsius)°C (composite only)"))
        } else {
            temperature.append(
                DetailRow(
                    label: "hotspot",
                    value: "\(health.hotspotCelsius)°C of \(health.sensorsCelsius.count) sensor(s)"))
            temperature.append(
                DetailRow(label: "composite", value: "\(health.compositeCelsius)°C"))
        }
        if let warning = record.identity?.warningTemperatureCelsius {
            temperature.append(
                DetailRow(label: "drive warns at", value: "\(warning)°C (composite)"))
        }

        let endurance: [DetailRow] = [
            DetailRow(label: "used", value: "\(health.percentageUsed)%"),
            DetailRow(
                label: "spare",
                value:
                    "\(health.availableSparePercent)% (min \(health.availableSpareThresholdPercent)%)"
            ),
            DetailRow(
                label: "written",
                value: byteString(SmartHealth.bytes(fromDataUnits: health.dataUnitsWritten))),
            DetailRow(label: "powered", value: "\(health.powerOnHours) h"),
            DetailRow(
                label: "cycles",
                value: "\(health.powerCycles) (\(health.unsafeShutdowns) unsafe)"),
            DetailRow(label: "media errors", value: "\(health.mediaAndDataIntegrityErrors)"),
        ]

        return [
            DetailSection(title: "Temperature", rows: temperature),
            DetailSection(title: "Endurance", rows: endurance),
        ]
    }

    static func byteString(_ bytes: UInt64) -> String {
        let terabytes = Double(bytes) / 1_000_000_000_000
        if terabytes >= 1 { return String(format: "%.2f TB", terabytes) }
        return String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}

extension UnmonitorableReason {
    /// A few words for a menu row. `explanation` keeps the full sentence for
    /// places that have room for it.
    public var shortLabel: String {
        switch self {
        case .usbAttachment: return "USB — needs a Thunderbolt enclosure"
        case .notNVMe(let interconnect):
            return "not NVMe (\(interconnect.isEmpty ? "unknown" : interconnect))"
        case .virtualDevice: return "disk image"
        case .advertisedButUnresponsive: return "no response — enclosure may be empty"
        }
    }
}
