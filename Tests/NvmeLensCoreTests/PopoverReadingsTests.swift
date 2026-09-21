import AppKit
import XCTest

/// Pins the AppKit readings `PanelToggle` exists because of. Measured on
/// macOS 27.0 (2026-09-21); if a future macOS reports a close promptly, these
/// fail and the extra state in `PanelToggle` can go.
///
/// The host window is placed off every screen, so nothing appears on screen
/// while the suite runs. Skipped where there is no window server at all.
final class PopoverReadingsTests: XCTestCase {
    private var host: NSWindow!
    private var popover: NSPopover!
    private var delegate: CloseRecorder!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipIf(NSScreen.screens.isEmpty, "no window server")
        _ = NSApplication.shared
        host = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: 120, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: false)
        host.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 40))
        host.orderFrontRegardless()

        delegate = CloseRecorder()
        popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = delegate
        let content = NSViewController()
        content.view = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        popover.contentViewController = content
    }

    override func tearDown() {
        popover?.close()
        host?.orderOut(nil)
        super.tearDown()
    }

    private func show() {
        guard let anchor = host.contentView else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    private var panelWindowIsVisible: Bool {
        popover.contentViewController?.view.window?.isVisible ?? false
    }

    private func spin(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: deadline)
        }
    }

    /// The reading the app must not use: still "shown" long after the close.
    func testIsShownLagsACloseWhileTheWindowDoesNot() throws {
        show()
        try XCTSkipUnless(popover.isShown, "the popover did not open in this environment")
        XCTAssertTrue(panelWindowIsVisible)

        popover.performClose(nil)
        XCTAssertFalse(panelWindowIsVisible, "the window goes at once")
        XCTAssertTrue(popover.isShown, "isShown does not — this is why the app keeps its own record")

        spin(0.25)
        XCTAssertTrue(popover.isShown, "still not prompt a quarter second later")
        XCTAssertEqual(delegate.closes, 0, "and no report yet either")
    }

    /// The report of one close arrives after a show that followed it, so a
    /// delegate callback cannot be believed on its own.
    func testACloseIsReportedAfterAShowThatFollowedIt() throws {
        show()
        try XCTSkipUnless(popover.isShown, "the popover did not open in this environment")
        popover.performClose(nil)
        spin(0.1)
        XCTAssertEqual(delegate.closes, 0, "the report has not come in 100 ms")

        show()  // the click that reopens it, inside the close animation
        spin(0.8)
        XCTAssertEqual(delegate.closes, 1, "it comes while the panel is up again")
    }

    private final class CloseRecorder: NSObject, NSPopoverDelegate {
        var closes = 0
        func popoverDidClose(_ notification: Notification) { closes += 1 }
    }
}
