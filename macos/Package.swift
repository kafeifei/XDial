// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "XDial",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "XDial",
            path: "Sources/XDial"
        ),
    ]
)
