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
      nvme-lens history --device <serial> --since <period> [--metric temp|wear]
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
        // TODO(Phase 2): launch the menu-bar application.
        emit("menu-bar application is not implemented yet", toStandardError: true)
        exit(69)  // EX_UNAVAILABLE
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
    case .history:
        // TODO(Phase 2): needs the SQLite store and background sampling.
        emit("history is not implemented yet", toStandardError: true)
        exit(69)  // EX_UNAVAILABLE
    }
} catch {
    emit("error: \(error)", toStandardError: true)
    emit(usage, toStandardError: true)
    exit(64)  // EX_USAGE
}
