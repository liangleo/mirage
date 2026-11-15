// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mirage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MirageCore", targets: ["MirageCore"]),
        .executable(name: "mirage-helper", targets: ["MirageHelperCLI"]),
        .executable(name: "mirage-menu", targets: ["MirageMenu"]),
    ],
    dependencies: [],
    targets: [
        .target(name: "MirageCore"),
        .target(
            name: "CGVirtualDisplayBridge",
            path: "Sources/CGVirtualDisplayBridge",
            publicHeadersPath: "include"
        ),
        .target(name: "MirageHelper", dependencies: ["MirageCore", "CGVirtualDisplayBridge"]),
        .executableTarget(
            name: "MirageHelperCLI",
            dependencies: ["MirageHelper", "MirageCore"],
            path: "Sources/MirageHelperCLI"
        ),
        .executableTarget(
            name: "MirageMenu",
            dependencies: ["MirageCore", "MirageHelper"],
            path: "Sources/MirageMenu"
        ),
        .testTarget(name: "MirageCoreTests", dependencies: ["MirageCore", "MirageHelper"]),
    ]
)