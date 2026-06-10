// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "murmur",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "LocalPackages/SherpaOnnx"),
    ],
    targets: [
        .executableTarget(
            name: "murmur",
            dependencies: ["MurmurCore"],
            path: "Sources/App",
            resources: [.process("Resources")]
        ),
        .target(
            name: "MurmurCore",
            dependencies: [
                .product(name: "CSherpaOnnx", package: "SherpaOnnx"),
            ],
            path: "Sources/MurmurCore"
        ),
        .executableTarget(
            name: "MurmurTests",
            dependencies: ["MurmurCore"],
            path: "Tests/MurmurTests"
        ),
    ],
    // The app's concurrency model targets the Swift 5 language mode; building under
    // Swift 6 strict concurrency surfaces non-Sendable capture errors
    // (CFMachPort / OpaquePointer in @Sendable closures). Pin to v5 to match intent.
    swiftLanguageModes: [.v5]
)
