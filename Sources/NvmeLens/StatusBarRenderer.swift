import AppKit
import NvmeLensCore

/// Builds the status-item title: a coloured drive symbol followed by the pinned
/// temperatures.
///
/// The symbol carries severity. Punctuation glued onto the number ("!! 70°C")
/// has to be decoded; a colour is read without reading. This mirrors the sibling
/// status tool, which embeds SF Symbols as text attachments for the same reason.
@MainActor
enum StatusBarRenderer {
    static let labelFont = NSFont.systemFont(ofSize: 12, weight: .medium)

    /// The tint to burn into the symbol, or nil to leave it as a template.
    ///
    /// A menu-bar image should normally be a *template*: macOS then draws it to
    /// match the bar it is sitting in — light or dark, translucent over a
    /// wallpaper, inverted while a menu is open. Burning in `labelColor` instead
    /// applies the colour the app would use in its own windows, which is close
    /// enough to look like a mistake and different enough to read as grey.
    ///
    /// Only the states whose message *is* the colour get an explicit one.
    static func tint(for severity: AlertSeverity?, monitoring: Bool) -> NSColor? {
        guard monitoring else { return .tertiaryLabelColor }
        switch severity {
        case .critical: return .systemRed
        case .warning: return .systemOrange
        case nil: return nil  // template: let the menu bar decide
        }
    }

    /// Green is deliberately absent for the healthy case.
    ///
    /// A permanently green icon in a menu bar is noise: it is the state 99% of
    /// the time, so it teaches the eye to ignore the icon entirely — and then
    /// the one time it turns orange, nobody notices.
    static func textColor(for severity: AlertSeverity?, monitoring: Bool) -> NSColor {
        tint(for: severity, monitoring: monitoring) ?? .labelColor
    }

    /// Verified to exist on the deployment target. A name that does not resolve
    /// falls back to a bullet, which would silently make the menu bar useless —
    /// `internaldrive.fill.badge.exclamationmark` reads plausibly and is not a
    /// real symbol.
    static func symbolName(for severity: AlertSeverity?, monitoring: Bool) -> String {
        guard monitoring else { return "internaldrive" }
        switch severity {
        case .critical: return "externaldrive.fill.badge.exclamationmark"
        case .warning: return "internaldrive.fill"
        case nil: return "internaldrive"
        }
    }

    /// Every name this renderer can produce, so a test can assert they resolve.
    static let allSymbolNames = [
        symbolName(for: nil, monitoring: false),
        symbolName(for: nil, monitoring: true),
        symbolName(for: .warning, monitoring: true),
        symbolName(for: .critical, monitoring: true),
    ]

    /// Menu-bar icon size. Smaller than this reads as thin next to the system's
    /// own items.
    static let symbolPointSize: CGFloat = 14

    /// Applies the symbol and text to the status item's button.
    ///
    /// The symbol goes in `button.image`, not into an `NSTextAttachment` inside
    /// an attributed title. `isTemplate` is honoured for a button's image and
    /// ignored for an image embedded in text — which is why the untinted symbol
    /// still came out grey: it was being drawn with whatever colour it carried
    /// instead of being recoloured to match the bar.
    static func apply(to button: NSStatusBarButton, presentation: MenuBarPresentation) {
        let monitoring = !presentation.drives.isEmpty
        let severity = presentation.overallSeverity
        let symbolTint = tint(for: severity, monitoring: monitoring)

        button.image = image(
            named: symbolName(for: severity, monitoring: monitoring), tint: symbolTint)
        button.imagePosition = presentation.title.isEmpty ? .imageOnly : .imageLeading
        button.imageHugsTitle = true

        if presentation.title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        if let symbolTint {
            button.attributedTitle = NSAttributedString(
                string: " " + presentation.title,
                attributes: [.font: labelFont, .foregroundColor: symbolTint])
        } else {
            // No explicit colour: the button draws the title in the menu bar's
            // own colour, matching the template image beside it.
            button.title = " " + presentation.title
            button.font = labelFont
        }
    }

    static func image(named name: String, tint: NSColor?) -> NSImage? {
        var configuration = NSImage.SymbolConfiguration(
            pointSize: symbolPointSize, weight: .regular)
        if let tint {
            configuration = configuration.applying(.init(paletteColors: [tint]))
        }
        guard
            let image = NSImage(systemSymbolName: name, accessibilityDescription: name)?
                .withSymbolConfiguration(configuration)
        else { return nil }
        // Template only when no tint was chosen: a template is recoloured by the
        // menu bar, which would discard the orange or red that is the message in
        // the other states.
        image.isTemplate = (tint == nil)
        return image
    }
}
