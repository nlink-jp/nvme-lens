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
