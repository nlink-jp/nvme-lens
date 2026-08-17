import Foundation
import Testing

@testable import NvmeLensCore

private let start = Date(timeIntervalSince1970: 1_700_000_000)

private func point(minutes: Int, celsius: Int) -> TemperaturePoint {
    TemperaturePoint(
        timestamp: start.addingTimeInterval(Double(minutes * 60)), hotspotCelsius: celsius)
}

@Suite("TemperatureSeries bucketing")
struct TemperatureSeriesTests {
    /// Six hours in ten-minute buckets: the window the menu graph draws.
    private func summarize(_ points: [TemperaturePoint], hours: Double = 6)
        -> TemperatureSeries.Summary
    {
        TemperatureSeries.summarize(
            points: points, from: start, to: start.addingTimeInterval(hours * 3600),
            bucketSeconds: 600)
    }

    @Test("the window is divided into fixed buckets regardless of the data")
    func bucketCount() {
        #expect(summarize([]).buckets.count == 36)
    }

    @Test("a bucket takes the min and max of the samples that land in it")
    func minMaxPerBucket() {
        let summary = summarize([
            point(minutes: 1, celsius: 50), point(minutes: 5, celsius: 62),
            point(minutes: 9, celsius: 55),
        ])
        #expect(summary.buckets[0].minCelsius == 50)
        #expect(summary.buckets[0].maxCelsius == 62)
    }

    /// The rule that keeps the graph honest: an interval with no samples must
    /// stay empty. Interpolating across it would assert both that the tool was
    /// running and that the drive was at some temperature.
    @Test("a bucket with no samples stays empty rather than being interpolated")
    func gapsStayEmpty() {
        let summary = summarize([point(minutes: 1, celsius: 50), point(minutes: 61, celsius: 70)])
        #expect(summary.buckets[0].isEmpty == false)
        #expect(summary.buckets[6].isEmpty == false)
        for index in 1...5 {
            #expect(summary.buckets[index].isEmpty)
        }
    }

    @Test("coverage reports how much of the window was actually recorded")
    func coverage() {
        #expect(summarize([]).coverage == 0)
        let full = (0..<36).map { point(minutes: $0 * 10, celsius: 50) }
        #expect(summarize(full).coverage == 1)
        let half = (0..<18).map { point(minutes: $0 * 10, celsius: 50) }
        #expect(abs(summarize(half).coverage - 0.5) < 0.001)
    }

    @Test("samples outside the window are ignored rather than clamped in")
    func outOfWindowSamplesIgnored() {
        let summary = summarize([
            point(minutes: -30, celsius: 99), point(minutes: 400, celsius: 98),
            point(minutes: 5, celsius: 50),
        ])
        #expect(summary.maxCelsius == 50)
    }

    @Test("the trend compares the last two populated buckets, skipping gaps")
    func trendSkipsGaps() {
        let summary = summarize([
            point(minutes: 0, celsius: 50), point(minutes: 200, celsius: 60),
        ])
        #expect(summary.trendDelta == 10)
    }

    @Test("a single sample yields no trend rather than a trend of zero")
    func noTrendFromOnePoint() {
        #expect(summarize([point(minutes: 0, celsius: 50)]).trendDelta == nil)
    }

    @Test("the latest value is the last populated bucket, not the last bucket")
    func latestSkipsTrailingGap() {
        let summary = summarize([point(minutes: 0, celsius: 50), point(minutes: 60, celsius: 71)])
        #expect(summary.latestCelsius == 71)
    }
}

@Suite("TemperatureSeries caption")
struct TemperatureSeriesCaptionTests {
    private func summary(_ points: [TemperaturePoint]) -> TemperatureSeries.Summary {
        TemperatureSeries.summarize(
            points: points, from: start, to: start.addingTimeInterval(6 * 3600), bucketSeconds: 600)
    }

    @Test("an empty window says so instead of rendering an empty range")
    func emptyCaption() {
        #expect(summary([]).caption(windowLabel: "6h") == "no samples in the last 6h")
    }

    @Test("the caption carries current value and range")
    func rangeCaption() {
        let text = summary([point(minutes: 0, celsius: 50), point(minutes: 60, celsius: 71)])
            .caption(windowLabel: "6h")
        #expect(text.contains("71°C"))
        #expect(text.contains("50–71°C"))
    }

    @Test("a flat trace shows one value, not a range of one to itself")
    func flatCaption() {
        let text = summary([point(minutes: 0, celsius: 54), point(minutes: 60, celsius: 54)])
            .caption(windowLabel: "6h")
        #expect(text.contains("54°C   6h: 54°C"))
    }

    @Test("the trend arrow needs a real move, not a one-degree wobble")
    func trendArrowThreshold() {
        let wobble = summary([point(minutes: 0, celsius: 54), point(minutes: 60, celsius: 55)])
        #expect(!wobble.caption(windowLabel: "6h").contains("↑"))
        let rising = summary([point(minutes: 0, celsius: 54), point(minutes: 60, celsius: 60)])
        #expect(rising.caption(windowLabel: "6h").contains("↑"))
        let falling = summary([point(minutes: 0, celsius: 60), point(minutes: 60, celsius: 54)])
        #expect(falling.caption(windowLabel: "6h").contains("↓"))
    }

    /// A graph covering two hours of a six-hour window must not read as a
    /// six-hour history.
    @Test("thin coverage is stated, full coverage is not")
    func gapNote() {
        let thin = summary([point(minutes: 0, celsius: 50)])
        #expect(thin.gapNote != nil)
        let full = summary((0..<36).map { point(minutes: $0 * 10, celsius: 50) })
        #expect(full.gapNote == nil)
        // Nothing recorded at all is already said by the caption.
        #expect(summary([]).gapNote == nil)
    }
}

@Suite("TemperatureSeries gaps")
struct TemperatureSeriesGapTests {
    private func summarize(_ points: [TemperaturePoint]) -> TemperatureSeries.Summary {
        TemperatureSeries.summarize(
            points: points, from: start, to: start.addingTimeInterval(6 * 3600), bucketSeconds: 600)
    }

    @Test("a fully covered window has no gaps")
    func noGaps() {
        let full = (0..<36).map { point(minutes: $0 * 10, celsius: 50) }
        #expect(TemperatureSeries.gaps(in: summarize(full), bucketSeconds: 600).isEmpty)
    }

    @Test("an interior outage becomes one range covering it")
    func interiorGap() {
        let points = [point(minutes: 0, celsius: 50), point(minutes: 60, celsius: 50)]
        let gaps = TemperatureSeries.gaps(in: summarize(points), bucketSeconds: 600)
        #expect(gaps.count == 2)  // the outage, then the tail after the last sample
        #expect(gaps[0].start == start.addingTimeInterval(600))
        #expect(gaps[0].duration == 5 * 600)
    }

    @Test("an outage running to the end of the window is closed at the window edge")
    func trailingGap() {
        let gaps = TemperatureSeries.gaps(
            in: summarize([point(minutes: 0, celsius: 50)]), bucketSeconds: 600)
        #expect(gaps.count == 1)
        #expect(gaps[0].end == start.addingTimeInterval(6 * 3600))
    }

    /// A window with nothing in it is one gap, not zero: "no data" and "steady"
    /// must not look the same.
    @Test("an empty window is a single gap covering all of it")
    func emptyWindowIsOneGap() {
        let gaps = TemperatureSeries.gaps(in: summarize([]), bucketSeconds: 600)
        #expect(gaps.count == 1)
        #expect(gaps[0].duration == 6 * 3600)
    }

    @Test("each window pairs with a bucket size that keeps the point count sane")
    func windowBucketing() {
        for window in TemperatureSeries.Window.allCases {
            let points = Int(window.seconds) / window.bucketSeconds
            #expect(points >= 100 && points <= 200)
        }
    }
}

@Suite("MetricSeries")
struct MetricSeriesTests {
    private func summarize(_ values: [(Int, Double)]) -> MetricSeries.Summary {
        MetricSeries.summarize(
            points: values.map {
                MetricPoint(timestamp: start.addingTimeInterval(Double($0.0 * 60)), value: $0.1)
            },
            from: start, to: start.addingTimeInterval(6 * 3600), bucketSeconds: 600)
    }

    @Test("gaps stay empty rather than being interpolated")
    func gapsStayEmpty() {
        let summary = summarize([(0, 50), (60, 70)])
        #expect(summary.buckets[3].isEmpty)
        #expect(MetricSeries.gaps(in: summary, bucketSeconds: 600).count == 2)
    }

    /// A measurement that moved a few degrees must look like it moved, not like
    /// a flat line at the floor of a zero-anchored axis.
    @Test("a measurement is padded around its own range")
    func measurementDomain() {
        let scale = MetricSeries.domain(summarize([(0, 37), (60, 43)]), metric: .temperature)
        #expect(scale.lowerBound < 37 && scale.lowerBound > 30)
        #expect(scale.upperBound > 43 && scale.upperBound < 50)
    }

    /// A counter's level says nothing; how far it climbed is the information, so
    /// the axis starts where the window started rather than below it.
    @Test("a cumulative counter is anchored at its starting value")
    func cumulativeDomain() {
        let scale = MetricSeries.domain(summarize([(0, 9000), (60, 9411)]), metric: .powerCycles)
        #expect(scale.lowerBound == 9000)
        #expect(scale.upperBound > 9411)
    }

    @Test("a flat counter still gets a drawable range")
    func flatCumulativeDomain() {
        let scale = MetricSeries.domain(summarize([(0, 5), (60, 5)]), metric: .mediaErrors)
        #expect(scale.upperBound > scale.lowerBound)
    }

    @Test("every metric names itself and formats its own values")
    func metricsAreSelfDescribing() {
        for metric in HistoryMetric.allCases {
            #expect(!metric.label.isEmpty)
            #expect(!metric.format(1).isEmpty)
        }
        #expect(HistoryMetric.temperature.format(54) == "54°C")
        #expect(HistoryMetric.dataWritten.format(8.6456) == "8.65 TB")
        #expect(HistoryMetric.powerCycles.format(9411) == "9411")
    }

    /// Available spare falling is the bad direction; everything else rises when
    /// it is getting worse.
    @Test("the bad direction is recorded per metric")
    func direction() {
        #expect(HistoryMetric.availableSpare.risingIsBad == false)
        #expect(HistoryMetric.percentageUsed.risingIsBad)
        #expect(HistoryMetric.mediaErrors.risingIsBad)
    }
}
