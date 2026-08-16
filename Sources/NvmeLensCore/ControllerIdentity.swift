import Foundation

/// The fields nvme-lens needs from a 4096-byte Identify Controller structure.
public struct ControllerIdentity: Equatable, Sendable {
    /// Serial Number, trimmed. This is the device key: BSD names and IOService
    /// paths both change across reconnects.
    public var serialNumber: String
    public var modelNumber: String
    public var firmwareRevision: String
    /// Warning Composite Temperature Threshold (WCTEMP), Kelvin, 0 if unset.
    ///
    /// Note this is a threshold on *composite*, not on the hotspot — a drive can
    /// sit well under it while a sensor runs far hotter, which is why nvme-lens
    /// carries its own thresholds instead of deferring to this one.
    public var warningTemperatureKelvin: UInt16
    /// Critical Composite Temperature Threshold (CCTEMP), Kelvin, 0 if unset.
    public var criticalTemperatureKelvin: UInt16

    public static let identifySize = 4096

    public var warningTemperatureCelsius: Int? {
        warningTemperatureKelvin == 0 ? nil : SmartHealth.celsius(fromKelvin: warningTemperatureKelvin)
    }

    public var criticalTemperatureCelsius: Int? {
        criticalTemperatureKelvin == 0
            ? nil : SmartHealth.celsius(fromKelvin: criticalTemperatureKelvin)
    }
}

extension ControllerIdentity {
    public init(identify bytes: [UInt8]) throws {
        guard bytes.count == Self.identifySize else {
            throw SmartParseError.wrongLength(expected: Self.identifySize, actual: bytes.count)
        }

        func string(_ range: Range<Int>) -> String {
            let scalars = bytes[range].map { Character(UnicodeScalar($0)) }
            return String(scalars).trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
        }

        self.init(
            serialNumber: string(4..<24),
            modelNumber: string(24..<64),
            firmwareRevision: string(64..<72),
            warningTemperatureKelvin: u16(266),
            criticalTemperatureKelvin: u16(268)
        )
    }
}
