// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "macos-auto-tiler",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "macos-auto-tiler", targets: ["MacOSAutoTiler"])
    ],
    targets: [
        .executableTarget(
            name: "MacOSAutoTiler",
            path: "Sources/MacOSAutoTiler"
        )
    ]
)
