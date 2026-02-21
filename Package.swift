// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JunaGeotagger",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "JunaGeotagger",
            path: "JunaGeotagger"
        ),
    ]
)
