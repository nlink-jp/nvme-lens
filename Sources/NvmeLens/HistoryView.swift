import Charts
import NvmeLensCore
import SwiftUI

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
        .frame(minWidth: 640, minHeight: 460)
        .onAppear {
            if serial.isEmpty { serial = drives.first?.serialNumber ?? "" }
        }
    }

    private var controls: some View {
        HStack {
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

            Text("Range")
                // Without this the label is handed no width by the HStack and
                // SwiftUI wraps it one character per line.
                .fixedSize()
            Picker("Range", selection: $window) {
                ForEach(TemperatureSeries.Window.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer()
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
