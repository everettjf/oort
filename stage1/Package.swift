// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "openorb",
    platforms: [
        .macOS(.v13) // VZEFIBootLoader / Result-based start & connect require macOS 13+
    ],
    targets: [
        .executableTarget(
            name: "openorb",
            path: "Sources/openorb"
        )
    ]
)
