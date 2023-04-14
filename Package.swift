// swift-tools-version: 5.6
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
    dependencies: [],
    targets: [
        .target(
            name: "CloudSyncSession",
            dependencies: []
        ),
        .testTarget(
            name: "CloudSyncSessionTests",
            dependencies: ["CloudSyncSession"]
        ),
    ]
)
