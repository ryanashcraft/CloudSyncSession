// swift-tools-version: 6.0
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
        // The sync engine without a backend. CloudSyncSession is this plus CloudKit.
        .library(
            name: "SyncSessionCore",
            targets: ["SyncSessionCore"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ryanashcraft/swift-pid.git",
            .upToNextMajor(from: "0.0.1")
        ),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.4"),
    ],
    targets: [
        .target(
            name: "SyncSessionCore",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .target(
            name: "CloudSyncSession",
            dependencies: [
                "SyncSessionCore",
                .product(name: "PID", package: "swift-pid"),
                .product(name: "Logging", package: "swift-log"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .enableUpcomingFeature("StrictConcurrency"),
            ]
        ),
        .testTarget(
            name: "SyncSessionCoreTests",
            dependencies: ["SyncSessionCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "CloudSyncSessionTests",
            dependencies: ["CloudSyncSession", "SyncSessionCore"],
            swiftSettings: [
                .swiftLanguageMode(.v5),
            ]
        ),
    ]
)
