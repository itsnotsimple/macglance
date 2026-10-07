// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MacGlance",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MacGlance",
            dependencies: ["CSensors", "Shared"],
            path: "Sources/MacGlance",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The macOS widgets: an app extension, packed into MacGlance.app/Contents/PlugIns by build-app.sh.
        .executableTarget(
            name: "MacGlanceWidgets",
            dependencies: ["Shared"],
            path: "Sources/MacGlanceWidgets",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // What the app and the widgets both need: the snapshot file the app writes and the widgets read.
        .target(
            name: "Shared",
            path: "Sources/Shared",
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
