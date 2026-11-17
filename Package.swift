// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CopyCard",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CopyCore", targets: ["CopyCore"]), .executable(name: "CopyCard", targets: ["CopyApp"])],
    targets: [
        .target(name: "CopyCore"),
        .executableTarget(name: "CopyApp", dependencies: ["CopyCore"]),
        .testTarget(name: "CopyCoreTests", dependencies: ["CopyCore"]),
        .testTarget(name: "CopyAppTests", dependencies: ["CopyApp", "CopyCore"])
    ]
)
