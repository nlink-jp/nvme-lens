import Foundation

/// A history window reduced to fixed-width buckets, ready to draw.
///
/// Bucketing is a pure function of the points and the window, so the awkward
/// parts — an empty bucket in the middle, a window that starts before the first
/// sample — are testable without a database or a view.
public enum TemperatureSeries {
    public struct Bucket: Equatable, Sendable {
        public var start: Date
        /// `nil` when no sample landed in this bucket. Callers must draw that as
        /// a gap: joining across it would assert the tool was running and the
        /// drive was at some temperature, when neither is known.
        public var minCelsius: Int?
        public var maxCelsius: Int?

        public var isEmpty: Bool { maxCelsius == nil }
    }

    public struct Summary: Equatable, Sendable {
        public var buckets: [Bucket]
        public var minCelsius: Int?
        public var maxCelsius: Int?
        public var latestCelsius: Int?
        /// Difference between the last populated bucket and the one before it,
        /// for a trend indicator. `nil` when there is not enough history.
        public var trendDelta: Int?
        /// Populated buckets over total buckets — how much of the window the
        /// tool was actually running for.
        public var coverage: Double
    }

    public static func summarize(
        points: [TemperaturePoint], from start: Date, to end: Date, bucketSeconds: Int
    ) -> Summary {
        precondition(bucketSeconds > 0)
        let span = max(0, end.timeIntervalSince(start))
        let count = max(1, Int(ceil(span / Double(bucketSeconds))))

        var buckets = (0..<count).map { index in
            Bucket(
                start: start.addingTimeInterval(Double(index * bucketSeconds)), minCelsius: nil,
                maxCelsius: nil)
        }

        for point in points {
            let offset = point.timestamp.timeIntervalSince(start)
            guard offset >= 0 else { continue }
            let index = Int(offset) / bucketSeconds
            guard index < buckets.count else { continue }
            let value = point.hotspotCelsius
            buckets[index].minCelsius = min(buckets[index].minCelsius ?? value, value)
            buckets[index].maxCelsius = max(buckets[index].maxCelsius ?? value, value)
        }

        let populated = buckets.filter { !$0.isEmpty }
        let latest = populated.last?.maxCelsius
        var trend: Int?
        if populated.count >= 2, let last = populated.last?.maxCelsius,
            let previous = populated[populated.count - 2].maxCelsius
        {
            trend = last - previous
        }

        return Summary(
            buckets: buckets,
            minCelsius: populated.compactMap(\.minCelsius).min(),
            maxCelsius: populated.compactMap(\.maxCelsius).max(),
            latestCelsius: latest,
            trendDelta: trend,
            coverage: Double(populated.count) / Double(buckets.count))
    }
}

extension TemperatureSeries {
    /// A window the history view can show, with the bucket size that keeps the
    /// point count sane at that scale.
    public enum Window: String, CaseIterable, Sendable {
        case day, week, month, quarter

        public var seconds: TimeInterval {
            switch self {
            case .day: return 86_400
            case .week: return 7 * 86_400
            case .month: return 30 * 86_400
            case .quarter: return 90 * 86_400
            }
        }

        public var bucketSeconds: Int {
            switch self {
            case .day: return 600
            case .week: return 3_600
            case .month: return 4 * 3_600
            case .quarter: return 12 * 3_600
            }
        }

        public var label: String {
            switch self {
            case .day: return "24 hours"
            case .week: return "7 days"
            case .month: return "30 days"
            case .quarter: return "90 days"
            }
        }
    }

    /// Stretches with no samples, as time ranges.
    ///
    /// Returned so a chart can shade them. Drawing a line straight across an
    /// outage invents readings that were never taken, and at a 90-day scale an
    /// outage of a week is invisible unless it is marked.
    public struct Gap: Equatable, Sendable, Identifiable {
        public var start: Date
        public var end: Date
        public var id: Date { start }
        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    public static func gaps(in summary: Summary, bucketSeconds: Int) -> [Gap] {
        var gaps: [Gap] = []
        var runStart: Date?
        for bucket in summary.buckets {
            if bucket.isEmpty {
                if runStart == nil { runStart = bucket.start }
            } else if let start = runStart {
                gaps.append(Gap(start: start, end: bucket.start))
                runStart = nil
            }
        }
        if let start = runStart, let last = summary.buckets.last {
            gaps.append(Gap(start: start, end: last.start.addingTimeInterval(Double(bucketSeconds))))
        }
        return gaps
    }
}

extension TemperatureSeries.Summary {
    /// One line under the graph: current, range, and trend. Written here rather
    /// than in the view so the wording is testable.
    public func caption(windowLabel: String) -> String {
        guard let latest = latestCelsius, let minCelsius, let maxCelsius else {
            return "no samples in the last \(windowLabel)"
        }
        let arrow: String
        switch trendDelta {
        case .some(let delta) where delta >= 2: arrow = " ↑"
        case .some(let delta) where delta <= -2: arrow = " ↓"
        default: arrow = ""
        }
        let range = minCelsius == maxCelsius ? "\(minCelsius)°C" : "\(minCelsius)–\(maxCelsius)°C"
        return "\(latest)°C\(arrow)   \(windowLabel): \(range)"
    }

    /// Stated when the tool was not running for much of the window, so a short
    /// graph is not mistaken for a stable one.
    public var gapNote: String? {
        guard coverage < 0.5, coverage > 0 else { return nil }
        return String(format: "%.0f%% recorded", coverage * 100)
    }
}
