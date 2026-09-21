import CoreGraphics
import XCTest
@testable import NvmeLensCore

final class StatusItemOwnsTests: XCTestCase {
    // The status item button's window as measured on macOS 27.0 (3840×2160, one
    // point per pixel): flush with the top of the screen.
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
        XCTAssertTrue(statusItemOwns(CGPoint(x: 2048.5, y: 2130.5), itemWindowFrame: frame))
        // frame.minY is the first row under the menu bar, which contains lets in.
        XCTAssertFalse(statusItemOwns(CGPoint(x: 2048.5, y: 2130), itemWindowFrame: frame))
        XCTAssertTrue(frame.contains(CGPoint(x: 2048.5, y: 2130)))
    }

    func testTheNeighboursFirstColumnIsNotOwned() {
        XCTAssertTrue(statusItemOwns(CGPoint(x: 2014, y: 2145), itemWindowFrame: frame))
        XCTAssertFalse(statusItemOwns(CGPoint(x: 2013, y: 2145), itemWindowFrame: frame))
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
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ ms: Double) -> Date { t0.addingTimeInterval(ms / 1000) }

    func testTheActionOpensAndCloses() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(at: at(0)), .open)
        XCTAssertTrue(toggle.isUp)
        XCTAssertEqual(toggle.statusItemAction(at: at(900)), .close)
        XCTAssertFalse(toggle.isUp)
    }

    func testTheMonitorDismissesAndOpensNothing() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.globalMouseDown(onStatusItem: false, at: at(0)), .none,
                       "nothing is up, so there is nothing to dismiss")
        XCTAssertEqual(toggle.statusItemAction(at: at(100)), .open)
        XCTAssertEqual(toggle.globalMouseDown(onStatusItem: false, at: at(200)), .close)
        XCTAssertFalse(toggle.isUp)
        XCTAssertEqual(toggle.globalMouseDown(onStatusItem: true, at: at(300)), .none,
                       "and a click on the item opens nothing from here")
    }

    /// One click on the item while the panel is up: the monitor dismisses it,
    /// and the button's action — 23–41 ms behind, when it comes at all — must
    /// not open it again.
    func testTheActionOfTheClickThatDismissedThePanelDoesNothing() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(at: at(0)), .open)
        XCTAssertEqual(toggle.globalMouseDown(onStatusItem: true, at: at(900)), .close)
        XCTAssertEqual(toggle.statusItemAction(at: at(935)), .none)
        XCTAssertFalse(toggle.isUp)
    }

    /// What users reported: after the panel closed, clicking the item again
    /// right away did nothing. Nothing here reads the panel, so the re-click is
    /// an ordinary open — verified on the real app at 130 ms and 200 ms, 10 out
    /// of 10 each.
    func testAReClickAfterADismissalOpensThePanel() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(at: at(0)), .open)
        XCTAssertEqual(toggle.globalMouseDown(onStatusItem: true, at: at(900)), .close)
        XCTAssertEqual(toggle.statusItemAction(at: at(935)), .none)

        // The re-click, inside the half second in which the panel still reports
        // itself shown and before any close has been reported.
        XCTAssertEqual(toggle.globalMouseDown(onStatusItem: true, at: at(1030)), .none)
        XCTAssertEqual(toggle.statusItemAction(at: at(1065)), .open)
        XCTAssertTrue(toggle.isUp)
    }

    /// An action that arrives after the window is a click of its own — which is
    /// how the keyboard and assistive software reach the item, and how a click
    /// the monitor did not see still works.
    func testAnActionAfterTheWindowIsItsOwnActivation() {
        var inside = PanelToggle()
        XCTAssertEqual(inside.statusItemAction(at: at(0)), .open)
        XCTAssertEqual(inside.globalMouseDown(onStatusItem: true, at: at(900)), .close)
        XCTAssertEqual(
            inside.statusItemAction(at: at(900) + PanelToggle.actionWindow / 2), .none)

        var outside = PanelToggle()
        XCTAssertEqual(outside.statusItemAction(at: at(0)), .open)
        XCTAssertEqual(outside.globalMouseDown(onStatusItem: true, at: at(900)), .close)
        XCTAssertEqual(
            outside.statusItemAction(at: at(900) + PanelToggle.actionWindow * 2), .open)
    }

    func testTheWindowCoversTheGapThatWasMeasuredAndNoRealSecondClick() {
        XCTAssertGreaterThan(PanelToggle.actionWindow, 0.041, "the action arrives 23–41 ms behind")
        XCTAssertLessThanOrEqual(PanelToggle.actionWindow, 0.13,
                                 "a re-click 130 ms later is a click of its own (measured)")
    }

    /// A click elsewhere dismissed the panel, so the next click on the item is
    /// an open and its action must not be taken for the dismissed click's.
    func testTheActionAfterAnOutsideDismissalOpens() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(at: at(0)), .open)
        XCTAssertEqual(toggle.globalMouseDown(onStatusItem: false, at: at(900)), .close)
        XCTAssertEqual(toggle.statusItemAction(at: at(930)), .open)
    }

    /// `popoverDidClose` arrives about half a second after the close — measured,
    /// and pinned by `PopoverReadingsTests` — so it can land after the panel has
    /// been opened again. Believing it would leave the record saying "closed"
    /// while the panel is up, and the next click would try to close what is
    /// already closed: another click that does nothing.
    func testTheLateReportOfOurOwnCloseDoesNotUnsayAnOpenSince() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(at: at(0)), .open)
        XCTAssertEqual(toggle.globalMouseDown(onStatusItem: true, at: at(900)), .close)
        XCTAssertEqual(toggle.statusItemAction(at: at(1065)), .open)

        toggle.panelReportedClose()   // the close at 900 ms, reported at last
        XCTAssertTrue(toggle.isUp, "the panel that was opened since is still up")
        XCTAssertEqual(toggle.statusItemAction(at: at(2000)), .close, "and one click closes it")
    }

    /// A close this app did not make — `.transient`, the Escape key — is the one
    /// report that carries news.
    func testACloseTheAppDidNotMakeIsBelieved() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(at: at(0)), .open)
        toggle.panelReportedClose()
        XCTAssertFalse(toggle.isUp)
        XCTAssertEqual(toggle.statusItemAction(at: at(900)), .open,
                       "the next click opens, it does not close")
    }

    func testEachOfOurClosesConsumesExactlyOneReport() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(at: at(0)), .open)
        XCTAssertEqual(toggle.statusItemAction(at: at(900)), .close)
        XCTAssertEqual(toggle.statusItemAction(at: at(1800)), .open)
        XCTAssertEqual(toggle.statusItemAction(at: at(2700)), .close)
        toggle.panelReportedClose()
        toggle.panelReportedClose()
        XCTAssertEqual(toggle.unreportedCloses, 0)
        XCTAssertEqual(toggle.statusItemAction(at: at(3600)), .open)
        // A third report belongs to nothing of ours, so it is believed.
        toggle.panelReportedClose()
        XCTAssertFalse(toggle.isUp)
    }

    func testTheAppsOwnCloseIsNoEffectWhenNothingIsUp() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.closeFromApp(), .none)
        XCTAssertEqual(toggle.unreportedCloses, 0, "no report to consume, so none is expected")
        XCTAssertEqual(toggle.statusItemAction(at: at(0)), .open)
        XCTAssertEqual(toggle.closeFromApp(), .close)
        XCTAssertFalse(toggle.isUp)
        XCTAssertEqual(toggle.statusItemAction(at: at(30)), .open,
                       "a close this app made does not swallow the next click")
    }

    /// The residual, measured on the real app: at a 60–100 ms gap the panel
    /// ended up closed once in ten, because the dismissed click's action can
    /// arrive after the window and be taken for a click of its own. Two clicks
    /// that fast are one gesture, and the alternative — a longer window —
    /// swallows the re-click, which is the defect being fixed.
    func testAVeryFastDoubleClickCanEndUpClosed() {
        var toggle = PanelToggle()
        XCTAssertEqual(toggle.statusItemAction(at: at(0)), .open)
        XCTAssertEqual(toggle.globalMouseDown(onStatusItem: true, at: at(900)), .close)
        // The dismissed click's action, late:
        XCTAssertEqual(toggle.statusItemAction(at: at(900) + PanelToggle.actionWindow * 1.1), .open)
        // The re-click's own action then closes it again.
        XCTAssertEqual(toggle.statusItemAction(at: at(1040)), .close)
    }
}
