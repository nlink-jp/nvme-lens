import Foundation

/// One collection pass: read every drive, persist what is monitorable, and
/// decide what deserves a notification.
///
/// The orchestration lives here so both the CLI (`sample`) and the menu-bar
/// application drive the identical path — a divergence between "what the GUI
/// records" and "what the CLI records" would make the history unreadable.
public struct Sampler {
    public let store: HealthStore
    public var configuration: Configuration

    public init(store: HealthStore, configuration: Configuration) {
        self.store = store
        self.configuration = configuration
    }

    public struct Outcome: Sendable {
        public var recorded: [String]
        public var alerts: [Alert]
        public var prunedTemperatureRows: Int
    }

    /// `now` is injected rather than read from the clock so the whole pass can
    /// be exercised deterministically.
    @discardableResult
    public func run(records: [DriveRecord], now: Date = Date()) throws -> Outcome {
        var recorded: [String] = []
        var alerts: [Alert] = []

        for record in records where record.state.isMonitored {
            let serial = record.serialNumber
            guard !serial.isEmpty else { continue }

            // Read the baseline and history *before* inserting this sample, so
            // the evaluator compares against the past rather than against the
            // row it is about to write.
            let baseline = try store.latestWearBaseline(serial: serial, before: now)
            var history = try store.temperatureHistory(
                serial: serial,
                since: now.addingTimeInterval(
                    -Double(configuration.temperature.sustainedMinutes * 60 * 4)))
            if let health = record.health {
                history.append(
                    TemperaturePoint(timestamp: now, hotspotCelsius: health.hotspotCelsius))
            }

            try store.record(record, at: now)
            recorded.append(serial)

            alerts.append(
                contentsOf: AlertEvaluator.evaluate(
                    record: record, now: now, temperatureHistory: history,
                    wearBaseline: baseline, configuration: configuration))
        }

        let cutoff = now.addingTimeInterval(
            -Double(configuration.sampling.temperatureRetentionDays) * 86_400)
        let pruned = try store.pruneTemperature(olderThan: cutoff)

        return Outcome(recorded: recorded, alerts: alerts, prunedTemperatureRows: pruned)
    }
}

/// Parses the `--since` argument: `30m`, `12h`, `7d`, `4w`.
public enum PeriodParser {
    public enum Failure: Error, Equatable, Sendable {
        case unparsable(String)
    }

    public static func seconds(_ text: String) throws -> Int {
        guard let unit = text.last, let magnitude = Int(text.dropLast()), magnitude > 0 else {
            throw Failure.unparsable(text)
        }
        switch unit {
        case "m": return magnitude * 60
        case "h": return magnitude * 3600
        case "d": return magnitude * 86_400
        case "w": return magnitude * 604_800
        default: throw Failure.unparsable(text)
        }
    }
}
