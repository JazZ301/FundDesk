// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FundDesk",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "FundDesk", targets: ["FundDesk"])],
    targets: [
        .target(name: "FundCore"),
        .executableTarget(name: "FundDesk", dependencies: ["FundCore"]),
        .testTarget(name: "FundCoreTests", dependencies: ["FundCore"])
    ]
)
