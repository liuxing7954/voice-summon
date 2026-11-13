// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "VoiceSummon",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "VoiceSummon", path: "Sources/VoiceSummon")
    ]
)
