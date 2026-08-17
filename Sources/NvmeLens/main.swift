import Foundation
import NvmeLensCore

// Thin entry point: parse, dispatch, exit. Everything worth testing lives in
// NvmeLensCore.

let arguments = Array(CommandLine.arguments.dropFirst())

func emit(_ message: String, toStandardError: Bool = false) {
    let handle = toStandardError ? FileHandle.standardError : FileHandle.standardOutput
    handle.write(Data((message + "\n").utf8))
}

let usage = """
    nvme-lens \(Version.current)

    USAGE:
      nvme-lens                                   Launch the menu-bar application
      nvme-lens list [--format json|table]        List drives, monitorable or not
      nvme-lens status [--device <serial>]        Current-value snapshot
      nvme-lens sample [--format json|table]      Record one sample
      nvme-lens history --device <serial> --since <period> [--metric temp|wear]
                                                  period: 30m, 12h, 7d, 4w
      nvme-lens --version                         Print the version
      nvme-lens --help                            Print this message
    """

do {
    let command = try CommandLineRouter.route(arguments)
    switch command {
    case .version:
        emit(Version.current)
    case .help:
        emit(usage)
    case .menuBar:
        MenuBarApp.run(store: try HealthStore())
    case .list(let format):
        // list shows every drive, including the ones that cannot be monitored:
        // a drive missing from the list reads as broken or undetected.
        let reports = IOKitDeviceReader.readAll().map(DriveReport.init(record:))
        emit(format == .json ? try Renderer.json(reports) : Renderer.table(reports))
    case .status(let serial, let format):
        var reports = IOKitDeviceReader.readMonitored().map(DriveReport.init(record:))
        if let serial {
            reports = reports.filter { $0.serialNumber == serial }
            if reports.isEmpty {
                emit("error: no monitored drive with serial '\(serial)'", toStandardError: true)
                exit(69)
            }
        }
        emit(format == .json ? try Renderer.json(reports) : Renderer.table(reports))
    case .sample(let format):
        // Records only. Deciding what deserves a warning is the application's
        // job — it is the thing that can raise one, and it owns the thresholds.
        let outcome = try Sampler(store: try HealthStore(), configuration: Configuration())
            .run(records: IOKitDeviceReader.readAll())
        if format == .json {
            emit(try Renderer.json(sampleSummary: outcome))
        } else {
            emit(Renderer.table(sampleSummary: outcome))
        }

    case .history(let serial, let since, let metric, let format):
        let store = try HealthStore()
        let cutoff = Date().addingTimeInterval(-Double(try PeriodParser.seconds(since)))
        let temperature =
            metric == .wear ? nil : try store.temperatureSummary(serial: serial, since: cutoff)
        let wear = metric == .temp ? nil : try store.wearDelta(serial: serial, since: cutoff)
        if temperature == nil && wear == nil {
            // Distinguish "nothing happened" from "nothing was ever recorded":
            // an empty result that looks like a healthy answer is worse than an
            // explicit one.
            let known = try store.knownSerials()
            let hint =
                known.contains(serial)
                ? "no samples for '\(serial)' in that window"
                : "no drive with serial '\(serial)' has ever been sampled"
                    + (known.isEmpty ? " (the store is empty — run 'nvme-lens sample')" : "")
            emit("error: \(hint)", toStandardError: true)
            exit(69)
        }
        if format == .json {
            emit(try Renderer.json(temperature: temperature, wear: wear))
        } else {
            emit(Renderer.table(temperature: temperature, wear: wear))
        }
    }
} catch {
    emit("error: \(error)", toStandardError: true)
    emit(usage, toStandardError: true)
    exit(64)  // EX_USAGE
}
