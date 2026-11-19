// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "BBManagerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "BBManagerKit", targets: ["BBManagerKit"]),
    ],
    targets: [
        .target(name: "BBManagerKit"),
        .testTarget(name: "BBManagerKitTests", dependencies: ["BBManagerKit"]),
    ]
)
