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
    case .list, .status, .history:
        // TODO(Phase 1): read SMART data via IOKit and render the result.
        emit("not implemented yet", toStandardError: true)
        exit(69)  // EX_UNAVAILABLE
    }
} catch {
    emit("error: \(error)", toStandardError: true)
    emit(usage, toStandardError: true)
    exit(64)  // EX_USAGE
}
