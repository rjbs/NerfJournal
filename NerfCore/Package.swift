// swift-tools-version: 6.0
import PackageDescription

// The model layer shared by the NerfJournal app and the nerf CLI: civil dates
// and moments, the record types, the schema migrations, and the export format.
// No UI dependency, so the CLI can link it.
let package = Package(
    name: "NerfCore",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "NerfCore", targets: ["NerfCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        .package(path: "../../Jinx"),
    ],
    targets: [
        .target(
            name: "NerfCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "JinxJSON", package: "Jinx"),
                .product(name: "JinxPatch", package: "Jinx"),
                .product(name: "JinxWire", package: "Jinx"),
                .product(name: "JinxStore", package: "Jinx"),
                .product(name: "Jinx", package: "Jinx"),
                .product(name: "JinxTypes", package: "Jinx"),
            ]
        ),
        .testTarget(
            name: "NerfCoreTests",
            dependencies: ["NerfCore", .product(name: "JinxScriptedServer", package: "Jinx")]
        ),
    ]
)
