// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "AgentUsage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentUsage", targets: ["AgentUsage"]),
    ],
    targets: [
        // UI-free logic: API models, credential lookup, local log scanning,
        // projections, alert planning and tips. Kept separate so it is testable.
        .target(name: "AgentUsageCore", path: "Sources/AgentUsageCore"),
        .executableTarget(
            name: "AgentUsage",
            dependencies: ["AgentUsageCore"],
            path: "Sources/AgentUsage"
        ),
        .testTarget(
            name: "AgentUsageCoreTests",
            dependencies: ["AgentUsageCore"],
            path: "Tests/AgentUsageCoreTests"
        ),
    ]
)
