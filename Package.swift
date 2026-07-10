// swift-tools-version: 6.4
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
        .package(path: "../packages/shared-kit"),
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
            exclude: ["ApexAgent.entitlements", "Info.plist"],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "ApexAgentTests",
            dependencies: ["ApexAgent", .product(name: "Sparkle", package: "Sparkle")],
            path: "ApexAgentTests",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_AppKit",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_SwiftUI",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_Vision_FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_CoreSpotlight_FoundationModels"
                ])
            ]
        )
    ]
)
