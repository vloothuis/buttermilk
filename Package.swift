// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Buttermilk",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ButtermilkCore", targets: ["ButtermilkCore"]),
        .library(name: "ButtermilkView", targets: ["ButtermilkView"]),
    ],
    targets: [
        .target(name: "ButtermilkCore"),
        .target(name: "ButtermilkView", dependencies: ["ButtermilkCore"]),
        .testTarget(name: "ButtermilkViewTests", dependencies: ["ButtermilkView"]),
        .testTarget(
            name: "ButtermilkCoreTests",
            dependencies: ["ButtermilkCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
