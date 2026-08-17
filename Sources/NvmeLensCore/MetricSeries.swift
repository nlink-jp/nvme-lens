import Foundation

/// Which recorded quantity a history view is showing.
///
/// Temperature is sampled per minute; everything else is a wear counter written
/// with the same sample. All of it is retained, so all of it should be
/// reachable — collecting a value nobody can look at is just disk use.
public enum HistoryMetric: String, CaseIterable, Sendable {
    case temperature
    case percentageUsed
    case availableSpare
    case dataWritten
    case powerCycles
    case unsafeShutdowns
    case mediaErrors

    public var label: String {
        switch self {
        case .temperature: return "Temperature"
        case .percentageUsed: return "Percentage used"
        case .availableSpare: return "Available spare"
        case .dataWritten: return "Data written"
        case .powerCycles: return "Power cycles"
        case .unsafeShutdowns: return "Unsafe shutdowns"
        case .mediaErrors: return "Media errors"
        }
    }

    public var unit: String {
        switch self {
        case .temperature: return "°C"
        case .percentageUsed, .availableSpare: return "%"
        case .dataWritten: return "TB"
        case .powerCycles, .unsafeShutdowns, .mediaErrors: return ""
        }
    }

    /// Counters that only ever grow. Their level says little; the slope is the
    /// information, so a chart of one should not be padded around its range as
    /// if it were a measurement that moves both ways.
    public var isCumulative: Bool {
        switch self {
        case .temperature, .percentageUsed, .availableSpare: return false
        case .dataWritten, .powerCycles, .unsafeShutdowns, .mediaErrors: return true
        }
    }

    /// What a rising value means, so a chart can be read without knowing NVMe.
    public var risingIsBad: Bool {
        switch self {
        case .availableSpare: return false
        default: return true
        }
    }

    public func format(_ value: Double) -> String {
        switch self {
        case .temperature: return "\(Int(value.rounded()))°C"
        case .percentageUsed, .availableSpare: return "\(Int(value.rounded()))%"
        case .dataWritten: return String(format: "%.2f TB", value)
        default: return "\(Int(value.rounded()))"
        }
    }
}

public struct MetricPoint: Equatable, Sendable {
    public var timestamp: Date
    public var value: Double

    public init(timestamp: Date, value: Double) {
        self.timestamp = timestamp
        self.value = value
    }
}

/// Bucketing shared by every metric.
///
/// Pure: the awkward parts — an empty bucket in the middle, a window starting
/// before the first sample — are testable without a database or a view.
public enum MetricSeries {
    public struct Bucket: Equatable, Sendable {
        public var start: Date
        /// `nil` when no sample landed here. Callers must draw that as a gap:
        /// joining across it asserts the tool was running and the value was
        /// something, when neither is known.
        public var min: Double?
        public var max: Double?

        public var isEmpty: Bool { max == nil }
    }

    public struct Summary: Equatable, Sendable {
        public var buckets: [Bucket]
        public var min: Double?
        public var max: Double?
        public var latest: Double?
        public var first: Double?
        public var coverage: Double
    }

    public static func summarize(
        points: [MetricPoint], from start: Date, to end: Date, bucketSeconds: Int
    ) -> Summary {
        precondition(bucketSeconds > 0)
        let span = Swift.max(0, end.timeIntervalSince(start))
        let count = Swift.max(1, Int(ceil(span / Double(bucketSeconds))))

        var buckets = (0..<count).map { index in
            Bucket(
                start: start.addingTimeInterval(Double(index * bucketSeconds)), min: nil, max: nil)
        }
        for point in points {
            let offset = point.timestamp.timeIntervalSince(start)
            guard offset >= 0 else { continue }
            let index = Int(offset) / bucketSeconds
            guard index < buckets.count else { continue }
            buckets[index].min = Swift.min(buckets[index].min ?? point.value, point.value)
            buckets[index].max = Swift.max(buckets[index].max ?? point.value, point.value)
        }

        let populated = buckets.filter { !$0.isEmpty }
        return Summary(
            buckets: buckets,
            min: populated.compactMap(\.min).min(),
            max: populated.compactMap(\.max).max(),
            latest: populated.last?.max,
            first: populated.first?.min,
            coverage: Double(populated.count) / Double(buckets.count))
    }

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

    /// The y-range to draw in.
    ///
    /// A measurement is padded around its own range, so a drive that moved
    /// between 37 and 43 degrees looks like it moved rather than like a flat
    /// line at the floor of a 0–100 axis. A cumulative counter is anchored at
    /// its starting value instead: what matters there is how far it climbed.
    public static func domain(_ summary: Summary, metric: HistoryMetric) -> ClosedRange<Double> {
        guard let low = summary.min, let high = summary.max else { return 0...1 }
        if metric.isCumulative {
            let top = high == low ? high + 1 : high + (high - low) * 0.1
            return low...top
        }
        let padding = Swift.max((high - low) * 0.2, 3)
        return (low - padding)...(high + padding)
    }
}
