// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GameLingo",
    platforms: [.macOS(.v14)],  // SCScreenshotManager 需要 macOS 14
    targets: [
        .executableTarget(
            name: "GameLingo",
            path: "Sources/GameLingo"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
