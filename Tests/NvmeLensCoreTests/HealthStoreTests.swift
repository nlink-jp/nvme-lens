import Foundation
import Testing

@testable import NvmeLensCore

/// The store is exercised against a real SQLite file in a temporary directory.
/// It needs no NVMe device — only the parsed structures — so it stays inside the
/// "unit tests require no hardware" rule.
private func makeStore() throws -> (HealthStore, URL) {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("nvme-lens-tests-\(UUID().uuidString)")
    let url = directory.appendingPathComponent("history.sqlite")
    return (try HealthStore(url: url), directory)
}

private func makeRecord(
    serial: String = "SERIAL000000", hotspotKelvin: UInt16 = 320, percentageUsed: UInt8 = 1,
    powerCycles: UInt64 = 100, powerOnHours: UInt64 = 10, mediaErrors: UInt64 = 0,
    unsafeShutdowns: UInt64 = 0
) -> DriveRecord {
    let health = SmartHealth(
        criticalWarning: 0, compositeTemperatureKelvin: 300, availableSparePercent: 100,
        availableSpareThresholdPercent: 10, percentageUsed: percentageUsed, dataUnitsRead: 5,
        dataUnitsWritten: 7, hostReadCommands: 0, hostWriteCommands: 0,
        controllerBusyTimeMinutes: 0, powerCycles: powerCycles, powerOnHours: powerOnHours,
        unsafeShutdowns: unsafeShutdowns, mediaAndDataIntegrityErrors: mediaErrors,
        errorInformationLogEntries: 0, warningCompositeTemperatureMinutes: 0,
        criticalCompositeTemperatureMinutes: 0, sensorsKelvin: [hotspotKelvin])
    return DriveRecord(
        descriptor: DriveDescriptor(
            bsdName: "disk9", productName: "EXAMPLE SSD", serialNumber: serial,
            physicalInterconnect: "PCI-Express", physicalInterconnectLocation: "External",
            smartCapable: true),
        state: .monitored, identity: nil, health: health)
}

@Suite("HealthStore")
struct HealthStoreTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a sample can be written and read back")
    func roundTrip() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.record(makeRecord(hotspotKelvin: 330), at: base)
        let points = try store.temperatureHistory(
            serial: "SERIAL000000", since: base.addingTimeInterval(-60))
        #expect(points.count == 1)
        #expect(points.first?.hotspotCelsius == 57)
    }

    @Test("an unmonitorable drive is not recorded")
    func unmonitorableIsNotRecorded() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var record = makeRecord()
        record.state = .unmonitorable(.usbAttachment)
        try store.record(record, at: base)
        #expect(try store.knownSerials().isEmpty)
    }

    @Test("the summary reports min, max and average over the window")
    func summary() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        for (index, kelvin) in [UInt16(320), 340, 330].enumerated() {
            try store.record(
                makeRecord(hotspotKelvin: kelvin), at: base.addingTimeInterval(Double(index * 60)))
        }
        let summary = try store.temperatureSummary(
            serial: "SERIAL000000", since: base.addingTimeInterval(-60))
        #expect(summary?.samples == 3)
        #expect(summary?.minCelsius == 47)
        #expect(summary?.maxCelsius == 67)
    }

    @Test("a window with no samples summarises to nil rather than to zeros")
    func emptySummary() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.record(makeRecord(), at: base)
        let summary = try store.temperatureSummary(
            serial: "SERIAL000000", since: base.addingTimeInterval(3600))
        #expect(summary == nil)
    }

    @Test("the wear delta computes the power-cycle rate over the window")
    func wearDelta() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.record(makeRecord(powerCycles: 1000, powerOnHours: 100), at: base)
        try store.record(
            makeRecord(powerCycles: 1073, powerOnHours: 110),
            at: base.addingTimeInterval(36_000))

        let delta = try store.wearDelta(serial: "SERIAL000000", since: base.addingTimeInterval(-60))
        #expect(delta?.powerCyclesDelta == 73)
        #expect(delta?.powerOnHoursDelta == 10)
        #expect(delta.map { abs(($0.powerCyclesPerHour ?? 0) - 7.3) < 0.01 } == true)
    }

    @Test("a single snapshot yields no delta, rather than a delta of zero")
    func singleSnapshotHasNoDelta() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.record(makeRecord(), at: base)
        #expect(try store.wearDelta(serial: "SERIAL000000", since: base.addingTimeInterval(-60)) == nil)
    }

    @Test("the baseline is the newest snapshot strictly before the given moment")
    func baselineIsStrictlyBefore() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.record(makeRecord(percentageUsed: 1), at: base)
        try store.record(makeRecord(percentageUsed: 2), at: base.addingTimeInterval(3600))

        let baseline = try store.latestWearBaseline(
            serial: "SERIAL000000", before: base.addingTimeInterval(3600))
        #expect(baseline?.percentageUsed == 1)
    }

    @Test("pruning drops expired temperature rows and keeps wear snapshots")
    func pruning() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        try store.record(makeRecord(), at: base)
        try store.record(makeRecord(), at: base.addingTimeInterval(86_400 * 100))

        let pruned = try store.pruneTemperature(olderThan: base.addingTimeInterval(86_400))
        #expect(pruned == 1)
        // The wear history survives: it is small and its long-term trend is the point.
        let delta = try store.wearDelta(serial: "SERIAL000000", since: base.addingTimeInterval(-60))
        #expect(delta != nil)
    }

    @Test("re-opening the same file keeps the data")
    func persistsAcrossOpens() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = URL(fileURLWithPath: store.path)

        try store.record(makeRecord(), at: base)
        let reopened = try HealthStore(url: url)
        #expect(try reopened.knownSerials() == ["SERIAL000000"])
    }
}

@Suite("Sampler")
struct SamplerTests {
    let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("a pass records monitorable drives and skips the rest")
    func recordsOnlyMonitorable() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        var usb = makeRecord(serial: "USBDRIVE")
        usb.state = .unmonitorable(.usbAttachment)
        let sampler = Sampler(store: store, configuration: Configuration())
        let outcome = try sampler.run(records: [makeRecord(), usb], now: base)

        #expect(outcome.recorded == ["SERIAL000000"])
    }

    /// The evaluator must compare against the past, not against the row the
    /// sampler is about to write — otherwise every delta is zero forever.
    @Test("the second pass sees the first pass as its baseline")
    func baselineComesFromThePreviousPass() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sampler = Sampler(store: store, configuration: Configuration())
        _ = try sampler.run(records: [makeRecord(mediaErrors: 0)], now: base)
        let second = try sampler.run(
            records: [makeRecord(mediaErrors: 3)], now: base.addingTimeInterval(3600))

        #expect(second.alerts.contains { $0.kind == "media-error" })
    }

    @Test("the first pass on an empty store raises no delta-based alerts")
    func firstPassIsQuiet() throws {
        let (store, directory) = try makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }

        let sampler = Sampler(store: store, configuration: Configuration())
        let outcome = try sampler.run(records: [makeRecord(mediaErrors: 5)], now: base)
        #expect(outcome.alerts.filter { $0.kind == "media-error" }.isEmpty)
    }
}
