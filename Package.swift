// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ConCopy",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ConCopyApp", targets: ["ConCopyApp"]),
        .library(name: "ConCopyCore", targets: ["ConCopyCore"]),
        .library(name: "ConCopyUI", targets: ["ConCopyUI"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.24.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "1.11.0")
    ],
    targets: [
        .target(
            name: "ConCopyCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/ConCopyCore"
        ),
        .target(
            name: "ConCopyUI",
            dependencies: [
                "ConCopyCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")
            ],
            path: "Sources/ConCopyUI"
        ),
        .executableTarget(
            name: "ConCopyApp",
            dependencies: [
                "ConCopyCore",
                "ConCopyUI"
            ],
            path: "Sources/ConCopyApp",
            exclude: ["Info.plist"]
        ),
        .testTarget(
            name: "ConCopyCoreTests",
            dependencies: [
                "ConCopyCore"
            ],
            path: "Tests/ConCopyCoreTests"
        )
    ]
)
