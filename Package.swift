// swift-tools-version: 5.9
import PackageDescription

// The portable core builds everywhere. The macOS menu-bar app builds on
// macOS only; each platform shell builds on its own OS. This keeps
// `swift build` green on every platform without cross-compiling UI code.

let coreTarget = Target.target(
    name: "MeterUsageCore",
    path: "Sources/MeterUsageCore"
)

#if os(macOS)
let package = Package(
    name: "MeterUsage",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "MeterUsageCore", targets: ["MeterUsageCore"]),
        .executable(name: "meterusage", targets: ["MeterUsage"])
    ],
    targets: [
        coreTarget,
        .executableTarget(
            name: "MeterUsage",
            dependencies: ["MeterUsageCore"],
            path: "Sources/MeterUsage"
        ),
        .testTarget(
            name: "MeterUsageTests",
            dependencies: ["MeterUsage", "MeterUsageCore"],
            path: "Tests/MeterUsageTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
#elseif os(Linux)
let package = Package(
    name: "MeterUsage",
    products: [
        .library(name: "MeterUsageCore", targets: ["MeterUsageCore"]),
        .executable(name: "meterusage-linux", targets: ["MeterUsageLinux"])
    ],
    targets: [
        coreTarget,
        .systemLibrary(
            name: "CGtk3",
            path: "Sources/CGtk3",
            pkgConfig: "gtk+-3.0"
        ),
        .systemLibrary(
            name: "CAyatanaAppIndicator3",
            path: "Sources/CAyatanaAppIndicator3",
            pkgConfig: "ayatana-appindicator3-0.1"
        ),
        .executableTarget(
            name: "MeterUsageLinux",
            dependencies: ["MeterUsageCore", "CGtk3", "CAyatanaAppIndicator3"],
            path: "Sources/MeterUsageLinux"
        )
    ]
)
#else
let package = Package(
    name: "MeterUsage",
    products: [
        .library(name: "MeterUsageCore", targets: ["MeterUsageCore"]),
        .executable(name: "meterusage-windows", targets: ["MeterUsageWindows"])
    ],
    targets: [
        coreTarget,
        .executableTarget(
            name: "MeterUsageWindows",
            dependencies: ["MeterUsageCore"],
            path: "Sources/MeterUsageWindows"
        )
    ]
)
#endif
