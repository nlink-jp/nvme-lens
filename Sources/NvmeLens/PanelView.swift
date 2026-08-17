import NvmeLensCore
import SwiftUI

/// Wraps the existing AppKit sparkline so its gap handling and threshold line
/// are not reimplemented.
private struct Sparkline: NSViewRepresentable {
    let title: String
    let summary: TemperatureSeries.Summary
    let warningCelsius: Int?

    func makeNSView(context: Context) -> SparklineView {
        SparklineView(
            title: title, summary: summary, windowLabel: AppModel.graphWindowLabel,
            warningCelsius: warningCelsius)
    }

    func updateNSView(_ view: SparklineView, context: Context) {
        // Hand the new values over. Marking the view dirty without them just
        // redraws the data it was built with.
        view.update(
            title: title, summary: summary, windowLabel: AppModel.graphWindowLabel,
            warningCelsius: warningCelsius)
    }
}

/// The panel shown when the status item is clicked.
///
/// A panel rather than a menu because this is a display, not a list of commands:
/// a graph, a value hierarchy and a health verdict all fought the menu metaphor.
struct PanelView: View {
    @ObservedObject var model: AppModel
    var onOpenHistory: () -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    private var watched: [MenuBarPresentation.DriveEntry] {
        model.presentation.drives.filter(\.isShownInMenuBar)
    }

    private var others: [MenuBarPresentation.DriveEntry] {
        model.presentation.drives.filter { !$0.isShownInMenuBar }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let storeError = model.storeError {
                Label(storeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }

            if watched.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(watched, id: \.serialNumber) { drive in
                        watchedCard(drive)
                    }
                }
                // Said once for the panel rather than under every chart: all the
                // rows cover the same window.
                Text("Last 6 hours · History… for longer")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            if !others.isEmpty {
                Divider()
                VStack(spacing: 3) {
                    ForEach(others, id: \.serialNumber) { drive in
                        compactRow(drive)
                    }
                }
            }


            Divider()
            footer
        }
        .padding(12)
        .frame(width: 360)
        // Take the ideal height rather than whatever the window offers: a VStack
        // handed less than it needs compresses its children until rows overlap.
        // Bounded by the number of drives attached, so there is no ScrollView and
        // therefore no way for the content to collapse to nothing.
        .fixedSize(horizontal: false, vertical: true)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing pinned to the menu bar.")
                .font(.system(size: 12, weight: .medium))
            Text("Pin a drive in Settings to see its temperature there and its history here.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var header: some View {
        HStack {
            Text(model.presentation.verdict)
                .font(.system(size: 12, weight: .medium))
            // Evidence, not a claim: a panel left open should say when it last
            // heard anything. Driven by a TimelineView because SwiftUI only
            // redraws on observed changes — a plain Date() here would render
            // once and then sit there as a frozen clock.
            if let sampled = model.lastSampledAt {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text("· \(age(context.date.timeIntervalSince(sampled)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                model.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .help("Sample the drives now")
        }
    }

    private func age(_ seconds: TimeInterval) -> String {
        let value = Int(max(0, seconds))
        if value < 60 { return "\(value)s ago" }
        if value < 3600 { return "\(value / 60)m ago" }
        return "\(value / 3600)h ago"
    }

    private func watchedCard(_ drive: MenuBarPresentation.DriveEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(drive.name).font(.callout.weight(.medium))
                Spacer()
                Text("\(drive.temperatureCelsius)°C")
                    .font(.title3.monospacedDigit())
                    .foregroundStyle(colour(for: drive.severity))
            }
            if let summary = model.series[drive.serialNumber] {
                Sparkline(
                    title: "", summary: summary,
                    warningCelsius: model.configuration.temperature.warningCelsius
                )
                .frame(height: SparklineView.defaultHeight)
            }
            ForEach(drive.alertMessages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            // One line, not the whole field list: the full numbers are a click
            // away in Settings, and a card per drive that reprints every field
            // is the flat dump this layout exists to avoid.
            Text(enduranceSummary(drive))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func enduranceSummary(_ drive: MenuBarPresentation.DriveEntry) -> String {
        let rows = drive.sections.first { $0.title == "Endurance" }?.rows ?? []
        func value(_ label: String) -> String? { rows.first { $0.label == label }?.value }
        return [
            value("used").map { "used \($0)" },
            value("spare").map { "spare \($0)" },
            value("written").map { "written \($0)" },
        ].compactMap { $0 }.joined(separator: "  ·  ")
    }

    private func compactRow(_ drive: MenuBarPresentation.DriveEntry) -> some View {
        HStack {
            Text(drive.name).font(.callout)
            Spacer()
            Text("\(drive.temperatureCelsius)°C")
                .font(.callout.monospacedDigit())
                .foregroundStyle(colour(for: drive.severity))
        }
    }

    private var footer: some View {
        HStack {
            Button("History…", action: onOpenHistory)
                .buttonStyle(.borderless)
                .focusable(false)
            Button("Settings…", action: onOpenSettings)
                .buttonStyle(.borderless)
                .focusable(false)
            Spacer()
            Button("Quit", action: onQuit)
                .buttonStyle(.borderless)
                .focusable(false)
        }
        .font(.caption)
    }

    private func colour(for severity: AlertSeverity?) -> Color {
        switch severity {
        case .critical: return .red
        case .warning: return .orange
        case nil: return .primary
        }
    }
}
