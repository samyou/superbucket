// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SuperBucket",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "SuperBucketCore",
            path: "Sources/SuperBucketCore"
        ),
        .executableTarget(
            name: "SuperBucket",
            dependencies: [
                "SuperBucketCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/SuperBucket"
        ),
        .testTarget(
            name: "SuperBucketCoreTests",
            dependencies: ["SuperBucketCore"],
            path: "Tests/SuperBucketCoreTests"
        ),
    ]
)
