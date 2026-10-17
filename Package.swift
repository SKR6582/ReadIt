// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ReadIt",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "ReadIt",
            path: "Sources/LiveCaption"
        )
    ]
)
