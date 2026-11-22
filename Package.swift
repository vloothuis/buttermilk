// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Buttermilk",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "ButtermilkCore", targets: ["ButtermilkCore"]),
        .library(name: "ButtermilkView", targets: ["ButtermilkView"]),
        .library(name: "ButtermilkMarkdown", targets: ["ButtermilkMarkdown"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-markdown.git", from: "0.5.0"),
    ],
    targets: [
        .target(name: "ButtermilkCore"),
        .target(name: "ButtermilkView", dependencies: ["ButtermilkCore"]),
        .testTarget(name: "ButtermilkViewTests", dependencies: ["ButtermilkView"]),
        .target(name: "ButtermilkMarkdown", dependencies: ["ButtermilkCore", .product(name: "Markdown", package: "swift-markdown")]),
        .testTarget(name: "ButtermilkMarkdownTests", dependencies: ["ButtermilkMarkdown"], resources: [.copy("Fixtures")]),
        .testTarget(
            name: "ButtermilkCoreTests",
            dependencies: ["ButtermilkCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
