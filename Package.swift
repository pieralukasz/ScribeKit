// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScribeKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "ScribeKit", targets: ["ScribeKit"]),
        .executable(name: "scribe", targets: ["scribe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
    ],
    targets: [
        .target(
            name: "ScribeKit",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]
        ),
        .executableTarget(
            name: "scribe",
            dependencies: ["ScribeKit"]
        ),
        .testTarget(
            name: "ScribeKitTests",
            dependencies: ["ScribeKit"]
        ),
    ]
)
