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
    ],
    targets: [
        // ─────────────────────────────────────────────────────────────────────
        // INLINED shared-kit modules (formerly github.com/dboone323/shared-kit).
        // Pure-Foundation, ~1,800 LOC. Kept as separate local targets so the
        // existing `import SharedKit / MCPKit / SharedModels` statements in
        // app + test sources compile unchanged. Dependency graph mirrors the
        // original package exactly. SharedUI was unused and intentionally
        // dropped. The `AI` routing module was removed as dead code (its
        // ModelRouter singleton was stored but never invoked).
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
            name: "MCPKit",
            dependencies: ["SharedLogging"],
            path: "Modules/MCPKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),
        .target(
            name: "SharedKit",
            dependencies: ["SharedModels", "SharedLogging"],
            path: "Modules/SharedKit",
            swiftSettings: [.enableUpcomingFeature("StrictConcurrency")]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // ApexAgentCore: All app logic, INCLUDING the container runtime
        // (ContainerManager) and the @main app entry point (ApexAgentApp).
        //
        // ContainerManager is kept here (not a separate target) so the app entry
        // point can reach it without `@testable import ApexAgentCore` — which
        // previously broke `swift build -c release`. The container test target
        // links ApexAgentCore directly, so no `-testable` executable variant is
        // forced. CoreDevice double-load in FoundationModels tests is avoided by
        // NOT depending on FoundationModels here (it is weak-linked by the app).
        // ─────────────────────────────────────────────────────────────────────
        .target(
            name: "ApexAgentCore",
            dependencies: [
                "SharedKit",
                "MCPKit",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ],
            path: "ApexAgent",
            exclude: [
                "ApexAgent.entitlements",
                "Info.plist",
            ],
            resources: [
                .process("Resources")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency"),
            ]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // ApexAgent: Thin executable entry point. ApexAgentApp (the @main App)
        // lives in ApexAgentCore; this target just calls ApexAgentApp.main().
        // ─────────────────────────────────────────────────────────────────────
        .executableTarget(
            name: "ApexAgent",
            dependencies: [
                "ApexAgentCore",
                "MCPKit",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ],
            path: "ApexAgentRuntime",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_AppKit",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_SwiftUI",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_Vision_FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_CoreSpotlight_FoundationModels",
                    // Sparkle.framework is linked transitively via ApexAgentCore;
                    // add the rpath so it dlopen's at app launch.
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"
                ])
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
            resources: [
                .copy("mock_mcp_server.sh"),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_AppKit",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_FoundationModels_SwiftUI",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_Vision_FoundationModels",
                    "-Xlinker", "-weak_framework", "-Xlinker", "_CoreSpotlight_FoundationModels",
                    // SwiftPM does not add the build-products dir to the test bundle's
                    // @rpath, so Sparkle.framework (linked transitively via ApexAgentCore)
                    // fails to dlopen at test launch. Add the rpath explicitly.
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."
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
                    "-Xlinker", "-weak_framework", "-Xlinker", "_CoreSpotlight_FoundationModels",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."
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
                    "-Xlinker", "-weak_framework", "-Xlinker", "_CoreSpotlight_FoundationModels",
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../../.."
                ])
            ]
        ),
    ]
)
