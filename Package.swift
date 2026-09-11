// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuotaPeek",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "QuotaPeek",
            path: "Sources/QuotaPeek"
        )
    ]
)
