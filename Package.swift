// swift-tools-version: 5.9
import PackageDescription

// GRDB 7 supports Swift 6 concurrency and avoids the deprecated manifest in GRDB 6.
// Keep the Swift 5.9 toolchain supported for existing Xcode 15 builds.
#if compiler(>=6.0)
let grdbDependency: Package.Dependency = .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.5.0")
#else
let grdbDependency: Package.Dependency = .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3")
#endif

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
        grdbDependency,
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
                "ConCopyCore",
                "ConCopyUI"
            ],
            path: "Tests/ConCopyCoreTests"
        )
    ]
)
