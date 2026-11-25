// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "QuotaPeek",
    platforms: [.macOS(.v13)],
    targets: [
        // Models, formatting, gauges and the snapshot contract shared by the
        // app and the widget extension.
        .target(
            name: "QuotaPeekCore",
            path: "Sources/QuotaPeekCore"
        ),
        .executableTarget(
            name: "QuotaPeek",
            dependencies: ["QuotaPeekCore"],
            path: "Sources/QuotaPeek"
        ),
        // Widget timeline logic and style views, separate from the extension
        // so they can be unit-tested and rendered to preview images.
        .target(
            name: "QuotaPeekWidgetUI",
            dependencies: ["QuotaPeekCore"],
            path: "Sources/QuotaPeekWidgetUI",
            swiftSettings: [.unsafeFlags(["-application-extension"])]
        ),
        // Native WidgetKit extension. Built as a plain executable and wrapped
        // into Contents/PlugIns/QuotaPeekWidget.appex by build-app-bundle.sh.
        // App extensions start at NSExtensionMain (what Xcode links for
        // extension targets); without it the extension traps at launch.
        .executableTarget(
            name: "QuotaPeekWidget",
            dependencies: ["QuotaPeekCore", "QuotaPeekWidgetUI"],
            path: "Sources/QuotaPeekWidget",
            swiftSettings: [.unsafeFlags(["-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-Xlinker", "-application_extension"])]
        ),
        .testTarget(
            name: "QuotaPeekTests",
            dependencies: ["QuotaPeek", "QuotaPeekCore", "QuotaPeekWidgetUI"],
            path: "Tests/QuotaPeekTests"
        )
    ]
)
