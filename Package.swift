// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "oort",
    platforms: [
        .macOS(.v13) // VZEFIBootLoader / Result-based start & connect require macOS 13+
    ],
    targets: [
        .executableTarget(
            name: "oort",
            path: "Sources/oort"
        ),
        .executableTarget(
            name: "oort-gui",
            path: "Sources/oort-gui"
        )
    ]
)
