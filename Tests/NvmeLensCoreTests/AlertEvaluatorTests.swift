import Foundation
import Testing

@testable import NvmeLensCore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func health(
    hotspotSensorKelvin: UInt16 = 0, compositeKelvin: UInt16 = 300, percentageUsed: UInt8 = 0,
    availableSpare: UInt8 = 100, spareThreshold: UInt8 = 10, mediaErrors: UInt64 = 0,
    powerCycles: UInt64 = 0, powerOnHours: UInt64 = 0, unsafeShutdowns: UInt64 = 0
) -> SmartHealth {
    SmartHealth(
        criticalWarning: 0, compositeTemperatureKelvin: compositeKelvin,
        availableSparePercent: availableSpare, availableSpareThresholdPercent: spareThreshold,
        percentageUsed: percentageUsed, dataUnitsRead: 0, dataUnitsWritten: 0, hostReadCommands: 0,
        hostWriteCommands: 0, controllerBusyTimeMinutes: 0, powerCycles: powerCycles,
        powerOnHours: powerOnHours, unsafeShutdowns: unsafeShutdowns,
        mediaAndDataIntegrityErrors: mediaErrors, errorInformationLogEntries: 0,
        warningCompositeTemperatureMinutes: 0, criticalCompositeTemperatureMinutes: 0,
        sensorsKelvin: hotspotSensorKelvin == 0 ? [] : [hotspotSensorKelvin])
}

private func record(_ health: SmartHealth) -> DriveRecord {
    DriveRecord(
        descriptor: DriveDescriptor(
            bsdName: "disk9", productName: "EXAMPLE SSD", serialNumber: "SERIAL000000",
            physicalInterconnect: "PCI-Express", physicalInterconnectLocation: "External",
            smartCapable: true),
        state: .monitored, identity: nil, health: health)
}

private func history(celsius: [Int], spacingSeconds: Int = 60, endingAt end: Date = epoch)
    -> [TemperaturePoint]
{
    celsius.enumerated().map { index, value in
        TemperaturePoint(
            timestamp: end.addingTimeInterval(
                -Double((celsius.count - 1 - index) * spacingSeconds)),
            hotspotCelsius: value)
    }
}

@Suite("AlertEvaluator")
struct AlertEvaluatorTests {
    var configuration: Configuration {
        var config = Configuration()
        config.temperature.warningCelsius = 78
        config.temperature.criticalCelsius = 83
        config.temperature.sustainedMinutes = 5
        return config
    }

    /// The whole point of the dwell condition: a drive that spikes during a file
    /// copy and cools must not wake anyone.
    @Test("a brief temperature spike does not alert")
    func briefSpikeIsSilent() {
        let alerts = AlertEvaluator.evaluate(
            record: record(health(hotspotSensorKelvin: 353)),  // 80 C
            now: epoch,
            temperatureHistory: history(celsius: [50, 50, 80]),
            wearBaseline: nil, configuration: configuration)
        #expect(alerts.filter { $0.kind == "temperature" }.isEmpty)
    }

    @Test("sustained heat above the warning threshold alerts")
    func sustainedHeatAlerts() {
        let alerts = AlertEvaluator.evaluate(
            record: record(health(hotspotSensorKelvin: 353)),  // 80 C
            now: epoch,
            temperatureHistory: history(celsius: [80, 80, 80, 80, 80, 80]),
            wearBaseline: nil, configuration: configuration)
        let temperature = alerts.filter { $0.kind == "temperature" }
        #expect(temperature.count == 1)
        #expect(temperature.first?.severity == .warning)
    }

    @Test("sustained heat above the critical threshold escalates and does not double-report")
    func criticalEscalates() {
        let alerts = AlertEvaluator.evaluate(
            record: record(health(hotspotSensorKelvin: 358)),  // 85 C
            now: epoch,
            temperatureHistory: history(celsius: [85, 85, 85, 85, 85, 85]),
            wearBaseline: nil, configuration: configuration)
        let temperature = alerts.filter { $0.kind == "temperature" }
        #expect(temperature.count == 1)
        #expect(temperature.first?.severity == .critical)
    }

    /// Measured behaviour: a drive idles at 69 C. A monitor that alerts there is
    /// a monitor nobody keeps enabled.
    @Test("a hot but normal idle temperature is silent")
    func hotIdleIsSilent() {
        let alerts = AlertEvaluator.evaluate(
            record: record(health(hotspotSensorKelvin: 342)),  // 69 C
            now: epoch,
            temperatureHistory: history(celsius: Array(repeating: 69, count: 30)),
            wearBaseline: nil, configuration: configuration)
        #expect(alerts.isEmpty)
    }

    @Test("a drive that has cooled stops alerting immediately")
    func coolingStopsAlerts() {
        let alerts = AlertEvaluator.evaluate(
            record: record(health(hotspotSensorKelvin: 323)),  // 50 C
            now: epoch,
            temperatureHistory: history(celsius: [85, 85, 85, 85, 85, 50]),
            wearBaseline: nil, configuration: configuration)
        #expect(alerts.filter { $0.kind == "temperature" }.isEmpty)
    }

    @Test("any increase in media errors is critical, with no threshold")
    func mediaErrorsAlert() {
        let baseline = WearBaseline(
            timestamp: epoch.addingTimeInterval(-3600), percentageUsed: 0, mediaErrors: 0,
            powerCycles: 0, powerOnHours: 0, unsafeShutdowns: 0)
        let alerts = AlertEvaluator.evaluate(
            record: record(health(mediaErrors: 1)), now: epoch, temperatureHistory: [],
            wearBaseline: baseline, configuration: configuration)
        let media = alerts.filter { $0.kind == "media-error" }
        #expect(media.count == 1)
        #expect(media.first?.severity == .critical)
    }

    @Test("available spare reaching the drive's own threshold is critical")
    func spareExhaustionIsCritical() {
        let alerts = AlertEvaluator.evaluate(
            record: record(health(availableSpare: 10, spareThreshold: 10)), now: epoch,
            temperatureHistory: [], wearBaseline: nil, configuration: configuration)
        #expect(alerts.contains { $0.kind == "endurance" && $0.severity == .critical })
    }

    /// Regression, found by running against real hardware: Apple's internal SSD
    /// reports Available Spare Threshold = 99% while spare itself is 100%. A
    /// bare "within N points of the threshold" test fires on a perfectly healthy
    /// drive, because the threshold's scale is a vendor choice (5%, 10% and 99%
    /// were all observed on one machine).
    @Test("a full spare does not alert however high the drive sets its threshold")
    func fullSpareWithHighThresholdIsSilent() {
        let alerts = AlertEvaluator.evaluate(
            record: record(health(availableSpare: 100, spareThreshold: 99)), now: epoch,
            temperatureHistory: [], wearBaseline: nil, configuration: configuration)
        #expect(alerts.filter { $0.kind == "endurance" }.isEmpty)
    }

    @Test("spare that has actually started depleting near the threshold warns")
    func depletingSpareWarns() {
        let alerts = AlertEvaluator.evaluate(
            record: record(health(availableSpare: 12, spareThreshold: 10)), now: epoch,
            temperatureHistory: [], wearBaseline: nil, configuration: configuration)
        let endurance = alerts.filter { $0.kind == "endurance" }
        #expect(endurance.count == 1)
        #expect(endurance.first?.severity == .warning)
    }

    /// The measurement that started this project: a USB enclosure drove 7.3
    /// power cycles per powered hour through disk sleep.
    @Test("an abnormal power-cycle rate alerts")
    func powerCycleRateAlerts() {
        let baseline = WearBaseline(
            timestamp: epoch.addingTimeInterval(-36_000), percentageUsed: 0, mediaErrors: 0,
            powerCycles: 1000, powerOnHours: 100, unsafeShutdowns: 0)
        let alerts = AlertEvaluator.evaluate(
            record: record(health(powerCycles: 1073, powerOnHours: 110)), now: epoch,
            temperatureHistory: [], wearBaseline: baseline, configuration: configuration)
        let cycles = alerts.filter { $0.kind == "power-cycle" }
        #expect(cycles.count == 1)
        #expect(cycles.first?.message.contains("7.3") == true)
    }

    @Test("a normal power-cycle rate is silent")
    func normalPowerCycleRateIsSilent() {
        let baseline = WearBaseline(
            timestamp: epoch.addingTimeInterval(-36_000), percentageUsed: 0, mediaErrors: 0,
            powerCycles: 1000, powerOnHours: 100, unsafeShutdowns: 0)
        let alerts = AlertEvaluator.evaluate(
            record: record(health(powerCycles: 1000, powerOnHours: 112)), now: epoch,
            temperatureHistory: [], wearBaseline: baseline, configuration: configuration)
        #expect(alerts.filter { $0.kind == "power-cycle" }.isEmpty)
    }

    @Test("an unmonitorable drive produces no alerts at all")
    func unmonitorableIsSilent() {
        var unmonitorable = record(health(hotspotSensorKelvin: 400))
        unmonitorable.state = .unmonitorable(.usbAttachment)
        let alerts = AlertEvaluator.evaluate(
            record: unmonitorable, now: epoch, temperatureHistory: history(celsius: [127, 127, 127]),
            wearBaseline: nil, configuration: configuration)
        #expect(alerts.isEmpty)
    }
}

@Suite("sustainedSeconds")
struct SustainedSecondsTests {
    @Test("counts back only through the unbroken run")
    func unbrokenRun() {
        let points = history(celsius: [90, 50, 90, 90, 90], spacingSeconds: 60)
        #expect(AlertEvaluator.sustainedSeconds(history: points, now: epoch, atOrAbove: 80) == 120)
    }

    @Test("returns zero when the latest reading is below the threshold")
    func belowThreshold() {
        let points = history(celsius: [90, 90, 50])
        #expect(AlertEvaluator.sustainedSeconds(history: points, now: epoch, atOrAbove: 80) == 0)
    }

    @Test("an empty history is zero, not a crash")
    func emptyHistory() {
        #expect(AlertEvaluator.sustainedSeconds(history: [], now: epoch, atOrAbove: 80) == 0)
    }
}

@Suite("PeriodParser")
struct PeriodParserTests {
    @Test("accepts the documented units", arguments: [("30m", 1800), ("12h", 43200), ("7d", 604_800), ("4w", 2_419_200)])
    func units(_ input: String, _ expected: Int) throws {
        #expect(try PeriodParser.seconds(input) == expected)
    }

    @Test("rejects what it cannot parse", arguments: ["", "7", "d", "-1d", "7y", "abc"])
    func rejects(_ input: String) {
        #expect(throws: (any Error).self) { try PeriodParser.seconds(input) }
    }
}
