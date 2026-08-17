import Testing

@testable import NvmeLensCore

@Suite("LoginItemPresentation")
struct LoginItemPresentationTests {
    private static let allStatuses: [LoginItemStatus] = [
        .enabled, .requiresApproval, .notRegistered, .notFound, .unknown(42),
    ]

    /// The rule this whole type exists to hold. A sibling tool disabled its
    /// login-item switch whenever the status was the never-registered one — which
    /// is the status on first run, so the switch was dead exactly when enabling
    /// it was the only thing anyone wanted to do.
    @Test("no status ever disables the control", arguments: allStatuses)
    func controlIsNeverDisabled(_ status: LoginItemStatus) {
        #expect(LoginItemPresentation.make(status: status).isControlEnabled)
    }

    @Test("a never-registered app reads as off, not as unavailable")
    func notFoundIsOff() {
        let presentation = LoginItemPresentation.make(status: .notFound)
        #expect(presentation.isOn == false)
        #expect(presentation.note == nil)
    }

    @Test("an unrecognised status folds to off rather than to an error state")
    func unknownIsOff() {
        #expect(LoginItemPresentation.make(status: .unknown(99)).isOn == false)
    }

    @Test("enabled is on with nothing left to do")
    func enabled() {
        let presentation = LoginItemPresentation.make(status: .enabled)
        #expect(presentation.isOn)
        #expect(presentation.note == nil)
    }

    /// Showing a plain "on" here would promise a launch that will not happen.
    @Test("pending approval is on, but says what is still required")
    func requiresApproval() {
        let presentation = LoginItemPresentation.make(status: .requiresApproval)
        #expect(presentation.isOn)
        #expect(presentation.note?.contains("System Settings") == true)
    }
}

@Suite("LoginItemOutcome")
struct LoginItemOutcomeTests {
    @Test("a status that reached the requested value is a success")
    func success() {
        #expect(
            LoginItemOutcome.evaluate(
                wanted: true, before: .notFound, after: .enabled, error: nil)
                == .succeeded(nowOn: true))
        #expect(
            LoginItemOutcome.evaluate(
                wanted: false, before: .enabled, after: .notRegistered, error: nil)
                == .succeeded(nowOn: false))
    }

    /// Approval still counts as on: the registration exists, and the note tells
    /// the user what remains.
    @Test("pending approval satisfies a request to enable")
    func approvalCountsAsEnabled() {
        #expect(
            LoginItemOutcome.evaluate(
                wanted: true, before: .notFound, after: .requiresApproval, error: nil)
                == .succeeded(nowOn: true))
    }

    @Test("a thrown error is reported verbatim")
    func failure() {
        #expect(
            LoginItemOutcome.evaluate(
                wanted: true, before: .notFound, after: .notFound, error: "denied")
                == .failed("denied"))
    }

    /// The worst outcome is silence: no error, and the control quietly snaps
    /// back with nothing to explain it.
    @Test("an unchanged status with no error is reported, not swallowed")
    func silentNoOpIsReported() {
        let outcome = LoginItemOutcome.evaluate(
            wanted: true, before: .notFound, after: .notFound, error: nil)
        guard case .didNotChange(let message) = outcome else {
            Issue.record("expected didNotChange, got \(outcome)")
            return
        }
        #expect(message.contains("could not enable"))
    }

    @Test("disabling that leaves the registration in place is reported")
    func failedDisableIsReported() {
        let outcome = LoginItemOutcome.evaluate(
            wanted: false, before: .enabled, after: .enabled, error: nil)
        guard case .didNotChange(let message) = outcome else {
            Issue.record("expected didNotChange, got \(outcome)")
            return
        }
        #expect(message.contains("still present"))
    }
}
