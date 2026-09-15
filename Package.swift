// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacGlance",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacGlance",
            dependencies: ["CSensors"],
            path: "Sources/MacGlance",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // C code for hardware sensors that have no Swift-friendly API (SMC, HID temperatures, NVMe SMART, IOReport).
        .target(
            name: "CSensors",
            path: "Sources/CSensors",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("CoreFoundation"), .linkedLibrary("IOReport")]
        ),
    ]
)
