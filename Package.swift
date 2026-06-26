// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "AutoAFK",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "AutoAFK",
            path: "Sources/AutoAFK"
        )
    ]
)
