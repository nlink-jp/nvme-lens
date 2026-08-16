import Testing

@testable import NvmeLensCore

/// Builds a 512-byte SMART log page from field values, so each test states only
/// what it cares about. The offsets here mirror the NVMe specification and are
/// deliberately written out again rather than reused from the parser — a shared
/// constant would let a wrong offset agree with itself.
private struct LogPageBuilder {
    var bytes = [UInt8](repeating: 0, count: 512)

    mutating func u8(_ value: UInt8, at offset: Int) { bytes[offset] = value }

    mutating func u16(_ value: UInt16, at offset: Int) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    mutating func u32(_ value: UInt32, at offset: Int) {
        for index in 0..<4 { bytes[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF) }
    }

    mutating func u64(_ value: UInt64, at offset: Int) {
        for index in 0..<8 { bytes[offset + index] = UInt8((value >> (8 * UInt64(index))) & 0xFF) }
    }
}

@Suite("SmartHealth parsing")
struct SmartHealthTests {
    @Test("a log page of the wrong length is rejected")
    func wrongLength() {
        #expect(throws: SmartParseError.wrongLength(expected: 512, actual: 511)) {
            try SmartHealth(logPage: [UInt8](repeating: 0, count: 511))
        }
    }

    @Test("scalar fields are read from their specified offsets")
    func scalarFields() throws {
        var builder = LogPageBuilder()
        builder.u8(0x04, at: 0)  // critical warning
        builder.u16(327, at: 1)  // composite temperature, Kelvin
        builder.u8(100, at: 3)  // available spare
        builder.u8(10, at: 4)  // available spare threshold
        builder.u8(3, at: 5)  // percentage used

        let health = try SmartHealth(logPage: builder.bytes)
        #expect(health.criticalWarning == 0x04)
        #expect(health.compositeTemperatureKelvin == 327)
        #expect(health.compositeCelsius == 54)
        #expect(health.availableSparePercent == 100)
        #expect(health.availableSpareThresholdPercent == 10)
        #expect(health.percentageUsed == 3)
    }

    @Test("64-bit counters are read little-endian from their offsets")
    func counters() throws {
        var builder = LogPageBuilder()
        builder.u64(16_885_965, at: 48)  // data units written
        builder.u64(5_871_240, at: 32)  // data units read
        builder.u64(9_411, at: 112)  // power cycles
        builder.u64(1_308, at: 128)  // power on hours
        builder.u64(72, at: 144)  // unsafe shutdowns
        builder.u64(0, at: 160)  // media errors
        builder.u64(7, at: 176)  // error log entries

        let health = try SmartHealth(logPage: builder.bytes)
        #expect(health.dataUnitsWritten == 16_885_965)
        #expect(health.dataUnitsRead == 5_871_240)
        #expect(health.powerCycles == 9_411)
        #expect(health.powerOnHours == 1_308)
        #expect(health.unsafeShutdowns == 72)
        #expect(health.mediaAndDataIntegrityErrors == 0)
        #expect(health.errorInformationLogEntries == 7)
    }

    @Test("composite temperature dwell times are 32-bit at 192 and 196")
    func dwellTimes() throws {
        var builder = LogPageBuilder()
        builder.u32(11, at: 192)
        builder.u32(2, at: 196)
        let health = try SmartHealth(logPage: builder.bytes)
        #expect(health.warningCompositeTemperatureMinutes == 11)
        #expect(health.criticalCompositeTemperatureMinutes == 2)
    }

    @Test("implemented sensors are read from 200..215")
    func sensors() throws {
        var builder = LogPageBuilder()
        builder.u16(343, at: 200)  // sensor 1 = 70 C
        builder.u16(327, at: 202)  // sensor 2 = 54 C
        let health = try SmartHealth(logPage: builder.bytes)
        #expect(health.sensorsCelsius == [70, 54])
    }

    @Test("a sensor reporting zero is unimplemented, not absolute zero")
    func zeroSensorsAreDropped() throws {
        var builder = LogPageBuilder()
        builder.u16(0, at: 200)
        builder.u16(310, at: 202)
        let health = try SmartHealth(logPage: builder.bytes)
        #expect(health.sensorsCelsius == [37])
    }

    /// The reason this tool exists: composite understated the hotspot by 17 °C
    /// on real hardware while the drive still called itself healthy.
    @Test("the hotspot is the hottest sensor, not composite")
    func hotspotPrefersSensors() throws {
        var builder = LogPageBuilder()
        builder.u16(326, at: 1)  // composite 53 C
        builder.u16(343, at: 200)  // sensor 1   70 C
        builder.u16(326, at: 202)  // sensor 2   53 C
        let health = try SmartHealth(logPage: builder.bytes)
        #expect(health.hotspotCelsius == 70)
        #expect(health.compositeCelsius == 53)
        #expect(health.hotspotIsCompositeOnly == false)
    }

    /// Apple's internal SSD implements no per-sensor temperatures. Reporting
    /// nothing would be worse than reporting the conservative composite value,
    /// but the caller has to be able to tell the two apart.
    @Test("a drive with no sensors falls back to composite and says so")
    func hotspotFallsBackToComposite() throws {
        var builder = LogPageBuilder()
        builder.u16(313, at: 1)  // composite 40 C, no sensors set
        let health = try SmartHealth(logPage: builder.bytes)
        #expect(health.sensorsCelsius.isEmpty)
        #expect(health.hotspotCelsius == 40)
        #expect(health.hotspotIsCompositeOnly)
    }

    @Test("a data unit is 512000 bytes")
    func dataUnitConversion() {
        #expect(SmartHealth.bytes(fromDataUnits: 16_885_965) == 8_645_614_080_000)
    }

    @Test("Kelvin converts the way the oracle converts it")
    func kelvinConversion() {
        #expect(SmartHealth.celsius(fromKelvin: 327) == 54)
        #expect(SmartHealth.celsius(fromKelvin: 273) == 0)
    }
}
