// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StratusKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StratusKit", targets: ["StratusKit"]),
    ],
    targets: [
        .target(name: "StratusKit"),
        .testTarget(
            name: "StratusKitTests",
            dependencies: ["StratusKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
