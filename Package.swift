// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeterUsage",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "meterusage", targets: ["MeterUsage"])
    ],
    targets: [
        .executableTarget(
            name: "MeterUsage",
            path: "Sources/MeterUsage"
        ),
        .testTarget(
            name: "MeterUsageTests",
            dependencies: ["MeterUsage"],
            path: "Tests/MeterUsageTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
