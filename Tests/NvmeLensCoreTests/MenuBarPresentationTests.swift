import Testing

@testable import NvmeLensCore

private func monitored(
    name: String = "EXAMPLE SSD", serial: String = "SERIAL000000", hotspotKelvin: UInt16 = 343,
    compositeKelvin: UInt16 = 326, sensors: Bool = true
) -> DriveRecord {
    let health = SmartHealth(
        criticalWarning: 0, compositeTemperatureKelvin: compositeKelvin, availableSparePercent: 100,
        availableSpareThresholdPercent: 10, percentageUsed: 3, dataUnitsRead: 0,
        dataUnitsWritten: 0, hostReadCommands: 0, hostWriteCommands: 0,
        controllerBusyTimeMinutes: 0, powerCycles: 9411, powerOnHours: 1308, unsafeShutdowns: 0,
        mediaAndDataIntegrityErrors: 0, errorInformationLogEntries: 0,
        warningCompositeTemperatureMinutes: 0, criticalCompositeTemperatureMinutes: 0,
        sensorsKelvin: sensors ? [hotspotKelvin] : [])
    return DriveRecord(
        descriptor: DriveDescriptor(
            bsdName: "disk9", productName: name, serialNumber: serial,
            physicalInterconnect: "PCI-Express", physicalInterconnectLocation: "External",
            smartCapable: true),
        state: .monitored, identity: nil, health: health)
}

private func usbDrive() -> DriveRecord {
    DriveRecord(
        descriptor: DriveDescriptor(
            bsdName: "", productName: "USB CADDY", serialNumber: "",
            physicalInterconnect: "USB", physicalInterconnectLocation: "External",
            smartCapable: true),
        state: .unmonitorable(.usbAttachment))
}

private func alert(serial: String, severity: AlertSeverity = .warning) -> Alert {
    Alert(
        serialNumber: serial, model: "EXAMPLE SSD", severity: severity, kind: "temperature",
        message: "hot")
}

@Suite("MenuBarPresentation title")
struct MenuBarPresentationTitleTests {
    /// With nothing chosen the tool still has to show something meaningful, and
    /// the hottest drive is the one worth a glance.
    @Test("with no selection the title falls back to the hottest drive")
    func fallsBackToHottest() {
        let presentation = MenuBarPresentation.make(records: [
            monitored(serial: "A", hotspotKelvin: 320), monitored(serial: "B", hotspotKelvin: 343),
        ])
        #expect(presentation.title == "70°C")
    }

    @Test("a chosen drive is shown even when it is not the hottest")
    func honoursSelection() {
        // Composite is set below each sensor here: the hotspot is the maximum of
        // both, so leaving composite at its default would decide these cases.
        let presentation = MenuBarPresentation.make(
            records: [
                monitored(serial: "A", hotspotKelvin: 320, compositeKelvin: 300),
                monitored(serial: "B", hotspotKelvin: 343, compositeKelvin: 326),
            ],
            selectedSerials: ["A"])
        #expect(presentation.title == "47°C")
    }

    @Test("several chosen drives appear in list order")
    func multipleSelection() {
        let presentation = MenuBarPresentation.make(
            records: [
                monitored(serial: "A", hotspotKelvin: 320, compositeKelvin: 300),
                monitored(serial: "B", hotspotKelvin: 343, compositeKelvin: 326),
                monitored(serial: "C", hotspotKelvin: 300, compositeKelvin: 290),
            ],
            selectedSerials: ["A", "C"])
        #expect(presentation.title == "47°C 27°C")
    }

    @Test("a selection naming drives that are gone falls back rather than blanking")
    func staleSelectionFallsBack() {
        let presentation = MenuBarPresentation.make(
            records: [monitored(serial: "A", hotspotKelvin: 320, compositeKelvin: 300)],
            selectedSerials: ["DISCONNECTED"])
        #expect(presentation.title == "47°C")
    }

    /// Severity rides on the symbol beside the number, not on punctuation glued
    /// to it: a colour is read at a glance where "!!" has to be decoded.
    @Test("severity is reported separately from the text")
    func severityIsSeparate() {
        let records = [monitored(serial: "A")]
        let healthy = MenuBarPresentation.make(records: records)
        #expect(healthy.title == "70°C")
        #expect(healthy.overallSeverity == nil)

        let warned = MenuBarPresentation.make(records: records, alerts: [alert(serial: "A")])
        #expect(warned.title == "70°C")
        #expect(warned.overallSeverity == .warning)

        let critical = MenuBarPresentation.make(
            records: records, alerts: [alert(serial: "A"), alert(serial: "A", severity: .critical)])
        #expect(critical.overallSeverity == .critical)
    }

    /// Nothing to report leaves the symbol to speak for itself; a placeholder
    /// string beside it would only add noise.
    @Test("with no monitorable drive the text is empty")
    func emptyTitle() {
        #expect(MenuBarPresentation.make(records: [usbDrive()]).title == "")
        #expect(MenuBarPresentation.make(records: []).title == "")
    }
}

@Suite("MenuBarPresentation verdict")
struct MenuBarPresentationVerdictTests {
    /// The first line answers the question the tool exists for. A statistic like
    /// "3 drives monitored, hottest 71°C" is not an answer.
    @Test("a healthy fleet says so")
    func healthy() {
        #expect(
            MenuBarPresentation.make(records: [monitored(serial: "A"), monitored(serial: "B")])
                .verdict == "All 2 drives healthy")
        #expect(MenuBarPresentation.make(records: [monitored()]).verdict == "1 drive healthy")
    }

    @Test("alerts are counted by drive, and named by worst severity")
    func needsAttention() {
        let records = [monitored(serial: "A"), monitored(serial: "B")]
        #expect(
            MenuBarPresentation.make(records: records, alerts: [alert(serial: "A")]).verdict
                == "1 drive needs attention (warning)")
        #expect(
            MenuBarPresentation.make(
                records: records,
                alerts: [alert(serial: "A"), alert(serial: "B", severity: .critical)]
            ).verdict == "2 drives need attention (critical)")
    }

    @Test("two alerts on one drive still count as one drive")
    func alertsDeduplicateByDrive() {
        let presentation = MenuBarPresentation.make(
            records: [monitored(serial: "A")],
            alerts: [alert(serial: "A"), alert(serial: "A", severity: .critical)])
        #expect(presentation.verdict == "1 drive needs attention (critical)")
    }

    @Test("the empty states explain themselves rather than showing nothing")
    func emptyStates() {
        #expect(MenuBarPresentation.make(records: []).verdict == "No drives detected")
        #expect(
            MenuBarPresentation.make(records: [usbDrive()]).verdict == "No monitorable NVMe drive")
    }
}

@Suite("MenuBarPresentation structure")
struct MenuBarPresentationStructureTests {
    /// The complaint that started this redesign: everything at one level, with
    /// unmonitorable drives taking as much room as real ones.
    @Test("unmonitorable drives collapse into one summary row")
    func unmonitorableCollapse() {
        let presentation = MenuBarPresentation.make(records: [monitored(), usbDrive(), usbDrive()])
        #expect(presentation.drives.count == 1)
        #expect(presentation.unmonitorable.count == 2)
        #expect(presentation.unmonitorableSummary == "2 drives not monitored")
    }

    @Test("no unmonitorable drives means no summary row at all")
    func noSummaryWhenAllHealthy() {
        #expect(MenuBarPresentation.make(records: [monitored()]).unmonitorableSummary == nil)
    }

    @Test("the short reason is a clause, not the README paragraph")
    func shortReasonIsShort() {
        let presentation = MenuBarPresentation.make(records: [usbDrive()])
        let entry = presentation.unmonitorable[0]
        #expect(entry.shortReason.count < 45)
        #expect(entry.shortReason.contains("Thunderbolt"))
        // The full sentence is still available for places with room.
        #expect(entry.fullReason.count > entry.shortReason.count)
    }

    @Test("numbers live in the detail sections, not on the drive row")
    func detailsAreNested() {
        let presentation = MenuBarPresentation.make(records: [monitored()])
        let drive = presentation.drives[0]
        #expect(drive.sections.map(\.title) == ["Temperature", "Endurance"])
        #expect(drive.sections.contains { $0.rows.contains { $0.label == "media errors" } })
    }

    /// A composite-derived number must never be presented as a sensor reading.
    @Test("a composite-only drive says so in its temperature detail")
    func compositeOnlyIsLabelled() {
        let presentation = MenuBarPresentation.make(
            records: [monitored(compositeKelvin: 313, sensors: false)])
        let temperature = presentation.drives[0].sections[0]
        #expect(temperature.rows[0].value.contains("composite only"))
    }

    @Test("a drive's row carries the severity of its own alerts only")
    func severityIsPerDrive() {
        let presentation = MenuBarPresentation.make(
            records: [monitored(serial: "A"), monitored(serial: "B")],
            alerts: [alert(serial: "B", severity: .critical)])
        #expect(presentation.drives[0].severity == nil)
        #expect(presentation.drives[1].severity == .critical)
        #expect(presentation.drives[1].alertMessages.count == 1)
    }

    @Test("selection state is reported per drive so the menu can show a checkmark")
    func selectionIsReported() {
        let presentation = MenuBarPresentation.make(
            records: [monitored(serial: "A"), monitored(serial: "B")], selectedSerials: ["B"])
        #expect(presentation.drives[0].isShownInMenuBar == false)
        #expect(presentation.drives[1].isShownInMenuBar == true)
    }
}
