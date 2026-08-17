import AppKit
import Foundation
import Testing

@testable import NvmeLens
@testable import NvmeLensCore

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

private func summary(_ celsius: [Int]) -> TemperatureSeries.Summary {
    let points = celsius.enumerated().map { index, value in
        TemperaturePoint(
            timestamp: epoch.addingTimeInterval(Double(index * 600)), hotspotCelsius: value)
    }
    return TemperatureSeries.summarize(
        points: points, from: epoch, to: epoch.addingTimeInterval(6 * 3600), bucketSeconds: 600)
}

@Suite("SparklineView")
@MainActor
struct SparklineViewTests {
    /// The bug this exists to prevent: the view held its data in `let`, so once
    /// SwiftUI had built it the graph redrew the first sample forever. It looked
    /// right throughout development because restarting the app rebuilt the view;
    /// it only showed up on a machine left running.
    @Test("new data replaces what the view was constructed with")
    func updateReplacesData() {
        let view = SparklineView(
            title: "A", summary: summary([50, 51, 52]), windowLabel: "6h", warningCelsius: 78)
        let before = view.renderedSummary

        view.update(
            title: "B", summary: summary([70, 71, 72]), windowLabel: "6h", warningCelsius: 80)

        #expect(view.renderedSummary != before)
        #expect(view.renderedSummary.maxCelsius == 72)
        #expect(view.renderedTitle == "B")
    }

    @Test("the caption is recomputed, not carried over from construction")
    func captionFollowsData() {
        let view = SparklineView(
            title: "A", summary: summary([50]), windowLabel: "6h", warningCelsius: 78)
        view.update(
            title: "A", summary: summary([70, 71]), windowLabel: "6h", warningCelsius: 78)
        #expect(view.renderedCaption.contains("71°C"))
    }

    // A "needsDisplay becomes true" test was written here and removed: a view
    // that is not in a window does not retain the flag, so it measured AppKit
    // rather than this code. What matters is that the data reached the view.
}
