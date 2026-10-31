// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SonyLogMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        // Pure color/exposure math. The Metal shader is generated from these same
        // constants, so the preview and the self-check can't drift apart.
        .target(name: "MonitorCore"),
        .executableTarget(name: "SonyLogMonitor", dependencies: ["MonitorCore"]),
        // `swift run SelfCheck` — XCTest isn't available without full Xcode.
        .executableTarget(name: "SelfCheck", dependencies: ["MonitorCore"]),
    ]
)
