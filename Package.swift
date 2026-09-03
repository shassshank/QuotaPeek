// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AIUsageWidget",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "AIUsageWidget",
            path: "Sources/AIUsageWidget"
        )
    ]
)
