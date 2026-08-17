import Foundation

/// The raw status a login-item registration can report, mirrored here so the
/// mapping can be tested without importing ServiceManagement.
public enum LoginItemStatus: Equatable, Sendable {
    case enabled
    case requiresApproval
    case notRegistered
    /// What the system actually returns for an app that has never been
    /// registered — *not* an error, and not "this copy cannot be registered".
    case notFound
    case unknown(Int)
}

/// What the login-item control should look like and do.
public struct LoginItemPresentation: Equatable, Sendable {
    public var isOn: Bool
    /// Always true. Kept as a field so the rule is visible and testable rather
    /// than implicit: a status that cannot tell "no" from "don't know" must
    /// never disable the control, because disabling it removes the only action
    /// that would resolve the situation. A sibling tool shipped exactly that
    /// bug — the first-run status is the never-registered one, so the switch was
    /// disabled precisely when enabling it was the whole point.
    public var isControlEnabled: Bool
    public var title: String
    /// Shown next to the control when there is something the user must still do.
    public var note: String?

    public static func make(status: LoginItemStatus) -> LoginItemPresentation {
        switch status {
        case .enabled:
            return LoginItemPresentation(
                isOn: true, isControlEnabled: true, title: "Open at Login", note: nil)
        case .requiresApproval:
            // Reporting a plain "on" here would promise something that does not
            // happen: the registration exists but the system will not honour it
            // until the user approves it.
            return LoginItemPresentation(
                isOn: true, isControlEnabled: true, title: "Open at Login",
                note: "approve in System Settings › Login Items")
        case .notRegistered, .notFound, .unknown:
            // Every ambiguous status folds to "not enabled yet", never to
            // "unavailable".
            return LoginItemPresentation(
                isOn: false, isControlEnabled: true, title: "Open at Login", note: nil)
        }
    }
}

public enum LoginItemOutcome: Equatable, Sendable {
    case succeeded(nowOn: Bool)
    case failed(String)
    /// No error was raised but the status did not move. Silence here is the
    /// worst outcome: the control snaps back and nothing explains why.
    case didNotChange(String)

    /// Compares the status before and after an attempted toggle.
    public static func evaluate(
        wanted: Bool, before: LoginItemStatus, after: LoginItemStatus, error: String?
    ) -> LoginItemOutcome {
        if let error { return .failed(error) }
        let isOn = LoginItemPresentation.make(status: after).isOn
        if isOn == wanted { return .succeeded(nowOn: isOn) }
        if before == after {
            return .didNotChange(
                wanted
                    ? "could not enable opening at login — the system did not register it"
                    : "could not disable opening at login — the registration is still present")
        }
        return .didNotChange("opening at login is now \(isOn ? "on" : "off"), which was not requested")
    }
}
