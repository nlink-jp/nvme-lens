import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, Equatable, Sendable {
    case cannotOpen(path: String, message: String)
    case statementFailed(sql: String, message: String)
}

/// Persistent history of temperature and wear.
///
/// Temperature arrives per minute and wear per hour, and the questions asked of
/// them ("peak over the last week", "delta against last month") are aggregates —
/// which is why this is SQLite rather than a flat file that would need its own
/// aggregation and downsampling code.
public final class HealthStore {
    private var handle: OpaquePointer?
    public let path: String

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/nvme-lens/history.sqlite")
    }

    public init(url: URL = HealthStore.defaultURL) throws {
        path = url.path
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw StoreError.cannotOpen(path: path, message: message)
        }
        handle = db
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = NORMAL")
        try createSchema()
    }

    deinit { sqlite3_close(handle) }

    // MARK: - Schema

    private func createSchema() throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS drives (
                serial TEXT PRIMARY KEY,
                model TEXT NOT NULL,
                firmware TEXT,
                first_seen INTEGER NOT NULL,
                last_seen INTEGER NOT NULL
            )
            """)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS temperature_samples (
                serial TEXT NOT NULL,
                ts INTEGER NOT NULL,
                hotspot_c INTEGER NOT NULL,
                composite_c INTEGER NOT NULL,
                composite_only INTEGER NOT NULL,
                PRIMARY KEY (serial, ts)
            )
            """)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS wear_snapshots (
                serial TEXT NOT NULL,
                ts INTEGER NOT NULL,
                percentage_used INTEGER NOT NULL,
                available_spare INTEGER NOT NULL,
                available_spare_threshold INTEGER NOT NULL,
                data_units_written INTEGER NOT NULL,
                data_units_read INTEGER NOT NULL,
                power_on_hours INTEGER NOT NULL,
                power_cycles INTEGER NOT NULL,
                unsafe_shutdowns INTEGER NOT NULL,
                media_errors INTEGER NOT NULL,
                error_log_entries INTEGER NOT NULL,
                critical_warning INTEGER NOT NULL,
                PRIMARY KEY (serial, ts)
            )
            """)
        try execute(
            "CREATE INDEX IF NOT EXISTS idx_temp_serial_ts ON temperature_samples(serial, ts)")
        try execute("CREATE INDEX IF NOT EXISTS idx_wear_serial_ts ON wear_snapshots(serial, ts)")
    }

    // MARK: - Writing

    public func record(_ record: DriveRecord, at timestamp: Date) throws {
        guard let health = record.health, record.state.isMonitored else { return }
        let serial = record.serialNumber
        guard !serial.isEmpty else { return }
        let epoch = Int64(timestamp.timeIntervalSince1970)

        try withStatement(
            """
            INSERT INTO drives (serial, model, firmware, first_seen, last_seen)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(serial) DO UPDATE SET model = excluded.model,
                firmware = excluded.firmware, last_seen = excluded.last_seen
            """
        ) { statement in
            bind(statement, 1, serial)
            bind(statement, 2, record.displayName)
            bind(statement, 3, record.identity?.firmwareRevision ?? "")
            sqlite3_bind_int64(statement, 4, epoch)
            sqlite3_bind_int64(statement, 5, epoch)
        }

        try withStatement(
            """
            INSERT OR REPLACE INTO temperature_samples
                (serial, ts, hotspot_c, composite_c, composite_only)
            VALUES (?, ?, ?, ?, ?)
            """
        ) { statement in
            bind(statement, 1, serial)
            sqlite3_bind_int64(statement, 2, epoch)
            sqlite3_bind_int(statement, 3, Int32(health.hotspotCelsius))
            sqlite3_bind_int(statement, 4, Int32(health.compositeCelsius))
            sqlite3_bind_int(statement, 5, health.hotspotIsCompositeOnly ? 1 : 0)
        }

        try withStatement(
            """
            INSERT OR REPLACE INTO wear_snapshots
                (serial, ts, percentage_used, available_spare, available_spare_threshold,
                 data_units_written, data_units_read, power_on_hours, power_cycles,
                 unsafe_shutdowns, media_errors, error_log_entries, critical_warning)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            bind(statement, 1, serial)
            sqlite3_bind_int64(statement, 2, epoch)
            sqlite3_bind_int(statement, 3, Int32(health.percentageUsed))
            sqlite3_bind_int(statement, 4, Int32(health.availableSparePercent))
            sqlite3_bind_int(statement, 5, Int32(health.availableSpareThresholdPercent))
            sqlite3_bind_int64(statement, 6, Int64(bitPattern: health.dataUnitsWritten))
            sqlite3_bind_int64(statement, 7, Int64(bitPattern: health.dataUnitsRead))
            sqlite3_bind_int64(statement, 8, Int64(bitPattern: health.powerOnHours))
            sqlite3_bind_int64(statement, 9, Int64(bitPattern: health.powerCycles))
            sqlite3_bind_int64(statement, 10, Int64(bitPattern: health.unsafeShutdowns))
            sqlite3_bind_int64(statement, 11, Int64(bitPattern: health.mediaAndDataIntegrityErrors))
            sqlite3_bind_int64(statement, 12, Int64(bitPattern: health.errorInformationLogEntries))
            sqlite3_bind_int(statement, 13, Int32(health.criticalWarning))
        }
    }

    // MARK: - Reading

    public func temperatureHistory(serial: String, since: Date) throws -> [TemperaturePoint] {
        var points: [TemperaturePoint] = []
        try withStatement(
            "SELECT ts, hotspot_c FROM temperature_samples WHERE serial = ? AND ts >= ? ORDER BY ts",
            bind: { statement in
                self.bind(statement, 1, serial)
                sqlite3_bind_int64(statement, 2, Int64(since.timeIntervalSince1970))
            },
            step: { statement in
                points.append(
                    TemperaturePoint(
                        timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
                        hotspotCelsius: Int(sqlite3_column_int(statement, 1))))
            })
        return points
    }

    /// The most recent wear snapshot strictly before `before`, which is what the
    /// evaluator compares against.
    public func latestWearBaseline(serial: String, before: Date) throws -> WearBaseline? {
        var baseline: WearBaseline?
        try withStatement(
            """
            SELECT ts, percentage_used, media_errors, power_cycles, power_on_hours, unsafe_shutdowns
            FROM wear_snapshots WHERE serial = ? AND ts < ? ORDER BY ts DESC LIMIT 1
            """,
            bind: { statement in
                self.bind(statement, 1, serial)
                sqlite3_bind_int64(statement, 2, Int64(before.timeIntervalSince1970))
            },
            step: { statement in
                baseline = WearBaseline(
                    timestamp: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
                    percentageUsed: UInt8(truncatingIfNeeded: sqlite3_column_int(statement, 1)),
                    mediaErrors: UInt64(bitPattern: sqlite3_column_int64(statement, 2)),
                    powerCycles: UInt64(bitPattern: sqlite3_column_int64(statement, 3)),
                    powerOnHours: UInt64(bitPattern: sqlite3_column_int64(statement, 4)),
                    unsafeShutdowns: UInt64(bitPattern: sqlite3_column_int64(statement, 5)))
            })
        return baseline
    }

    /// Any recorded metric as a time series.
    ///
    /// One query path with the metric choosing the column, rather than a
    /// bespoke accessor per field — adding a metric to the history then means
    /// naming it, not writing another query.
    public func metricSeries(serial: String, metric: HistoryMetric, since: Date) throws
        -> [MetricPoint]
    {
        let (table, column, scale): (String, String, Double) = {
            switch metric {
            case .temperature: return ("temperature_samples", "hotspot_c", 1)
            case .percentageUsed: return ("wear_snapshots", "percentage_used", 1)
            case .availableSpare: return ("wear_snapshots", "available_spare", 1)
            // Data units are 512000 bytes; charting terabytes keeps the axis
            // readable.
            case .dataWritten: return ("wear_snapshots", "data_units_written", 512_000 / 1e12)
            case .powerCycles: return ("wear_snapshots", "power_cycles", 1)
            case .unsafeShutdowns: return ("wear_snapshots", "unsafe_shutdowns", 1)
            case .mediaErrors: return ("wear_snapshots", "media_errors", 1)
            }
        }()

        var points: [MetricPoint] = []
        try withStatement(
            "SELECT ts, \(column) FROM \(table) WHERE serial = ? AND ts >= ? ORDER BY ts",
            bind: { statement in
                self.bind(statement, 1, serial)
                sqlite3_bind_int64(statement, 2, Int64(since.timeIntervalSince1970))
            },
            step: { statement in
                points.append(
                    MetricPoint(
                        timestamp: Date(
                            timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
                        value: Double(sqlite3_column_int64(statement, 1)) * scale))
            })
        return points
    }

    public struct TemperatureSummary: Equatable, Sendable, Codable {
        public var serialNumber: String
        public var samples: Int
        public var minCelsius: Int
        public var maxCelsius: Int
        public var averageCelsius: Double
    }

    public func temperatureSummary(serial: String, since: Date) throws -> TemperatureSummary? {
        var summary: TemperatureSummary?
        try withStatement(
            """
            SELECT COUNT(*), MIN(hotspot_c), MAX(hotspot_c), AVG(hotspot_c)
            FROM temperature_samples WHERE serial = ? AND ts >= ?
            """,
            bind: { statement in
                self.bind(statement, 1, serial)
                sqlite3_bind_int64(statement, 2, Int64(since.timeIntervalSince1970))
            },
            step: { statement in
                let count = Int(sqlite3_column_int(statement, 0))
                guard count > 0 else { return }
                summary = TemperatureSummary(
                    serialNumber: serial, samples: count,
                    minCelsius: Int(sqlite3_column_int(statement, 1)),
                    maxCelsius: Int(sqlite3_column_int(statement, 2)),
                    averageCelsius: sqlite3_column_double(statement, 3))
            })
        return summary
    }

    public struct WearDelta: Equatable, Sendable, Codable {
        public var serialNumber: String
        public var fromTimestamp: Date
        public var toTimestamp: Date
        public var percentageUsedDelta: Int
        public var dataUnitsWrittenDelta: Int64
        public var powerOnHoursDelta: Int64
        public var powerCyclesDelta: Int64
        public var unsafeShutdownsDelta: Int64
        public var mediaErrorsDelta: Int64
        /// Power cycles per powered hour over the window. The measurement that
        /// exposed a USB enclosure cycling a drive 7.3 times an hour.
        public var powerCyclesPerHour: Double?
    }

    public func wearDelta(serial: String, since: Date) throws -> WearDelta? {
        var rows: [(Date, Int, Int64, Int64, Int64, Int64, Int64)] = []
        try withStatement(
            """
            SELECT ts, percentage_used, data_units_written, power_on_hours, power_cycles,
                   unsafe_shutdowns, media_errors
            FROM wear_snapshots WHERE serial = ? AND ts >= ? ORDER BY ts
            """,
            bind: { statement in
                self.bind(statement, 1, serial)
                sqlite3_bind_int64(statement, 2, Int64(since.timeIntervalSince1970))
            },
            step: { statement in
                rows.append(
                    (
                        Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0))),
                        Int(sqlite3_column_int(statement, 1)),
                        sqlite3_column_int64(statement, 2), sqlite3_column_int64(statement, 3),
                        sqlite3_column_int64(statement, 4), sqlite3_column_int64(statement, 5),
                        sqlite3_column_int64(statement, 6)
                    ))
            })
        guard let first = rows.first, let last = rows.last, rows.count >= 2 else { return nil }
        let hours = last.3 - first.3
        let cycles = last.4 - first.4
        return WearDelta(
            serialNumber: serial, fromTimestamp: first.0, toTimestamp: last.0,
            percentageUsedDelta: last.1 - first.1,
            dataUnitsWrittenDelta: last.2 - first.2,
            powerOnHoursDelta: hours,
            powerCyclesDelta: cycles,
            unsafeShutdownsDelta: last.5 - first.5,
            mediaErrorsDelta: last.6 - first.6,
            powerCyclesPerHour: hours > 0 ? Double(cycles) / Double(hours) : nil)
    }

    /// Drops temperature samples older than the retention window. Wear snapshots
    /// are kept: they are small, and their long-term trend is the point.
    @discardableResult
    public func pruneTemperature(olderThan cutoff: Date) throws -> Int {
        try withStatement("DELETE FROM temperature_samples WHERE ts < ?") { statement in
            sqlite3_bind_int64(statement, 1, Int64(cutoff.timeIntervalSince1970))
        }
        return Int(sqlite3_changes(handle))
    }

    public func knownSerials() throws -> [String] {
        var serials: [String] = []
        try withStatement(
            "SELECT serial FROM drives ORDER BY serial", bind: { _ in },
            step: { statement in
                if let text = sqlite3_column_text(statement, 0) {
                    serials.append(String(cString: text))
                }
            })
        return serials
    }

    // MARK: - Plumbing

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw StoreError.statementFailed(sql: sql, message: message)
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func withStatement(_ sql: String, bind: (OpaquePointer?) -> Void) throws {
        try withStatement(sql, bind: bind, step: { _ in })
    }

    private func withStatement(
        _ sql: String, bind: (OpaquePointer?) -> Void, step: (OpaquePointer?) -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.statementFailed(
                sql: sql, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        bind(statement)

        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                step(statement)
            } else if result == SQLITE_DONE {
                break
            } else {
                throw StoreError.statementFailed(
                    sql: sql, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }
}
