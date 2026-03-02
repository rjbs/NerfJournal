// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "add-nerf-todo",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", branch: "master"),
    ],
    targets: [
        .executableTarget(
            name: "add-nerf-todo",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        )
    ]
)
