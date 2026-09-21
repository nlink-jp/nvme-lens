import XCTest

/// The app layer's part of the rule, machine-checked: `PanelToggle` can only
/// keep the record straight if nothing decides from `NSPopover.isShown`, which
/// lags a close by about half a second (`PopoverReadingsTests` pins that).
/// A click inside that half second is what users reported as "the panel does
/// not open".
final class PanelReadingRuleTests: XCTestCase {
    func testTheAppDoesNotDecideFromIsShown() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // the test directory
            .deletingLastPathComponent()      // Tests/
            .deletingLastPathComponent()      // the repository
            .appendingPathComponent("Sources/NvmeLens/MenuBarApp.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertTrue(text.contains("PanelToggle"), "wrong file, or the toggle was removed")

        for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let code = line.prefix(while: { _ in true })
            guard !code.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
            XCTAssertFalse(code.contains("popover.isShown"),
                           "line \(number + 1) decides from a reading that lags: \(code)")
        }
    }
}
