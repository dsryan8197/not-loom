// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NotLoom",
    platforms: [.macOS("15.0")],
    targets: [
        .executableTarget(name: "NotLoom", path: "Sources/NotLoom")
    ]
)
