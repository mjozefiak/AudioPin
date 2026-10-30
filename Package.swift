// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "AudioPin",
    platforms: [.macOS(.v27)],
    targets: [
        .executableTarget(name: "AudioPin")
    ],
    swiftLanguageModes: [.v6]
)
