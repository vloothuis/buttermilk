// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Buttermilk",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ButtermilkCore", targets: ["ButtermilkCore"]),
    ],
    targets: [
        .target(name: "ButtermilkCore"),
        .testTarget(
            name: "ButtermilkCoreTests",
            dependencies: ["ButtermilkCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
