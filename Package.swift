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
        // shared-kit modules are now INLINED as local targets under Modules/
        // (see SharedLogging/SharedModels/Utilities/AI/MCPKit/SharedKit below).
        // The external github.com/dboone323/shared-kit dependency was removed to
        // make ApexAgent fully self-contained (no cross-repo coupling, no LFS,
        // no separate CI). shared-kit was pure-Foundation, so this is a clean lift.
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.6.0"),
        // Container runtime — pinned to 1.0 stable (June 2026 release)
        .package(url: "https://github.com/apple/containerization.git", branch: "main"),
        // Explicitly declare transitive Apple infrastructure packages
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.4.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.0.0"),
    ],
    targets: [
        // ─────────────────────────────────────────────────────────────────────
        // INLINED shared-kit modules (formerly github.com/dboone323/shared-kit).
        // Pure-Foundation, ~1,800 LOC. Kept as separate local targets so the
        // existing `import SharedKit / AI / MCPKit / SharedModels` statements in
        // app + test sources compile unchanged. Dependency graph mirrors the
        // original package exactly. SharedUI was unused and intentionally dropped.
        // ─────────────────────────────────────────────────────────────────────
        .target(
            name: "SharedLogging",
            path: "Modules/SharedLogging",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "SharedModels",
            dependencies: ["SharedLogging"],
            path: "Modules/SharedModels",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "Utilities",
            dependencies: ["SharedLogging", "SharedModels"],
            path: "Modules/Utilities",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "AI",
            dependencies: ["SharedLogging", "SharedModels"],
            path: "Modules/AI",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "MCPKit",
            dependencies: ["SharedLogging", "AI"],
            path: "Modules/MCPKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "SharedKit",
            dependencies: ["SharedModels", "SharedLogging", "Utilities"],
            path: "Modules/SharedKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // ApexAgentCore: All app logic EXCEPT the container runtime itself.
        //
        // Deliberately does NOT depend on Containerization so that the
        // ApexAgentIntelligenceTests target can link it without pulling in
        // CoreDevice.framework (which bundles a conflicting UniversalHID copy
        // that segfaults Vision/FoundationModels tests when loaded twice).
        // ─────────────────────────────────────────────────────────────────────
        .target(
            name: "ApexAgentCore",
            dependencies: [
                "SharedKit",
                "AI",
                "MCPKit",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            path: "ApexAgent",
            // Exclude the container runtime file — it imports Containerization and
            // must remain in the ApexAgent executable target only.
            exclude: [
                "ApexAgent.entitlements",
                "Info.plist",
                // Lives in ApexAgentRuntime — @main entry point + AppDelegate
                "ApexAgentApp.swift",
                // Lives in ApexAgentRuntime — imports Containerization package
                "Models/ContainerManager.swift",
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // ApexAgent: Thin executable that wires ApexAgentCore + Containerization.
        //
        // Only ContainerManager.swift lives here, as it is the single file that
        // imports the Containerization/ContainerizationOCI packages.
        // ─────────────────────────────────────────────────────────────────────
        .executableTarget(
            name: "ApexAgent",
            dependencies: [
                "ApexAgentCore",
                "AI",
                "MCPKit",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ],
            path: "ApexAgentRuntime",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // ApexAgentTests: Headless-safe unit + integration tests.
        //
        // Depends ONLY on ApexAgentCore (no Containerization), so CoreDevice
        // is never loaded into the xctest process. The UniversalHID conflict
        // cannot occur.
        // ─────────────────────────────────────────────────────────────────────
        .testTarget(
            name: "ApexAgentTests",
            dependencies: [
                "ApexAgentCore",
            ],
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
        ),

        // ─────────────────────────────────────────────────────────────────────
        // ApexAgentContainerTests: Tests specifically verifying container logic.
        //
        // Links against the full ApexAgent executable and Containerization package.
        // Does NOT import FoundationModels in its tests, avoiding loading conflict.
        // ─────────────────────────────────────────────────────────────────────
        .testTarget(
            name: "ApexAgentContainerTests",
            dependencies: [
                "ApexAgent",
                "ApexAgentCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ],
            path: "ApexAgentContainerTests",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_AppKit",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_SwiftUI",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_Vision_FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_CoreSpotlight_FoundationModels"
                ])
            ]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // ApexAgentIntelligenceTests: Vision, FoundationModels, AppleScript,
        // AppKit AppleEvents tests — the tests that previously segfaulted.
        //
        // Depends ONLY on ApexAgentCore (no Containerization), so CoreDevice
        // is never loaded into the xctest process. The UniversalHID conflict
        // cannot occur. All previously-skipped tests run here without guards.
        //
        // Uses Swift Testing (built into Swift 6 toolchain — no dep needed).
        // ─────────────────────────────────────────────────────────────────────
        .testTarget(
            name: "ApexAgentIntelligenceTests",
            dependencies: [
                "ApexAgentCore",
            ],
            path: "ApexAgentIntelligenceTests",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_AppKit",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_SwiftUI",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_Vision_FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_CoreSpotlight_FoundationModels"
                ])
            ]
        ),
    ]
)
