// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexQuotaMenu",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "CodexQuotaMenu",
            targets: ["CodexQuotaMenu"]
        )
    ],
    targets: [
        .target(
            name: "CodexQuotaCore",
            path: "Sources/CodexQuotaCore"
        ),
        .executableTarget(
            name: "CodexQuotaMenu",
            dependencies: ["CodexQuotaCore"],
            path: "Sources/CodexQuotaMenu"
        ),
        .testTarget(
            name: "CodexQuotaCoreTests",
            dependencies: ["CodexQuotaCore"],
            path: "Tests/CodexQuotaCoreTests"
        )
    ]
)
