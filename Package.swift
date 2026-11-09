// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TokenMeter",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TokenMeterCore", targets: ["TokenMeterCore"]),
        .executable(name: "tokenmeter", targets: ["tokenmeter"]),
        .executable(name: "TokenMeterApp", targets: ["TokenMeterApp"]),
    ],
    targets: [
        .target(name: "TokenMeterCore"),
        .executableTarget(name: "tokenmeter", dependencies: ["TokenMeterCore"]),
        .executableTarget(name: "TokenMeterApp", dependencies: ["TokenMeterCore"]),
    ]
)
