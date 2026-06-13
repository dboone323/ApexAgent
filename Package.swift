// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ApexAgent",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "ApexAgent", targets: ["ApexAgent"])
    ],
    dependencies: [
        .package(path: "/Users/danielstevens/github-projects/fleet/packages/shared-kit"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "ApexAgent",
            dependencies: [
                .product(name: "SharedKit", package: "shared-kit"),
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "ApexAgent",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ApexAgentTests",
            dependencies: ["ApexAgent"],
            path: "ApexAgentTests"
        )
    ]
)
