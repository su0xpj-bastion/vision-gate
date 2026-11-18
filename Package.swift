// swift-tools-version:5.4
import PackageDescription

let package = Package(
    name: "vision-gate",
    platforms: [.macOS(.v11), .iOS(.v14)],
    products: [.library(name: "VisionGate", targets: ["VisionGate"])],
    targets: [
        .target(name: "VisionGate"),
        .executableTarget(name: "gate", dependencies: ["VisionGate"]),
        .testTarget(name: "VisionGateTests", dependencies: ["VisionGate"]),
    ]
)
