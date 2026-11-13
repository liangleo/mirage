// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mirage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MirageCore", targets: ["MirageCore"]),
        .executable(name: "mirage-helper", targets: ["MirageHelperCLI"]),
    ],
    targets: [
        .target(name: "MirageCore"),
        .target(name: "MirageHelper", dependencies: ["MirageCore"]),
        .executableTarget(
            name: "MirageHelperCLI",
            dependencies: ["MirageHelper", "MirageCore"],
            path: "Sources/mirage-helper"
        ),
        .testTarget(name: "MirageCoreTests", dependencies: ["MirageCore", "MirageHelper"]),
    ]
)