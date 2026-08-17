import AppKit
import Testing

@testable import NvmeLens
@testable import NvmeLensCore

@Suite("StatusBarRenderer")
@MainActor
struct StatusBarRendererTests {
    /// A symbol name that does not resolve falls back to a bullet, which is a
    /// silent failure in the one place the user always looks. One of these was
    /// wrong on the first attempt and read entirely plausibly.
    @Test("every symbol the renderer can emit exists on this system")
    func symbolsResolve() {
        for name in StatusBarRenderer.allSymbolNames {
            #expect(
                NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                "missing SF Symbol: \(name)")
        }
    }

    /// Green for healthy would be lit 99% of the time, teaching the eye to skip
    /// the icon — and then the one time it turns orange nobody notices.
    @Test("only the states that need attention take a colour")
    func healthyIsNotTinted() {
        // nil tint means the symbol ships as a template and the menu bar draws
        // it to match itself. Burning in labelColor made it read as grey.
        #expect(StatusBarRenderer.tint(for: nil, monitoring: true) == nil)
        #expect(StatusBarRenderer.tint(for: .warning, monitoring: true) == .systemOrange)
        #expect(StatusBarRenderer.tint(for: .critical, monitoring: true) == .systemRed)
        #expect(StatusBarRenderer.tint(for: nil, monitoring: false) == .tertiaryLabelColor)
        #expect(StatusBarRenderer.textColor(for: nil, monitoring: true) == .labelColor)
    }

    /// The reason the healthy icon still looked grey after the first fix:
    /// `isTemplate` is honoured for a button's image and ignored for an image
    /// embedded in an attributed string, so the symbol has to go in the image
    /// slot to be recoloured by the menu bar.
    @Test("the healthy symbol ships as a template, the coloured ones do not")
    func templateOnlyWhenUntinted() throws {
        let healthy = try #require(
            StatusBarRenderer.image(
                named: StatusBarRenderer.symbolName(for: nil, monitoring: true), tint: nil))
        #expect(healthy.isTemplate)

        let warning = try #require(
            StatusBarRenderer.image(
                named: StatusBarRenderer.symbolName(for: .warning, monitoring: true),
                tint: .systemOrange))
        #expect(!warning.isTemplate)
    }

    @Test("an unknown symbol yields no image rather than a wrong one")
    func unknownSymbol() {
        #expect(StatusBarRenderer.image(named: "not.a.real.symbol", tint: nil) == nil)
    }
}

@Suite("HistoryView sizing")
@MainActor
struct HistoryViewSizingTests {
    /// The default window opened at 720pt while the controls needed ~817pt, so
    /// the row overflowed until the user widened it by hand. The width is now
    /// derived from what the controls measure, with headroom — and the row wraps
    /// anyway, because a drive's model name is not something this tool bounds.
    /// A wrapping layout treats each child independently, so a label handed to
    /// it separately from its control can be stranded on the line above. Both
    /// remaining widths must therefore be for whole label+control units.
    @Test("the wrap unit is wide enough to hold a label with its control")
    func wrapUnitsKeepLabelsWithControls() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        // The widest single unit is the range label plus all four segments; the
        // window must never be narrower than one unit, or wrapping cannot help.
        let rangeUnit = width("Range") + 8
            + ["24 hours", "7 days", "30 days", "90 days"].map { width($0) + 24 }.reduce(0, +)
        #expect(HistoryView.minimumWidth >= rangeUnit + 32)
    }

    @Test("the preferred width clears what the controls actually measure")
    func preferredWidthFitsControls() {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func width(_ text: String) -> CGFloat {
            (text as NSString).size(withAttributes: [.font: font]).width
        }
        let popupChrome: CGFloat = 34, labelGap: CGFloat = 8, segmentPadding: CGFloat = 24

        let drive = width("Drive") + labelGap + width("WD_BLACK SN770 1TB") + popupChrome
        let metric = width("Metric") + labelGap + width("Unsafe shutdowns") + popupChrome
        let range = width("Range") + labelGap
        let segments = ["24 hours", "7 days", "30 days", "90 days"]
            .map { width($0) + segmentPadding }.reduce(0, +)
        let required = 32 + drive + 8 + metric + 8 + range + segments

        #expect(HistoryView.preferredWidth >= required)
        // The floor is deliberately below that: the row wraps, so a narrower
        // window is usable rather than broken.
        #expect(HistoryView.minimumWidth < required)
    }
}
