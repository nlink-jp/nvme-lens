import Testing

@testable import NvmeLensCore

private func identifyBuffer(
    serial: String = "", model: String = "", firmware: String = "",
    warningKelvin: UInt16 = 0, criticalKelvin: UInt16 = 0
) -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: 4096)
    func write(_ text: String, at offset: Int, length: Int) {
        // NVMe pads these fields with spaces, not NULs.
        let padded = text.padding(toLength: length, withPad: " ", startingAt: 0)
        for (index, scalar) in padded.unicodeScalars.enumerated() where index < length {
            bytes[offset + index] = UInt8(scalar.value)
        }
    }
    write(serial, at: 4, length: 20)
    write(model, at: 24, length: 40)
    write(firmware, at: 64, length: 8)
    bytes[266] = UInt8(warningKelvin & 0xFF)
    bytes[267] = UInt8((warningKelvin >> 8) & 0xFF)
    bytes[268] = UInt8(criticalKelvin & 0xFF)
    bytes[269] = UInt8((criticalKelvin >> 8) & 0xFF)
    return bytes
}

@Suite("ControllerIdentity parsing")
struct ControllerIdentityTests {
    @Test("a buffer of the wrong length is rejected")
    func wrongLength() {
        #expect(throws: SmartParseError.wrongLength(expected: 4096, actual: 512)) {
            try ControllerIdentity(identify: [UInt8](repeating: 0, count: 512))
        }
    }

    @Test("space padding is trimmed from the identity strings")
    func trimsPadding() throws {
        let identity = try ControllerIdentity(
            identify: identifyBuffer(
                serial: "SERIAL000000", model: "EXAMPLE SSD 1TB", firmware: "FW000001"))
        #expect(identity.serialNumber == "SERIAL000000")
        #expect(identity.modelNumber == "EXAMPLE SSD 1TB")
        #expect(identity.firmwareRevision == "FW000001")
    }

    @Test("WCTEMP and CCTEMP are read from 266 and 268")
    func temperatureThresholds() throws {
        let identity = try ControllerIdentity(
            identify: identifyBuffer(warningKelvin: 357, criticalKelvin: 361))
        #expect(identity.warningTemperatureCelsius == 84)
        #expect(identity.criticalTemperatureCelsius == 88)
    }

    @Test("an unset threshold is absent rather than reported as -273 C")
    func unsetThresholds() throws {
        let identity = try ControllerIdentity(identify: identifyBuffer())
        #expect(identity.warningTemperatureCelsius == nil)
        #expect(identity.criticalTemperatureCelsius == nil)
    }
}
