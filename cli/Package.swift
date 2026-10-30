// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "nerf",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../NerfCore"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "nerf",
            dependencies: [
                .product(name: "NerfCore", package: "NerfCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            // Swift 6 mode. Unlike the app, no main-actor default: ArgumentParser
            // runs each command synchronously and nothing here is shared state.
            swiftSettings: [
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
            ]
        ),
    ]
)
