// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TinyCloudMusic",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TinyCloudMusic", targets: ["TinyCloudMusic"])
    ],
    dependencies: [
        .package(url: "https://github.com/kean/Nuke.git", exact: "13.0.6")
    ],
    targets: [
        .executableTarget(
            name: "TinyCloudMusic",
            dependencies: [
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "NukeUI", package: "Nuke")
            ]
        ),
        .testTarget(
            name: "TinyCloudMusicTests",
            dependencies: ["TinyCloudMusic"],
            resources: [.process("Fixtures")]
        )
    ],
    swiftLanguageModes: [.v6]
)
