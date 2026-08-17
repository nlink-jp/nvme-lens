import AppKit
import NvmeLensCore

/// Draws a temperature history sparkline for one drive inside a menu item.
///
/// Hosted in the panel through `NSViewRepresentable`. Everything is drawn
/// relative to `bounds`, so the layout follows whatever size SwiftUI hands it
/// rather than assuming one.
final class SparklineView: NSView {
    // Mutable, and reassigned on every update. Holding these as `let` meant the
    // view drew whatever it was constructed with for the rest of its life: the
    // panel's graph froze at the first sample and never moved again. It only
    // looked correct in development because restarting the app rebuilt the view.
    private var summary: TemperatureSeries.Summary
    private var title: String
    private var caption: String
    private var gapNote: String?
    private var warningCelsius: Int?

    /// The height the panel gives this view. Named here, next to the layout
    /// that divides it, so the caption row and the plot cannot be sized against
    /// two different numbers.
    static let defaultHeight: CGFloat = 92
    /// Only the initial frame; SwiftUI resizes it to the panel's width.
    static let preferredSize = NSSize(width: 330, height: defaultHeight)

    init(
        title: String, summary: TemperatureSeries.Summary, windowLabel: String,
        warningCelsius: Int?
    ) {
        self.summary = summary
        self.title = title
        self.caption = summary.caption(windowLabel: windowLabel)
        self.gapNote = summary.gapNote
        self.warningCelsius = warningCelsius
        super.init(frame: NSRect(origin: .zero, size: Self.preferredSize))
    }

    required init?(coder: NSCoder) { nil }

    /// What the view will draw next. Exposed so a test can assert that an update
    /// actually reached the view, rather than only that a redraw was requested.
    var renderedSummary: TemperatureSeries.Summary { summary }
    var renderedTitle: String { title }
    var renderedCaption: String { caption }

    /// Called by the SwiftUI wrapper whenever the model produces new data.
    func update(
        title: String, summary: TemperatureSeries.Summary, windowLabel: String,
        warningCelsius: Int?
    ) {
        self.title = title
        self.summary = summary
        self.caption = summary.caption(windowLabel: windowLabel)
        self.gapNote = summary.gapNote
        self.warningCelsius = warningCelsius
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 14
        let textColor = NSColor.labelColor
        let secondary = NSColor.secondaryLabelColor

        // The card above already names the drive, so the title row is only
        // drawn when this view is used standalone. Reserving it unconditionally
        // is what left the plot with ten points of height.
        var topReserved: CGFloat = 4
        if !title.isEmpty {
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: textColor,
            ]
            title.draw(at: NSPoint(x: inset, y: bounds.height - 18), withAttributes: titleAttributes)
            topReserved = 22
        }

        let captionAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: secondary,
        ]
        caption.draw(at: NSPoint(x: inset, y: 4), withAttributes: captionAttributes)
        if let gapNote {
            // Right-aligned against the measured string. Drawing it at a fixed
            // offset is what pushed it past the view's edge before.
            let noteAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]
            let noteWidth = (gapNote as NSString).size(withAttributes: noteAttributes).width
            let captionWidth = (caption as NSString).size(withAttributes: captionAttributes).width
            let x = bounds.width - inset - noteWidth
            // Only draw it if it clears the caption; a collision would be worse
            // than omitting a secondary note.
            if x > inset + captionWidth + 8 {
                gapNote.draw(at: NSPoint(x: x, y: 4), withAttributes: noteAttributes)
            }
        }

        let graph = NSRect(
            x: inset, y: 20, width: bounds.width - inset * 2,
            height: bounds.height - 20 - topReserved)

        // A plot well, so the trace reads as sitting inside a chart rather than
        // floating on the panel.
        let well = NSBezierPath(roundedRect: graph.insetBy(dx: -4, dy: -3), xRadius: 5, yRadius: 5)
        NSColor.quaternaryLabelColor.withAlphaComponent(0.16).setFill()
        well.fill()

        guard let low = summary.minCelsius, let high = summary.maxCelsius else { return }

        // Keep at least a 10-degree span so a flat trace does not become a
        // dramatic-looking line across the full height.
        let padded = max(10, high - low)
        let centre = Double(low + high) / 2
        let scaleLow = centre - Double(padded) / 2 - 1
        let scaleHigh = centre + Double(padded) / 2 + 1

        func y(_ celsius: Int) -> CGFloat {
            let ratio = (Double(celsius) - scaleLow) / (scaleHigh - scaleLow)
            return graph.minY + CGFloat(ratio) * graph.height
        }

        // The drive's own warning threshold, if it fits on the current scale.
        if let warningCelsius, Double(warningCelsius) > scaleLow,
            Double(warningCelsius) < scaleHigh
        {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: graph.minX, y: y(warningCelsius)))
            line.line(to: NSPoint(x: graph.maxX, y: y(warningCelsius)))
            line.setLineDash([2, 3], count: 2, phase: 0)
            NSColor.tertiaryLabelColor.setStroke()
            line.lineWidth = 1
            line.stroke()
        }

        let step = graph.width / CGFloat(max(1, summary.buckets.count))
        // Only the trace is coloured. Colouring every element would leave the
        // colour meaning nothing.
        NSColor.controlAccentColor.setStroke()
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()

        // A run of consecutive populated buckets is one stroked path; an empty
        // bucket ends the run. Bridging the gap would claim the tool was
        // running and the drive was at some temperature, when neither is known.
        var runStart = 0
        while runStart < summary.buckets.count {
            guard !summary.buckets[runStart].isEmpty else {
                runStart += 1
                continue
            }
            var runEnd = runStart
            while runEnd + 1 < summary.buckets.count, !summary.buckets[runEnd + 1].isEmpty {
                runEnd += 1
            }

            let path = NSBezierPath()
            let fill = NSBezierPath()
            for index in runStart...runEnd {
                guard let value = summary.buckets[index].maxCelsius else { continue }
                let point = NSPoint(x: graph.minX + (CGFloat(index) + 0.5) * step, y: y(value))
                if index == runStart {
                    path.move(to: point)
                    fill.move(to: NSPoint(x: point.x, y: graph.minY))
                    fill.line(to: point)
                } else {
                    path.line(to: point)
                    fill.line(to: point)
                }
            }
            if runEnd > runStart {
                fill.line(
                    to: NSPoint(
                        x: graph.minX + (CGFloat(runEnd) + 0.5) * step, y: graph.minY))
                fill.close()
                fill.fill()
            }
            path.lineWidth = 1.5
            path.lineJoinStyle = .round
            path.stroke()

            runStart = runEnd + 1
        }
    }
}
