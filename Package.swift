// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CloudSyncSession",
    platforms: [
        .iOS(.v15),
        .watchOS(.v8),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "CloudSyncSession",
            targets: ["CloudSyncSession"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ryanashcraft/swift-pid.git",
            .upToNextMajor(from: "0.0.1")
        ),
    ],
    targets: [
        .target(
            name: "CloudSyncSession",
            dependencies: [
                .product(name: "PID", package: "swift-pid"),
            ]
        ),
        .testTarget(
            name: "CloudSyncSessionTests",
            dependencies: ["CloudSyncSession"]
        ),
    ]
)
