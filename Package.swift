// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CrateSort",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "CrateSort", path: "Sources/CrateSort")
    ]
)
