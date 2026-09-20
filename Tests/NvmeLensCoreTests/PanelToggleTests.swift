import CoreGraphics
import XCTest
@testable import NvmeLensCore

final class StatusItemOwnsTests: XCTestCase {
    // The status item button's window as measured on macOS 27.0 (3840×2160, one
    // point per pixel): 69×30, flush with the top of the screen. Which of these
    // points open the panel when clicked was measured on the real app.
    private let frame = CGRect(x: 2014, y: 2130, width: 69, height: 30)

    func testCentreIsOwned() {
        XCTAssertTrue(statusItemOwns(CGPoint(x: 2048.5, y: 2145), itemWindowFrame: frame))
    }

    func testScreenTopRowIsOwned() {
        // Pointer pushed against the top edge: exactly frame.maxY, which
        // CGRect.contains leaves out.
        XCTAssertTrue(statusItemOwns(CGPoint(x: 2048.5, y: 2160), itemWindowFrame: frame))
        XCTAssertFalse(frame.contains(CGPoint(x: 2048.5, y: 2160)))
    }

    func testBottomRowIsOwnedButTheRowBelowTheMenuBarIsNot() {
        XCTAssertTrue(statusItemOwns(CGPoint(x: 2048.5, y: 2131), itemWindowFrame: frame))
        XCTAssertTrue(statusItemOwns(CGPoint(x: 2048.5, y: 2130.5), itemWindowFrame: frame))
        // frame.minY is the first row of the window under the menu bar, which
        // CGRect.contains lets in.
        XCTAssertFalse(statusItemOwns(CGPoint(x: 2048.5, y: 2130), itemWindowFrame: frame))
        XCTAssertTrue(frame.contains(CGPoint(x: 2048.5, y: 2130)))
    }

    func testLeftColumnIsOwned() {
        XCTAssertTrue(statusItemOwns(CGPoint(x: 2014, y: 2145), itemWindowFrame: frame))
        XCTAssertFalse(statusItemOwns(CGPoint(x: 2013, y: 2145), itemWindowFrame: frame))
    }

    func testLastColumnIsOwnedButTheNeighboursFirstColumnIsNot() {
        XCTAssertTrue(statusItemOwns(CGPoint(x: 2082, y: 2145), itemWindowFrame: frame))
        XCTAssertTrue(statusItemOwns(CGPoint(x: 2082.5, y: 2145), itemWindowFrame: frame))
        XCTAssertFalse(statusItemOwns(CGPoint(x: 2083, y: 2145), itemWindowFrame: frame))
    }

    func testElsewhereIsNotOwned() {
        XCTAssertFalse(statusItemOwns(CGPoint(x: 650, y: 236), itemWindowFrame: frame))
        // Same column, below the menu bar: the panel itself hangs there.
        XCTAssertFalse(statusItemOwns(CGPoint(x: 2048.5, y: 2000), itemWindowFrame: frame))
    }

    func testAnUnknownFrameOwnsNothing() {
        XCTAssertFalse(statusItemOwns(CGPoint(x: 2048.5, y: 2145), itemWindowFrame: nil))
        XCTAssertFalse(statusItemOwns(CGPoint(x: 0, y: 0), itemWindowFrame: .zero))
        XCTAssertFalse(statusItemOwns(CGPoint(x: 0, y: 0), itemWindowFrame: .null))
    }
}

final class PanelToggleTests: XCTestCase {
    func testActionTogglesWhenNothingElseIntervened() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(panelShown: false), .open)
        XCTAssertEqual(toggle.statusItemAction(panelShown: true), .close)
    }

    /// The defect: the monitor sees the click on our own status item first and
    /// closes the panel; the action that follows used to find it closed and open
    /// it again.
    func testReClickClosesAndTheActionThatFollowsDoesNotReopen() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.globalMouseDown(panelShown: true, onStatusItem: true), .close)
        XCTAssertTrue(toggle.needsMonitor(panelShown: false))
        XCTAssertEqual(toggle.statusItemAction(panelShown: false), .none)
        XCTAssertFalse(toggle.needsMonitor(panelShown: false))
        // The click after that one is an ordinary open.
        XCTAssertEqual(toggle.statusItemAction(panelShown: false), .open)
    }

    /// With a close animation the panel can still report itself shown when the
    /// action arrives; the click has done its work all the same.
    func testTheFollowingActionIsDroppedEvenIfThePanelStillReportsShown() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.globalMouseDown(panelShown: true, onStatusItem: true), .close)
        XCTAssertEqual(toggle.statusItemAction(panelShown: true), .none)
    }

    func testOutsideClickClosesAndLeavesTheNextActionAlone() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.globalMouseDown(panelShown: true, onStatusItem: false), .close)
        XCTAssertFalse(toggle.needsMonitor(panelShown: false))
        XCTAssertEqual(toggle.statusItemAction(panelShown: false), .open)
    }

    /// When nvme-lens is the active app the action of a re-click sometimes never
    /// arrives (measured). The note must not swallow the next click instead.
    func testAnActionThatNeverCameIsForgottenAtTheNextMouseDownOnTheItem() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.globalMouseDown(panelShown: true, onStatusItem: true), .close)
        // No action. The monitor is still installed and sees the next click.
        XCTAssertEqual(toggle.globalMouseDown(panelShown: false, onStatusItem: true), .none)
        XCTAssertFalse(toggle.needsMonitor(panelShown: false))
        XCTAssertEqual(toggle.statusItemAction(panelShown: false), .open)
    }

    func testAnActionThatNeverCameIsForgottenAtTheNextMouseDownElsewhere() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.globalMouseDown(panelShown: true, onStatusItem: true), .close)
        XCTAssertEqual(toggle.globalMouseDown(panelShown: false, onStatusItem: false), .none)
        XCTAssertFalse(toggle.needsMonitor(panelShown: false))
        XCTAssertEqual(toggle.statusItemAction(panelShown: false), .open)
    }

    /// Where clicks on the item never reach a global monitor, no note is ever
    /// taken: an outside click followed by a click on the item opens the panel.
    func testWithoutTheMonitorSeeingItemClicksThisIsAPlainToggle() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(panelShown: false), .open)
        XCTAssertEqual(toggle.globalMouseDown(panelShown: true, onStatusItem: false), .close)
        XCTAssertEqual(toggle.statusItemAction(panelShown: false), .open)
        XCTAssertEqual(toggle.statusItemAction(panelShown: true), .close)
        XCTAssertEqual(toggle.statusItemAction(panelShown: false), .open)
    }

    func testMonitorIsNeededWhileShownOrWhileAnActionIsAwaited() {
        var toggle = PanelToggle()
        XCTAssertFalse(toggle.needsMonitor(panelShown: false))
        XCTAssertTrue(toggle.needsMonitor(panelShown: true))
        _ = toggle.globalMouseDown(panelShown: true, onStatusItem: true)
        XCTAssertTrue(toggle.needsMonitor(panelShown: false))
        _ = toggle.statusItemAction(panelShown: false)
        XCTAssertFalse(toggle.needsMonitor(panelShown: false))
    }
}
