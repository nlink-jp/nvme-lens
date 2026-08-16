import Foundation

/// What IOKit says about a physical drive, before any SMART call is attempted.
public struct DriveDescriptor: Equatable, Sendable {
    public var bsdName: String
    public var productName: String
    public var serialNumber: String
    /// "Apple Fabric", "PCI-Express", "USB", "Secure Digital", "Virtual Interface", …
    public var physicalInterconnect: String
    /// "Internal", "External", "File".
    public var physicalInterconnectLocation: String
    /// Carries the "NVMe SMART Capable" property. Necessary but **not
    /// sufficient**: an empty USB NVMe caddy advertises it and then fails every
    /// call, which is what makes naive enumeration untrustworthy.
    public var smartCapable: Bool

    public init(
        bsdName: String, productName: String, serialNumber: String, physicalInterconnect: String,
        physicalInterconnectLocation: String, smartCapable: Bool
    ) {
        self.bsdName = bsdName
        self.productName = productName
        self.serialNumber = serialNumber
        self.physicalInterconnect = physicalInterconnect
        self.physicalInterconnectLocation = physicalInterconnectLocation
        self.smartCapable = smartCapable
    }
}

/// Result of actually trying to read SMART from a drive.
public enum ReadOutcome: Equatable, Sendable {
    /// No SMART-capable service matched this drive, so nothing was tried.
    case notAttempted
    case succeeded
    /// The call was made and IOKit returned this `IOReturn`.
    case failed(status: Int32)
}

public enum UnmonitorableReason: Equatable, Sendable {
    /// Attached over USB. No amount of software fixes this.
    case usbAttachment
    /// Not an NVMe drive at all (SD reader, SATA bridge, …).
    case notNVMe(interconnect: String)
    /// A disk image or other synthetic device — not a physical drive.
    case virtualDevice
    /// Advertised SMART capability but did not answer. An empty drive caddy
    /// behaves exactly like this.
    case advertisedButUnresponsive(status: Int32)

    /// Shown to the user. Every reason names a cause, and where a remedy exists
    /// it names that too — a drive silently missing from the list reads as
    /// "broken" or "not detected".
    public var explanation: String {
        switch self {
        case .usbAttachment:
            return
                "attached over USB — macOS provides no SMART path to USB storage. "
                + "A Thunderbolt/USB4 enclosure that tunnels PCIe makes this drive readable."
        case .notNVMe(let interconnect):
            return "not an NVMe drive (interconnect: \(interconnect.isEmpty ? "unknown" : interconnect))"
        case .virtualDevice:
            return "virtual device (disk image), not physical storage"
        case .advertisedButUnresponsive(let status):
            return String(
                format: "reports SMART capability but did not answer (IOReturn 0x%08x) — "
                    + "an empty drive enclosure behaves this way", UInt32(bitPattern: status))
        }
    }
}

public enum DriveState: Equatable, Sendable {
    case monitored
    case unmonitorable(UnmonitorableReason)

    public var isMonitored: Bool { self == .monitored }
}

public enum DriveClassifier {
    public static let virtualInterconnect = "Virtual Interface"
    public static let usbInterconnect = "USB"

    /// Pure classification, so the rules can be tested without a machine that
    /// happens to have the right drives attached.
    ///
    /// Order matters. A USB caddy both advertises SMART capability *and* fails
    /// its calls; reporting "did not answer" would be true and useless, while
    /// "attached over USB" is the fact the user can act on.
    public static func classify(descriptor: DriveDescriptor, readOutcome: ReadOutcome) -> DriveState
    {
        if descriptor.physicalInterconnect == virtualInterconnect {
            return .unmonitorable(.virtualDevice)
        }
        if readOutcome == .succeeded {
            return .monitored
        }
        if descriptor.physicalInterconnect == usbInterconnect {
            return .unmonitorable(.usbAttachment)
        }
        if !descriptor.smartCapable {
            return .unmonitorable(.notNVMe(interconnect: descriptor.physicalInterconnect))
        }
        if case .failed(let status) = readOutcome {
            return .unmonitorable(.advertisedButUnresponsive(status: status))
        }
        return .unmonitorable(.advertisedButUnresponsive(status: 0))
    }
}

/// A drive plus whatever could be learned about it.
public struct DriveRecord: Equatable, Sendable {
    public var descriptor: DriveDescriptor
    public var state: DriveState
    public var identity: ControllerIdentity?
    public var health: SmartHealth?

    public init(
        descriptor: DriveDescriptor, state: DriveState, identity: ControllerIdentity? = nil,
        health: SmartHealth? = nil
    ) {
        self.descriptor = descriptor
        self.state = state
        self.identity = identity
        self.health = health
    }

    /// Serial number from Identify Controller when available, falling back to
    /// what IOKit advertised. This is the key drives are addressed by.
    public var serialNumber: String {
        if let identity, !identity.serialNumber.isEmpty { return identity.serialNumber }
        return descriptor.serialNumber
    }

    public var displayName: String {
        if let identity, !identity.modelNumber.isEmpty { return identity.modelNumber }
        return descriptor.productName.isEmpty ? descriptor.bsdName : descriptor.productName
    }
}
