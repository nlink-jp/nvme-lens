import Foundation

/// What the menu bar should show, derived from the current readings.
///
/// Pure so the wording — especially the wording for the states where the tool
/// deliberately shows nothing — can be tested without launching an application.
public struct MenuBarPresentation: Equatable, Sendable {
    /// The status-item title. Short: it sits in a crowded menu bar.
    public var title: String
    /// Tooltip / first menu line explaining the title.
    public var summary: String
    public var rows: [Row]

    public struct Row: Equatable, Sendable {
        public var title: String
        public var detail: String
        public var isMonitored: Bool
        public var severity: AlertSeverity?
    }

    public static func make(
        records: [DriveRecord], alerts: [Alert] = [], configuration: Configuration = Configuration()
    ) -> MenuBarPresentation {
        let monitored = records.filter { $0.state.isMonitored }
        let severityBySerial = Dictionary(
            alerts.map { ($0.serialNumber, $0.severity) },
            uniquingKeysWith: { first, second in
                first == .critical || second == .critical ? .critical : first
            })

        var rows: [Row] = []
        for record in records {
            switch record.state {
            case .monitored:
                guard let health = record.health else { continue }
                let sensorNote = health.hotspotIsCompositeOnly ? " (composite only)" : ""
                rows.append(
                    Row(
                        title: "\(record.displayName)  \(health.hotspotCelsius)°C\(sensorNote)",
                        detail:
                            "used \(health.percentageUsed)%  spare \(health.availableSparePercent)%  \(health.powerOnHours) h  \(health.powerCycles) cycles",
                        isMonitored: true,
                        severity: severityBySerial[record.serialNumber]))
            case .unmonitorable(let reason):
                rows.append(
                    Row(
                        title: "\(record.displayName)  —",
                        detail: reason.explanation, isMonitored: false, severity: nil))
            }
        }

        guard
            let hottest = monitored.compactMap({ $0.health?.hotspotCelsius }).max()
        else {
            // Showing a blank or a zero here would read as a broken app. An
            // intentionally empty state has to say that it is intentional, and
            // why.
            let unmonitorableCount = records.count - monitored.count
            let summary =
                records.isEmpty
                ? "No drives detected."
                : "No monitorable NVMe drive. \(unmonitorableCount) drive(s) cannot be read — see below."
            return MenuBarPresentation(title: "––", summary: summary, rows: rows)
        }

        let worst: AlertSeverity? =
            alerts.contains { $0.severity == .critical }
            ? .critical : (alerts.isEmpty ? nil : .warning)
        let marker = worst == .critical ? "!! " : (worst == .warning ? "! " : "")
        let summary =
            alerts.isEmpty
            ? "\(monitored.count) drive(s) monitored, hottest \(hottest)°C"
            : "\(alerts.count) alert(s), hottest \(hottest)°C"

        return MenuBarPresentation(
            title: "\(marker)\(hottest)°", summary: summary, rows: rows)
    }
}
