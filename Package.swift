// swift-tools-version: 6.0
import PackageDescription

// The logic lives in NvmeLensCore so it can be unit-tested without a device.
// The executable target stays a thin entry point (see docs ADR-0001).
let package = Package(
    name: "NvmeLens",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NvmeLens", targets: ["NvmeLens"]),
        .library(name: "NvmeLensCore", targets: ["NvmeLensCore"]),
    ],
    targets: [
        .executableTarget(
            name: "NvmeLens",
            dependencies: ["NvmeLensCore"],
            path: "Sources/NvmeLens"
        ),
        .target(
            name: "NvmeLensCore",
            dependencies: ["CNvmeSmart"],
            path: "Sources/NvmeLensCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // CFPlugIn COM against IOKit's NVMe SMART interface is awkward from
        // Swift, so the COM dance is isolated here (ADR-0001).
        .target(
            name: "CNvmeSmart",
            path: "Sources/CNvmeSmart",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // The executable target is testable too: the status-bar renderer picks
        // SF Symbol names, and a name that does not resolve fails silently.
        .testTarget(
            name: "NvmeLensTests",
            dependencies: ["NvmeLens"],
            path: "Tests/NvmeLensTests"
        ),
        .testTarget(
            name: "NvmeLensCoreTests",
            dependencies: ["NvmeLensCore"],
            path: "Tests/NvmeLensCoreTests"
        ),
    ]
)
