// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JunaGeotagger",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "JunaGeotagger",
            path: "JunaGeotagger",
            resources: [
                .process("ko.lproj"),
                .process("en.lproj"),
                .process("fr.lproj"),
                .process("ja.lproj"),
            ]
        ),
    ]
)
