import Charts
import NvmeLensCore
import SwiftUI

/// Lays its children out in a row, wrapping to the next line when they do not
/// fit.
///
/// An `HStack` of fixed-size controls simply overflows its window, and the
/// widths here depend on drive model names, which this tool does not control.
private struct FlowControls: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0, rowHeight: CGFloat = 0
        var total = CGSize.zero
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > maxWidth {
                total.width = max(total.width, rowWidth)
                total.height += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += (rowWidth > 0 ? spacing : 0) + size.width
            rowHeight = max(rowHeight, size.height)
        }
        total.width = max(total.width, rowWidth)
        total.height += rowHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The window that makes the retained history reachable.
///
/// The panel deliberately shows six hours: it is a glance, not a study. But the
/// store keeps months, and a chart nobody can widen means that data exists only
/// in a file — collected, paid for in samples, and unreadable.
struct HistoryView: View {
    @ObservedObject var model: AppModel
    @State private var serial: String = ""
    @State private var window: TemperatureSeries.Window = .week
    @State private var metric: HistoryMetric = .temperature

    private var drives: [MenuBarPresentation.DriveEntry] { model.presentation.drives }

    private var selected: MenuBarPresentation.DriveEntry? {
        drives.first { $0.serialNumber == serial } ?? drives.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            controls
            if let drive = selected {
                content(for: drive)
            } else {
                ContentUnavailableView(
                    "No monitorable drive",
                    systemImage: "externaldrive.badge.questionmark",
                    description: Text(
                        "Nothing to chart yet. Drives attached over USB cannot be read at all; see Settings for what was detected."
                    ))
                .frame(maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(minWidth: Self.minimumWidth, idealWidth: Self.preferredWidth, minHeight: 460)
        .onAppear {
            if serial.isEmpty { serial = drives.first?.serialNumber ?? "" }
        }
    }

    /// Measured, not guessed: the pickers alone need ~820pt with the drive names
    /// seen so far, and a drive's model name is not ours to bound — a longer one
    /// would overflow any width chosen today. The row wraps instead.
    static let preferredWidth: CGFloat = 860
    static let minimumWidth: CGFloat = 560

    private var controls: some View {
        // ViewThatFits would silently drop controls; a wrapping layout keeps all
        // of them and costs a second line only when the names are long.
        FlowControls {
            Picker("Drive", selection: $serial) {
                ForEach(drives, id: \.serialNumber) { drive in
                    Text(drive.name).tag(drive.serialNumber)
                }
            }
            // No fixed width: a drive name longer than the ones attached today
            // would simply be truncated, and model names are not ours to bound.
            .fixedSize()

            Picker("Metric", selection: $metric) {
                ForEach(HistoryMetric.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .fixedSize()

            // The label and its control are one unit. Handed to the layout as
            // two children they wrapped apart, stranding "Range" on the line
            // above its own buttons. The other two pickers carry their labels
            // internally, which is why only this one split.
            HStack(spacing: 8) {
                Text("Range")
                    // Without this the label is handed no width and SwiftUI
                    // wraps it one character per line.
                    .fixedSize()
                Picker("Range", selection: $window) {
                    ForEach(TemperatureSeries.Window.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func content(for drive: MenuBarPresentation.DriveEntry) -> some View {
        let now = Date()
        let start = now.addingTimeInterval(-window.seconds)
        let points =
            (try? model.store.metricSeries(serial: drive.serialNumber, metric: metric, since: start))
            ?? []
        let summary = MetricSeries.summarize(
            points: points, from: start, to: now, bucketSeconds: window.bucketSeconds)
        let gaps = MetricSeries.gaps(in: summary, bucketSeconds: window.bucketSeconds)

        if summary.latest == nil {
            ContentUnavailableView(
                "Nothing recorded in this range",
                systemImage: "clock.badge.questionmark",
                description: Text(
                    "The application records while it is running. Open at Login keeps the history from breaking at every restart."
                ))
            .frame(maxHeight: .infinity)
        } else {
            chart(summary: summary, gaps: gaps)
            statistics(summary: summary, gaps: gaps, drive: drive, start: start)
        }
    }

    private func chart(summary: MetricSeries.Summary, gaps: [MetricSeries.Gap]) -> some View {
        let scale = MetricSeries.domain(summary, metric: metric)
        let warning = Double(model.configuration.temperature.warningCelsius)
        return Chart {
            // Shaded first so the trace draws over it. Gaps are marked rather
            // than smoothed: a line joined straight across an outage invents
            // readings that were never taken, and at ninety days a week-long
            // outage is invisible unless it is drawn.
            ForEach(gaps) { gap in
                RectangleMark(
                    xStart: .value("Gap start", gap.start), xEnd: .value("Gap end", gap.end)
                )
                .foregroundStyle(.gray.opacity(0.18))
            }
            ForEach(summary.buckets.indices, id: \.self) { index in
                if let high = summary.buckets[index].max, let low = summary.buckets[index].min {
                    // The band is only meaningful where a bucket holds a spread;
                    // a cumulative counter has none worth drawing.
                    if !metric.isCumulative {
                        AreaMark(
                            x: .value("Time", summary.buckets[index].start),
                            yStart: .value("Low", low), yEnd: .value("High", high)
                        )
                        .foregroundStyle(Color.accentColor.opacity(0.18))
                    }
                    LineMark(
                        x: .value("Time", summary.buckets[index].start),
                        y: .value(metric.label, high)
                    )
                    .foregroundStyle(Color.accentColor)
                }
            }
            // Drawn only when it belongs on this scale. Forcing a 78°C rule onto
            // a 37–43°C chart is what flattened the trace.
            if metric == .temperature, scale.contains(warning) {
                RuleMark(y: .value("Warning", warning))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.orange.opacity(0.7))
                    .annotation(position: .top, alignment: .leading) {
                        Text("warning").font(.caption2).foregroundStyle(.orange)
                    }
            }
        }
        .chartYScale(domain: scale)
        .chartYAxisLabel(metric.unit)
        .frame(minHeight: 260)
    }

    private func statistics(
        summary: MetricSeries.Summary, gaps: [MetricSeries.Gap],
        drive: MenuBarPresentation.DriveEntry, start: Date
    ) -> some View {
        let wear = try? model.store.wearDelta(serial: drive.serialNumber, since: start)
        return HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.label).font(.caption).foregroundStyle(.secondary)
                if let low = summary.min, let high = summary.max {
                    // A counter's level says little; what it climbed by is the
                    // information, so that is what gets the prominent line.
                    Text(
                        metric.isCumulative
                            ? "+\(metric.format(high - low)) over the range"
                            : "\(metric.format(low))–\(metric.format(high))"
                    )
                    .font(.callout.monospacedDigit())
                }
                // Coverage is stated, not implied: a chart drawn from two hours
                // of a ninety-day window is not a ninety-day history.
                Text(String(format: "%.0f%% of the range recorded", summary.coverage * 100))
                    .font(.caption).foregroundStyle(.secondary)
                if !gaps.isEmpty {
                    Text("\(gaps.count) gap(s)").font(.caption).foregroundStyle(.secondary)
                }
                if metric == .temperature, let high = summary.max {
                    let warning = Double(model.configuration.temperature.warningCelsius)
                    Text(
                        high < warning
                            ? "\(Int(warning - high))°C below the \(Int(warning))°C warning"
                            : "at or above the \(Int(warning))°C warning"
                    )
                    .font(.caption).foregroundStyle(high < warning ? Color.secondary : Color.orange)
                }
            }
            if let wear = wear ?? nil {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Over this range").font(.caption).foregroundStyle(.secondary)
                    Text("+\(wear.percentageUsedDelta)% used")
                        .font(.callout.monospacedDigit())
                    Text("+\(wear.powerOnHoursDelta) h powered · +\(wear.powerCyclesDelta) cycles")
                        .font(.caption).foregroundStyle(.secondary)
                    if let rate = wear.powerCyclesPerHour, rate > 0 {
                        Text(String(format: "%.2f cycles per powered hour", rate))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if wear.mediaErrorsDelta > 0 {
                        Text("+\(wear.mediaErrorsDelta) media errors")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            Spacer()
        }
    }
}
