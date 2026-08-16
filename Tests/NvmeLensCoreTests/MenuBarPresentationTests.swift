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

@Suite("MenuBarPresentation")
struct MenuBarPresentationTests {
    @Test("the title shows the hottest hotspot across monitored drives")
    func hottestWins() {
        let presentation = MenuBarPresentation.make(records: [
            monitored(serial: "A", hotspotKelvin: 320), monitored(serial: "B", hotspotKelvin: 343),
        ])
        #expect(presentation.title == "70°")
    }

    @Test("alerts mark the title so the state is visible without opening the menu")
    func alertsMarkTheTitle() {
        let warning = Alert(
            serialNumber: "SERIAL000000", model: "EXAMPLE SSD", severity: .warning,
            kind: "temperature", message: "hot")
        let critical = Alert(
            serialNumber: "SERIAL000000", model: "EXAMPLE SSD", severity: .critical,
            kind: "media-error", message: "errors")

        #expect(MenuBarPresentation.make(records: [monitored()], alerts: [warning]).title == "! 70°")
        #expect(
            MenuBarPresentation.make(records: [monitored()], alerts: [warning, critical]).title
                == "!! 70°")
    }

    /// A blank or zeroed menu bar reads as a broken app. An intentionally empty
    /// state has to say that it is intentional, and why.
    @Test("with no monitorable drive the summary explains itself")
    func emptyStateExplainsItself() {
        let presentation = MenuBarPresentation.make(records: [usbDrive()])
        #expect(presentation.title == "––")
        #expect(presentation.summary.contains("cannot be read"))
        #expect(presentation.rows.count == 1)
        #expect(presentation.rows[0].isMonitored == false)
        #expect(presentation.rows[0].detail.contains("Thunderbolt"))
    }

    @Test("with no drives at all the summary says so rather than showing nothing")
    func noDrivesAtAll() {
        let presentation = MenuBarPresentation.make(records: [])
        #expect(presentation.title == "––")
        #expect(presentation.summary == "No drives detected.")
    }

    @Test("unmonitorable drives stay in the list next to monitored ones")
    func unmonitorableAreListed() {
        let presentation = MenuBarPresentation.make(records: [monitored(), usbDrive()])
        #expect(presentation.rows.count == 2)
        #expect(presentation.rows.filter(\.isMonitored).count == 1)
    }

    /// A composite-derived number must not be presented as if it were a sensor
    /// reading.
    @Test("a composite-only drive is labelled as such")
    func compositeOnlyIsLabelled() {
        let presentation = MenuBarPresentation.make(
            records: [monitored(compositeKelvin: 313, sensors: false)])
        #expect(presentation.title == "40°")
        #expect(presentation.rows[0].title.contains("composite only"))
    }

    @Test("a drive's own row carries the severity of its alerts")
    func rowSeverity() {
        let alert = Alert(
            serialNumber: "B", model: "EXAMPLE SSD", severity: .critical, kind: "media-error",
            message: "errors")
        let presentation = MenuBarPresentation.make(
            records: [monitored(serial: "A"), monitored(serial: "B")], alerts: [alert])
        #expect(presentation.rows[0].severity == nil)
        #expect(presentation.rows[1].severity == .critical)
    }
}
