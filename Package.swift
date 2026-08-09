// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionSearchWidget",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "SessionSearchWidget",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        )
    ]
)
