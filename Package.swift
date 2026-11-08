// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Still",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Still", targets: ["SnapShelf"])],
    targets: [
        .target(name: "SnapShelfCore"),
        .executableTarget(name: "SnapShelf", dependencies: ["SnapShelfCore"]),
        .testTarget(name: "SnapShelfCoreTests", dependencies: ["SnapShelfCore"], resources: [.copy("Fixtures")])
    ]
)
