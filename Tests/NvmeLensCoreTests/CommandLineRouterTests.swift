import Testing

@testable import NvmeLensCore

@Suite("CommandLineRouter")
struct CommandLineRouterTests {
    @Test("no arguments launches the menu-bar application")
    func noArgumentsLaunchesMenuBar() throws {
        #expect(try CommandLineRouter.route([]) == .menuBar)
    }

    @Test(
        "version flags are recognised",
        arguments: ["--version", "-v", "version"])
    func versionFlags(_ argument: String) throws {
        #expect(try CommandLineRouter.route([argument]) == .version)
    }

    @Test("list defaults to JSON output")
    func listDefaultsToJSON() throws {
        #expect(try CommandLineRouter.route(["list"]) == .list(format: .json))
    }

    @Test("list honours an explicit format")
    func listExplicitFormat() throws {
        #expect(try CommandLineRouter.route(["list", "--format", "table"]) == .list(format: .table))
    }

    @Test("status without a device targets every drive")
    func statusWithoutDevice() throws {
        #expect(try CommandLineRouter.route(["status"]) == .status(serial: nil, format: .json))
    }

    @Test("status selects a drive by serial number")
    func statusWithDevice() throws {
        let command = try CommandLineRouter.route(["status", "--device", "SERIAL0001"])
        #expect(command == .status(serial: "SERIAL0001", format: .json))
    }

    @Test("history requires both --device and --since")
    func historyRequiresFlags() {
        #expect(throws: RoutingError.missingRequiredFlag("--device")) {
            try CommandLineRouter.route(["history", "--since", "7d"])
        }
        #expect(throws: RoutingError.missingRequiredFlag("--since")) {
            try CommandLineRouter.route(["history", "--device", "SERIAL0001"])
        }
    }

    @Test("history defaults to every metric")
    func historyDefaultsToAllMetrics() throws {
        let command = try CommandLineRouter.route(
            ["history", "--device", "SERIAL0001", "--since", "7d"])
        #expect(command == .history(serial: "SERIAL0001", since: "7d", metric: .all, format: .json))
    }

    @Test("an unknown subcommand is rejected rather than silently ignored")
    func unknownSubcommand() {
        #expect(throws: RoutingError.unknownSubcommand("frobnicate")) {
            try CommandLineRouter.route(["frobnicate"])
        }
    }

    @Test("a flag with no value is rejected")
    func flagWithoutValue() {
        #expect(throws: RoutingError.missingValue(flag: "--device")) {
            try CommandLineRouter.route(["status", "--device"])
        }
    }

    @Test("an unsupported format value is rejected")
    func invalidFormat() {
        #expect(throws: RoutingError.invalidValue(flag: "--format", value: "yaml")) {
            try CommandLineRouter.route(["list", "--format", "yaml"])
        }
    }
}
