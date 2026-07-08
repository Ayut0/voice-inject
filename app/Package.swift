// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "VoiceInject",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VoiceInject", path: "Sources/VoiceInject"),
        .testTarget(name: "VoiceInjectTests", dependencies: ["VoiceInject"], path: "Tests/VoiceInjectTests"),
    ]
)
