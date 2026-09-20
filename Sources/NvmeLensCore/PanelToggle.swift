import CoreGraphics
import Foundation

/// Whether a mouse-down at `location` landed on the status item.
///
/// Both arguments are in screen coordinates (bottom-left origin): the location a
/// global event monitor is handed, and the frame of the status item button's
/// window *read at the time of the click* — the item is as wide as its text, so
/// a cached frame goes stale within a sampling interval.
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

/// Arbitrates between the two things that react to one click on the status item
/// while the panel is open.
///
/// On macOS 27.0 the menu bar is hosted by another process, so a click on our
/// own status item reaches the *global* mouse-down monitor first and the
/// button's action a few tens of milliseconds later — or, when nvme-lens is the
/// active app, sometimes never. Letting both act on `isShown` closes the panel
/// and opens it again. The two events cannot be matched by identity (the action
/// runs under a synthesized mouse-up that carries no event number), so they are
/// matched by order: the monitor closes the panel and notes that the click was
/// on the item, and the next action is that click's and is dropped. If no
/// action comes, the note is void as soon as another mouse-down is seen, which
/// is why the monitor outlives the panel until then.
///
/// Where a click on the item never reaches a global monitor, the note is never
/// taken and this reduces to a plain toggle.
public struct PanelToggle: Equatable, Sendable {
    /// A mouse-down on the status item closed the panel, and that click's action
    /// has not arrived yet.
    public private(set) var awaitingActionOfClosingClick = false

    public enum Effect: Equatable, Sendable {
        case open
        case close
        case none
    }

    public init() {}

    /// A mouse-down seen by the global monitor.
    public mutating func globalMouseDown(panelShown: Bool, onStatusItem: Bool) -> Effect {
        guard panelShown else {
            // The monitor is only still here because an action was awaited, and a
            // new click has begun: that action is not coming any more.
            awaitingActionOfClosingClick = false
            return .none
        }
        awaitingActionOfClosingClick = onStatusItem
        return .close
    }

    /// The status item button's action.
    public mutating func statusItemAction(panelShown: Bool) -> Effect {
        if awaitingActionOfClosingClick {
            awaitingActionOfClosingClick = false
            return .none
        }
        return panelShown ? .close : .open
    }

    /// The monitor is needed while the panel is shown, and afterwards for as long
    /// as a closing click's action may still arrive.
    public func needsMonitor(panelShown: Bool) -> Bool {
        panelShown || awaitingActionOfClosingClick
    }
}
