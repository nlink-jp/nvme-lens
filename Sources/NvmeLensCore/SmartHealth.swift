import Foundation

/// A parsed NVMe SMART / Health Information log page (Log Identifier 02h).
///
/// Apple's `NVMeSMARTData` struct stops at the error-log-entry count and lumps
/// everything past byte 192 into a reserved array — which is exactly where the
/// per-sensor temperatures live. The offsets below therefore come from the NVMe
/// specification, not from that struct.
public struct SmartHealth: Equatable, Sendable {
    public var criticalWarning: UInt8
    /// Composite temperature in Kelvin as reported. Prefer `hotspotCelsius`.
    public var compositeTemperatureKelvin: UInt16
    public var availableSparePercent: UInt8
    public var availableSpareThresholdPercent: UInt8
    public var percentageUsed: UInt8
    public var dataUnitsRead: UInt64
    public var dataUnitsWritten: UInt64
    public var hostReadCommands: UInt64
    public var hostWriteCommands: UInt64
    public var controllerBusyTimeMinutes: UInt64
    public var powerCycles: UInt64
    public var powerOnHours: UInt64
    public var unsafeShutdowns: UInt64
    public var mediaAndDataIntegrityErrors: UInt64
    public var errorInformationLogEntries: UInt64
    public var warningCompositeTemperatureMinutes: UInt32
    public var criticalCompositeTemperatureMinutes: UInt32
    /// Temperature Sensor 1..8, in Kelvin. A sensor reporting 0 is not
    /// implemented and is dropped rather than reported as absolute zero.
    public var sensorsKelvin: [UInt16]

    public static let logPageSize = 512
    public static let sensorCount = 8

    /// NVMe reports temperatures in Kelvin. smartctl renders them with a flat
    /// 273 offset; matching that keeps cross-checks against the oracle exact
    /// (ADR-0001 Decision 5).
    public static func celsius(fromKelvin kelvin: UInt16) -> Int {
        Int(kelvin) - 273
    }

    public var compositeCelsius: Int { Self.celsius(fromKelvin: compositeTemperatureKelvin) }

    public var sensorsCelsius: [Int] { sensorsKelvin.map(Self.celsius(fromKelvin:)) }

    /// The number a monitor must actually judge on.
    ///
    /// Composite understates the hotspot — measured at 17–21 °C below sensor 1
    /// on a real drive — so the maximum reported sensor wins when any sensor is
    /// implemented. Drives that implement no sensors at all (Apple's internal
    /// SSD is one) leave only composite, and reporting nothing there would be
    /// worse than reporting the conservative value.
    public var hotspotCelsius: Int {
        max(sensorsCelsius.max() ?? Int.min, compositeCelsius)
    }

    /// True when the hotspot comes from composite because no sensor is
    /// implemented. Callers should say so rather than implying sensor accuracy.
    public var hotspotIsCompositeOnly: Bool { sensorsKelvin.isEmpty }
}

public enum SmartParseError: Error, Equatable, Sendable {
    case wrongLength(expected: Int, actual: Int)
}

extension SmartHealth {
    /// Parses the 512-byte log page. Pure — the buffer's origin is irrelevant,
    /// which is what allows the offsets to be tested without a device.
    public init(logPage bytes: [UInt8]) throws {
        guard bytes.count == Self.logPageSize else {
            throw SmartParseError.wrongLength(expected: Self.logPageSize, actual: bytes.count)
        }

        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }
        func u32(_ offset: Int) -> UInt32 {
            var value: UInt32 = 0
            for index in (0..<4).reversed() {
                value = (value << 8) | UInt32(bytes[offset + index])
            }
            return value
        }
        // The spec makes these counters 128-bit. Real drives do not come close
        // to overflowing the low 64 bits, and carrying a 128-bit type through
        // the whole tool would buy nothing, so the low half is taken.
        func u64(_ offset: Int) -> UInt64 {
            var value: UInt64 = 0
            for index in (0..<8).reversed() {
                value = (value << 8) | UInt64(bytes[offset + index])
            }
            return value
        }

        var sensors: [UInt16] = []
        for index in 0..<Self.sensorCount {
            let kelvin = u16(200 + index * 2)
            // 0 means "not implemented", not 0 K.
            if kelvin != 0 { sensors.append(kelvin) }
        }

        self.init(
            criticalWarning: bytes[0],
            compositeTemperatureKelvin: u16(1),
            availableSparePercent: bytes[3],
            availableSpareThresholdPercent: bytes[4],
            percentageUsed: bytes[5],
            dataUnitsRead: u64(32),
            dataUnitsWritten: u64(48),
            hostReadCommands: u64(64),
            hostWriteCommands: u64(80),
            controllerBusyTimeMinutes: u64(96),
            powerCycles: u64(112),
            powerOnHours: u64(128),
            unsafeShutdowns: u64(144),
            mediaAndDataIntegrityErrors: u64(160),
            errorInformationLogEntries: u64(176),
            warningCompositeTemperatureMinutes: u32(192),
            criticalCompositeTemperatureMinutes: u32(196),
            sensorsKelvin: sensors
        )
    }

    /// One NVMe "data unit" is 1000 × 512 bytes.
    public static func bytes(fromDataUnits units: UInt64) -> UInt64 { units &* 512_000 }
}
