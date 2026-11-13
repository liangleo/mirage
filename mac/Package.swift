// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mirage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MirageCore", targets: ["MirageCore"]),
    ],
    targets: [
        .target(name: "MirageCore"),
        .testTarget(name: "MirageCoreTests", dependencies: ["MirageCore"]),
    ]
)