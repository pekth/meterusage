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
        // WidgetKit extension. Deliberately has no dependency on MeterUsage:
        // it runs out-of-process and its only input is the snapshot JSON file
        // the app writes after every refresh, so the schema is the contract.
        .executableTarget(
            name: "MeterUsageWidget",
            path: "Sources/MeterUsageWidget",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "MeterUsageTests",
            dependencies: ["MeterUsage"],
            path: "Tests/MeterUsageTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
