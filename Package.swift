// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokei",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Tokei",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TokeiTests",
            dependencies: ["Tokei"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
