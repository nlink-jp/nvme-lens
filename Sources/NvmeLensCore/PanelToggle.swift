import CoreGraphics
import Foundation

/// Whether a mouse-down at `location` landed on the status item.
///
/// Both arguments are in screen coordinates (bottom-left origin): the location a
/// global event monitor is handed, and the frame of the status item button's
/// window *read at the time of the click* — the item's width follows its
/// content, so a cached frame goes stale.
///
/// The region is the one measured on macOS 27.0: the item owns the pixels of
/// that window and nothing else, with the top-left convention the pointer uses.
/// The screen's top row — where a pointer pushed against the edge sits, and
/// which is exactly `frame.maxY` here — belongs to the item; `frame.minY` is the
/// first row of whatever is below the menu bar, and `frame.maxX` the first
/// column of the neighbouring item. `CGRect.contains` gets both vertical edges
/// the wrong way round.
public func statusItemOwns(_ location: CGPoint, itemWindowFrame frame: CGRect?) -> Bool {
    guard let frame, !frame.isNull, !frame.isEmpty else { return false }
    let fromLeft = location.x - frame.minX
    let fromTop = frame.maxY - location.y
    return fromLeft >= 0 && fromLeft < frame.width && fromTop >= 0 && fromTop < frame.height
}

/// Decides what a click does, and keeps the one fact no AppKit reading gives in
/// time: whether the panel is up.
///
/// Everything below was measured on macOS 27.0 (2026-09-21) on this app, with
/// the clicks synthesised and every event logged.
///
/// **No reading of the panel can be trusted when a click arrives.**
/// `NSPopover.isShown` stays true for about half a second after a close, until
/// `popoverDidClose` — and that report arrives after a show that followed it, so
/// the delegate callback cannot be believed on its own either. The panel
/// window's `isVisible` goes false at once, but it is also false between a show
/// and the moment the panel appears, because AppKit queues a show that starts
/// during a close animation behind it (about 0.4 s). Deciding from `isShown` is
/// what users reported: a click inside that half second was read as "the panel
/// is open" and closed it again, so the panel did not open. Nothing here reads
/// the panel.
///
/// **The panel can only be opened from the button's action.** A show issued from
/// the global monitor, on the mouse-down or on the mouse-up, was dismissed by
/// AppKit within the same click (measured: `popoverDidClose` some 600 ms later,
/// every time). So the action opens, and the monitor's part is to dismiss.
///
/// **One click produces two events, and the second one often does not come.**
/// The menu bar is hosted by another process, so a click on our own item reaches
/// the global monitor first and the action 23–41 ms later — when it arrives at
/// all: of eight well-separated clicks, all eight were monitored and five
/// produced an action, the missing ones being clicks that closed the panel. So
/// an action arriving within `actionWindow` of the monitor closing the panel for
/// a click on the item is that click's second event, and does nothing; later
/// than that it is a click of its own. The window is kept small for a reason:
/// two clicks in quick succession must not be taken for one.
public struct PanelToggle: Equatable, Sendable {
    /// How long after the monitor closes the panel for a click on the item an
    /// action still belongs to that click. Measured 23–41 ms; a re-click a
    /// tenth of a second later has to be its own click, which is the case users
    /// reported.
    public static let actionWindow: TimeInterval = 0.1

    /// Whether the panel is up, as this app has left it — not what the panel
    /// reports (see above).
    public private(set) var isUp = false
    /// When the monitor last closed the panel for a click on our own item.
    public private(set) var closedByClickOnItem: Date?
    /// Closes this app asked for whose `popoverDidClose` has not arrived. Their
    /// reports say nothing new: the state was set when the close was asked for.
    public private(set) var unreportedCloses = 0

    public enum Effect: Equatable, Sendable {
        case open
        case close
        case none
    }

    public init() {}

    /// A mouse-down seen by the global monitor. Its part is to dismiss: a panel
    /// that is up is closed, whether the click was on our own item or anywhere
    /// else. Nothing is opened from here.
    public mutating func globalMouseDown(onStatusItem: Bool, at now: Date) -> Effect {
        guard isUp else { return .none }
        closedByClickOnItem = onStatusItem ? now : nil
        return closed()
    }

    /// The status item button's action — the only way the panel opens.
    public mutating func statusItemAction(at now: Date) -> Effect {
        let closedByThisClick = closedByClickOnItem.map {
            now.timeIntervalSince($0) < Self.actionWindow
        } ?? false
        closedByClickOnItem = nil
        if closedByThisClick { return .none }
        if isUp { return closed() }
        isUp = true
        return .open
    }

    /// A close this app makes for a reason of its own — opening another window,
    /// following a link out of the panel.
    public mutating func closeFromApp() -> Effect {
        guard isUp else { return .none }
        closedByClickOnItem = nil
        return closed()
    }

    /// `popoverDidClose`. A report of one of our own closes carries no news and
    /// is consumed; any other means something else closed the panel — a
    /// `.transient` dismissal, the Escape key — and is believed.
    public mutating func panelReportedClose() {
        if unreportedCloses > 0 {
            unreportedCloses -= 1
            return
        }
        isUp = false
    }

    private mutating func closed() -> Effect {
        isUp = false
        unreportedCloses += 1
        return .close
    }
}
