// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RunbotAIWatch",
    platforms: [
        .watchOS(.v9)
    ],
    dependencies: [
    ],
    targets: [
        .executableTarget(
            name: "RunbotAIWatch",
            dependencies: [],
            path: "Sources/RunbotAIWatch"
        )
    ]
)
