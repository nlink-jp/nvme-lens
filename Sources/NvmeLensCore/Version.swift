import Foundation

/// The version this build reports.
///
/// The Makefile substitutes `git describe` output into `Info.plist` at bundle
/// time, so a released `.app` carries the real version and both the CLI and the
/// GUI read the same value. A bare `swift build` binary has no bundle
/// `Info.plist`, so it falls back to a development marker rather than lying
/// about a version that was never tagged.
public enum Version {
    public static let developmentFallback = "0.0.0-dev"

    public static var current: String {
        resolve(bundleValue: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
    }

    /// Pure resolution step, split out so the fallback behaviour is testable
    /// without constructing a bundle.
    public static func resolve(bundleValue: String?) -> String {
        guard let bundleValue else { return developmentFallback }
        let trimmed = bundleValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // An unsubstituted Makefile placeholder must not reach the user as if
        // it were a version.
        if trimmed.isEmpty || trimmed.hasPrefix("${") { return developmentFallback }
        return trimmed
    }
}
