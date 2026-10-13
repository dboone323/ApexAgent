// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "ApexAgent",
    platforms: [
        .macOS("27.0")
    ],
    products: [
        .executable(name: "ApexAgent", targets: ["ApexAgent"]),
        .executable(name: "sandboxctl", targets: ["sandboxctl"]),
        .executable(name: "apexflow", targets: ["apexflow"]),
        .executable(name: "benchmark-repro", targets: ["benchmark-repro"])
    ],
    dependencies: [
        // Shared modules are local targets under Modules/
        // (SharedLogging, SharedModels, Utilities, MCPKit, SharedKit).
        // Container runtime — pinned to release tag 0.38.0 (= revision d9868bb,
        // the same revision apple/container's own Package.resolved pins). The
        // host library and the guest vminit initfs image MUST be the same
        // version: vmexec's sync-pipe protocol changed between 0.37.0 and
        // 0.38.0 ("no PID data from sync pipe" on mismatch).
        .package(url: "https://github.com/apple/containerization.git", exact: "0.38.0"),
        // Explicitly declare transitive Apple infrastructure packages.
        // Pinned exact to match project.yml and Package.resolved (1.14.0).
        .package(url: "https://github.com/apple/swift-log.git", exact: "1.14.0"),
    ],
    targets: [
        // ─────────────────────────────────────────────────────────────────────
        // Local shared modules (Modules/). Pure-Foundation, ~1,800 LOC.
        // Maintained as separate local targets for modularity and clean
        // architecture across app and test targets.
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
            exclude: ["README.md"],
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
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
                .product(name: "ContainerizationArchive", package: "containerization"),
                .product(name: "ContainerizationOS", package: "containerization"),
            ],
            path: "ApexAgent",
            exclude: [
                "ApexAgent.entitlements",
                "Info.plist",
                "Assets.xcassets",
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
                "ApexAgentIntents",
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
                    // ApexAgentCore's SPM deps (Containerization, etc.) are linked into
                    // the app; add the rpath so they dlopen at app launch.
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"
                ])
            ]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // ApexAgentIntents: App Intents (Siri / Shortcuts) exposing ApexAgent's
        // on-device model to the system. Backed by the real `fm` CLI. AppIntents
        // is a system framework on macOS; link it explicitly.
        // ─────────────────────────────────────────────────────────────────────
        .target(
            name: "ApexAgentIntents",
            dependencies: ["ApexAgentCore"],
            path: "ApexAgentIntents",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
            linkerSettings: [
                .unsafeFlags(["-framework", "AppIntents"])
            ]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // sandboxctl: entitled verification harness for the Apple Container
        // sandbox. The xctest agent cannot carry the virtualization
        // entitlement, so the real VM boot is proven by this CLI after ad-hoc
        // signing it with ApexAgent.entitlements (see Tools/sandboxctl/main.swift).
        // ─────────────────────────────────────────────────────────────────────
        .executableTarget(
            name: "sandboxctl",
            dependencies: [
                "ApexAgentCore",
                .product(name: "Containerization", package: "containerization"),
                .product(name: "ContainerizationOCI", package: "containerization"),
            ],
            path: "Tools/sandboxctl",
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
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"
                ])
            ]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // apexflow: runs ApexAgent automation workflows
        // ─────────────────────────────────────────────────────────────────────
        .executableTarget(
            name: "apexflow",
            dependencies: [
                "ApexAgentCore"
            ],
            path: "Tools/apexflow",
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
                    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"
                ])
            ]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // benchmark-repro: reproduces LanguageModelSession latency benchmarks
        // ─────────────────────────────────────────────────────────────────────
        .executableTarget(
            name: "benchmark-repro",
            path: "Tools/benchmark-repro",
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ],
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
                "MCPKit",
                // Mirrors project.yml (ApexAgentTests links Logging there).
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "ApexAgentTests",
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
                    // SwiftPM auto-adds the build-products rpath for test targets;
                    // the explicit -rpath caused a duplicate linker warning.
                ])
            ]
        ),

        // ─────────────────────────────────────────────────────────────────────
        // ApexAgentContainerTests: Tests specifically verifying container logic.
        //
        // Links against ApexAgentCore only (which already links the
        // Containerization products). Does NOT import FoundationModels in its
        // tests, avoiding loading conflict.
        // ─────────────────────────────────────────────────────────────────────
        .testTarget(
            name: "ApexAgentContainerTests",
            dependencies: [
                "ApexAgentCore",
            ],
            path: "ApexAgentContainerTests",
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
                ])
            ]
        ),
    ]
)
