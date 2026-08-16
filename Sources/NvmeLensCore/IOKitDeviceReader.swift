import CNvmeSmart
import Foundation

/// Reads drives and their SMART data through IOKit.
///
/// This is the one type that touches the device, so it stays deliberately thin:
/// gather bytes, hand them to the pure parsers, hand the outcome to the pure
/// classifier. Everything worth testing lives in those.
public enum IOKitDeviceReader {
    /// Every physical drive, monitorable or not, in IOKit enumeration order.
    ///
    /// Disk images are excluded by default. They are numerous on a working
    /// machine and are not storage anyone monitors the health of, so listing
    /// them buries the drives that matter.
    public static func readAll(includingVirtual: Bool = false) -> [DriveRecord] {
        let all = readAllRaw()
        guard !includingVirtual else { return all }
        return all.filter { $0.state != .unmonitorable(.virtualDevice) }
    }

    static func readAllRaw() -> [DriveRecord] {
        let samples = readSamples()

        var records: [DriveRecord] = []
        let driveCount = nl_drive_count()
        guard driveCount > 0 else { return [] }

        for index in 0..<driveCount {
            var raw = nl_drive()
            guard nl_drive_at(index, &raw) == 0 else { continue }
            let descriptor = DriveDescriptor(
                bsdName: string(from: &raw.bsdName),
                productName: string(from: &raw.productName),
                serialNumber: string(from: &raw.serialNumber),
                physicalInterconnect: string(from: &raw.physicalInterconnect),
                physicalInterconnectLocation: string(from: &raw.physicalInterconnectLocation),
                smartCapable: raw.smartCapable != 0
            )

            // Match a sample to a drive by BSD name; a sample with no BSD name
            // cannot be attributed to a drive and is handled separately below.
            let sample = samples.first { !$0.bsdName.isEmpty && $0.bsdName == descriptor.bsdName }
            let outcome = sample?.outcome ?? .notAttempted
            let state = DriveClassifier.classify(descriptor: descriptor, readOutcome: outcome)
            records.append(
                DriveRecord(
                    descriptor: descriptor, state: state, identity: sample?.identity,
                    health: sample?.health))
        }
        return records
    }

    /// Only the drives SMART could actually be read from.
    public static func readMonitored() -> [DriveRecord] {
        readAll().filter { $0.state.isMonitored }
    }

    // MARK: - Internals

    struct Sample {
        var bsdName: String
        var outcome: ReadOutcome
        var identity: ControllerIdentity?
        var health: SmartHealth?
    }

    static func readSamples() -> [Sample] {
        let count = nl_nvme_count()
        guard count > 0 else { return [] }

        var samples: [Sample] = []
        for index in 0..<count {
            var raw = nl_nvme_sample()
            guard nl_nvme_sample_at(index, &raw) == 0 else { continue }

            let bsdName = string(from: &raw.bsdName)
            guard raw.identifyStatus == 0, raw.logPageStatus == 0 else {
                // A device that advertises the capability and then fails is a
                // real, observed case (an empty USB caddy). Report the first
                // failing status rather than pretending nothing happened.
                let status = raw.identifyStatus != 0 ? raw.identifyStatus : raw.logPageStatus
                samples.append(Sample(bsdName: bsdName, outcome: .failed(status: status)))
                continue
            }

            let identifyBytes = withUnsafeBytes(of: &raw.identify) { Array($0) }
            let logBytes = withUnsafeBytes(of: &raw.smartLog) { Array($0) }
            let identity = try? ControllerIdentity(identify: identifyBytes)
            let health = try? SmartHealth(logPage: logBytes)
            guard let identity, let health else {
                samples.append(Sample(bsdName: bsdName, outcome: .failed(status: 0)))
                continue
            }
            samples.append(
                Sample(bsdName: bsdName, outcome: .succeeded, identity: identity, health: health))
        }
        return samples
    }

    /// Converts a fixed-size C char array to a String, stopping at the first NUL.
    private static func string<T>(from tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
