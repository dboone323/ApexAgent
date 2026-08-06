// swift-tools-version:6.4
import PackageDescription

let package = Package(
    name: "ApexAgentXcodePlugin",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "ApexAgentMCPServer",
            path: "Sources/ApexAgentMCPServer"
        )
    ]
)
