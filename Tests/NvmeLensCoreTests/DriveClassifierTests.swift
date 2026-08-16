import Testing

@testable import NvmeLensCore

private func descriptor(
    interconnect: String, smartCapable: Bool, location: String = "External"
) -> DriveDescriptor {
    DriveDescriptor(
        bsdName: "disk9", productName: "TEST", serialNumber: "SERIAL",
        physicalInterconnect: interconnect, physicalInterconnectLocation: location,
        smartCapable: smartCapable)
}

@Suite("DriveClassifier")
struct DriveClassifierTests {
    @Test("a drive that answered is monitored")
    func succeeded() {
        let state = DriveClassifier.classify(
            descriptor: descriptor(interconnect: "PCI-Express", smartCapable: true),
            readOutcome: .succeeded)
        #expect(state == .monitored)
    }

    /// The internal Apple SSD reports "Apple Fabric", not "PCI-Express".
    /// Classifying on the interconnect string would have excluded it.
    @Test("the internal Apple Fabric drive is monitored like any other")
    func appleFabric() {
        let state = DriveClassifier.classify(
            descriptor: descriptor(
                interconnect: "Apple Fabric", smartCapable: true, location: "Internal"),
            readOutcome: .succeeded)
        #expect(state == .monitored)
    }

    /// Observed on real hardware: an empty USB NVMe caddy advertises
    /// "NVMe SMART Capable" and then fails every call. "did not answer" would be
    /// true and useless; "attached over USB" is what the user can act on.
    @Test("a USB drive that advertises capability and fails reports the USB reason")
    func usbBeatsUnresponsive() {
        let state = DriveClassifier.classify(
            descriptor: descriptor(interconnect: "USB", smartCapable: true),
            readOutcome: .failed(status: -536_870_198))
        #expect(state == .unmonitorable(.usbAttachment))
    }

    @Test("a USB drive that never advertised capability still reports the USB reason")
    func usbWithoutCapability() {
        let state = DriveClassifier.classify(
            descriptor: descriptor(interconnect: "USB", smartCapable: false),
            readOutcome: .notAttempted)
        #expect(state == .unmonitorable(.usbAttachment))
    }

    @Test("a non-NVMe device names its interconnect")
    func notNVMe() {
        let state = DriveClassifier.classify(
            descriptor: descriptor(interconnect: "Secure Digital", smartCapable: false),
            readOutcome: .notAttempted)
        #expect(state == .unmonitorable(.notNVMe(interconnect: "Secure Digital")))
    }

    @Test("a disk image is classified as virtual, whatever else is true of it")
    func virtualDevice() {
        let state = DriveClassifier.classify(
            descriptor: descriptor(interconnect: "Virtual Interface", smartCapable: true),
            readOutcome: .succeeded)
        #expect(state == .unmonitorable(.virtualDevice))
    }

    @Test("a PCIe NVMe drive that fails is reported as unresponsive with its status")
    func pcieUnresponsive() {
        let state = DriveClassifier.classify(
            descriptor: descriptor(interconnect: "PCI-Express", smartCapable: true),
            readOutcome: .failed(status: 42))
        #expect(state == .unmonitorable(.advertisedButUnresponsive(status: 42)))
    }

    @Test("every unmonitorable reason explains itself in non-empty prose")
    func reasonsExplainThemselves() {
        let reasons: [UnmonitorableReason] = [
            .usbAttachment, .notNVMe(interconnect: "SATA"), .virtualDevice,
            .advertisedButUnresponsive(status: -536_870_198),
        ]
        for reason in reasons {
            #expect(!reason.explanation.isEmpty)
        }
        // The USB case is the one a user can actually resolve, so it must say how.
        #expect(UnmonitorableReason.usbAttachment.explanation.contains("Thunderbolt"))
    }
}
