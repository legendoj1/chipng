// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Chipng",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Chipng",
            path: "Sources/Chipng"
        ),
    ]
)
