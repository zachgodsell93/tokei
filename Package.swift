// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageMonitor",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "AIUsageMonitor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AIUsageMonitorTests",
            dependencies: ["AIUsageMonitor"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
