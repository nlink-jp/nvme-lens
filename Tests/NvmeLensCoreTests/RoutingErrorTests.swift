import Testing

@testable import NvmeLensCore

@Suite("RoutingError messages")
struct RoutingErrorTests {
    private static let allCases: [RoutingError] = [
        .unknownSubcommand("frobnicate"),
        .missingValue(flag: "--device"),
        .unknownFlag("--colour"),
        .missingRequiredFlag("--since"),
        .invalidValue(flag: "--format", value: "yaml"),
    ]

    @Test("every case names the offending token", arguments: allCases)
    func namesTheOffendingToken(_ error: RoutingError) {
        let message = String(describing: error)
        #expect(!message.isEmpty)
        // The default enum rendering leaks the case name and Swift's quoting.
        #expect(!message.contains("("))
        #expect(!message.contains("\""))
    }

    /// Guards against the failure mode where several cases collapse onto one
    /// indistinguishable string, leaving the reader unable to tell what to fix.
    @Test("no two cases produce the same message")
    func messagesAreDistinct() {
        let messages = Self.allCases.map { String(describing: $0) }
        #expect(Set(messages).count == messages.count)
    }

    @Test("the offending value appears in the message")
    func mentionsTheValue() {
        #expect(String(describing: RoutingError.unknownSubcommand("frobnicate")).contains("frobnicate"))
        #expect(String(describing: RoutingError.missingRequiredFlag("--since")).contains("--since"))
        #expect(String(describing: RoutingError.invalidValue(flag: "--format", value: "yaml")).contains("yaml"))
    }
}
