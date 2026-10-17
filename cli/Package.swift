// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nerf",
    platforms: [.macOS("27.0")],
    dependencies: [
        .package(path: "../NerfCore"),
        .package(url: "https://github.com/groue/GRDB.swift", branch: "master"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    ],
    targets: [
        .executableTarget(
            name: "nerf",
            dependencies: [
                .product(name: "NerfCore", package: "NerfCore"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
    ]
)
