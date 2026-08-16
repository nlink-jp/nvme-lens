import Foundation

/// What the process was asked to do.
///
/// Running with no arguments launches the menu-bar application; every other
/// invocation is a CLI subcommand. Both live in one binary by organization
/// convention, so the routing decision is made here and kept testable.
public enum Command: Equatable, Sendable {
    /// No arguments — launch the resident menu-bar application.
    case menuBar
    /// `list` — enumerate drives, including the ones that cannot be monitored.
    case list(format: OutputFormat)
    /// `status [--device <serial>]` — current-value snapshot.
    case status(serial: String?, format: OutputFormat)
    /// `history --device <serial> --since <period>` — recorded history.
    case history(serial: String, since: String, metric: Metric, format: OutputFormat)
    /// `sample` — take one reading, persist it, report any alerts.
    ///
    /// The menu-bar application does this on a timer; exposing it as a
    /// subcommand lets the store be populated (and the whole path exercised)
    /// before the GUI exists, and suits a launchd-driven collector.
    case sample(format: OutputFormat)
    /// `--version` — print the version and exit.
    case version
    /// `--help`, or anything we could not parse.
    case help(reason: String?)
}

public enum OutputFormat: String, Equatable, Sendable {
    case json
    case table
}

public enum Metric: String, Equatable, Sendable {
    case temp
    case wear
    case all
}

public enum RoutingError: Error, Equatable, Sendable {
    case unknownSubcommand(String)
    case missingValue(flag: String)
    case unknownFlag(String)
    case missingRequiredFlag(String)
    case invalidValue(flag: String, value: String)
}

extension RoutingError: CustomStringConvertible {
    /// Every case gets its own sentence naming the offending token. The default
    /// enum rendering (`unknownSubcommand("frobnicate")`) is a developer
    /// artefact, and a description that collapses to the same text for several
    /// cases tells the reader nothing about what to change.
    public var description: String {
        switch self {
        case .unknownSubcommand(let name):
            return "unknown subcommand '\(name)'"
        case .missingValue(let flag):
            return "'\(flag)' expects a value"
        case .unknownFlag(let flag):
            return "unknown option '\(flag)'"
        case .missingRequiredFlag(let flag):
            return "'\(flag)' is required"
        case .invalidValue(let flag, let value):
            return "'\(value)' is not a valid value for '\(flag)'"
        }
    }
}

/// Turns `CommandLine.arguments` (minus argv[0]) into a `Command`.
///
/// Pure: no I/O, no device access, no globals. This is what lets the routing
/// rules be verified without a machine that has an NVMe drive attached.
public enum CommandLineRouter {
    public static func route(_ arguments: [String]) throws -> Command {
        guard let first = arguments.first else { return .menuBar }

        switch first {
        case "--version", "-v", "version":
            return .version
        case "--help", "-h", "help":
            return .help(reason: nil)
        case "list":
            let flags = try Flags(parsing: Array(arguments.dropFirst()), allowed: ["--format"])
            return .list(format: try flags.format())
        case "status":
            let flags = try Flags(
                parsing: Array(arguments.dropFirst()), allowed: ["--format", "--device"])
            return .status(serial: flags["--device"], format: try flags.format())
        case "sample":
            let flags = try Flags(parsing: Array(arguments.dropFirst()), allowed: ["--format"])
            return .sample(format: try flags.format())
        case "history":
            let flags = try Flags(
                parsing: Array(arguments.dropFirst()),
                allowed: ["--format", "--device", "--since", "--metric"])
            guard let serial = flags["--device"] else {
                throw RoutingError.missingRequiredFlag("--device")
            }
            guard let since = flags["--since"] else {
                throw RoutingError.missingRequiredFlag("--since")
            }
            return .history(
                serial: serial, since: since, metric: try flags.metric(), format: try flags.format())
        default:
            throw RoutingError.unknownSubcommand(first)
        }
    }
}

/// Minimal `--flag value` parser. Deliberately not a general CLI framework:
/// the surface is small and fixed, and an external dependency would have to
/// earn its place (ADR-0001 keeps runtime dependencies at zero).
private struct Flags {
    private var values: [String: String] = [:]

    init(parsing arguments: [String], allowed: Set<String>) throws {
        var index = arguments.startIndex
        while index < arguments.endIndex {
            let flag = arguments[index]
            guard allowed.contains(flag) else { throw RoutingError.unknownFlag(flag) }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                throw RoutingError.missingValue(flag: flag)
            }
            values[flag] = arguments[valueIndex]
            index = arguments.index(after: valueIndex)
        }
    }

    subscript(flag: String) -> String? { values[flag] }

    func format() throws -> OutputFormat {
        guard let raw = values["--format"] else { return .json }
        guard let parsed = OutputFormat(rawValue: raw) else {
            throw RoutingError.invalidValue(flag: "--format", value: raw)
        }
        return parsed
    }

    func metric() throws -> Metric {
        guard let raw = values["--metric"] else { return .all }
        guard let parsed = Metric(rawValue: raw) else {
            throw RoutingError.invalidValue(flag: "--metric", value: raw)
        }
        return parsed
    }
}
