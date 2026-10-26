// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GoProTimelapser",
    // Catalina and later. The arm64 slice is automatically 11.0+ (Apple Silicon never ran anything older).
    platforms: [.macOS(.v10_15)],
    products: [
        .executable(name: "GoProTimelapser", targets: ["GoProTimelapser"]),
    ],
    targets: [
        .target(name: "TimelapserCore"),
        .executableTarget(name: "GoProTimelapser", dependencies: ["TimelapserCore"]),
        .testTarget(name: "TimelapserCoreTests", dependencies: ["TimelapserCore"]),
    ]
)
