import Foundation
import Testing

@Suite("MenuBarApp source")
struct MenuBarAppSourceTests {
    private func source() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: root.appendingPathComponent("Sources/NvmeLens/MenuBarApp.swift"),
            encoding: .utf8)
    }

    /// `NSEvent.removeMonitor` over-releases a monitor it is handed twice, and
    /// nothing in the unit tests can run the path that did it: quitting from the
    /// panel removed the monitor in `applicationWillTerminate`, kept the
    /// reference, and removed it again when the closing panel reported
    /// `popoverDidClose` — a segmentation fault on the way out. One removal site
    /// that also drops the reference cannot do that; a second site can.
    @Test("the outside-click monitor is removed in exactly one place")
    func monitorHasOneRemovalSite() throws {
        let calls = try source().components(separatedBy: "NSEvent.removeMonitor(").count - 1
        #expect(calls == 1)
    }

    @Test("that place drops the reference it removed")
    func removalDropsTheReference() throws {
        let text = try source()
        let site = try #require(text.range(of: "NSEvent.removeMonitor("))
        let after = text[site.upperBound...].prefix(120)
        #expect(after.contains("outsideClickMonitor = nil"))
    }
}
