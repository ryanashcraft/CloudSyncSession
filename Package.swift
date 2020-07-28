// swift-tools-version:5.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "CloudSyncSession",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
    ],
    products: [
        // Products define the executables and libraries a package produces, and make them visible to other packages.
        .library(
            name: "CloudSyncSession",
            targets: ["CloudSyncSession"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        .package(url: "https://github.com/jayhickey/Cirrus.git", from: "0.1.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages this package depends on.
        .target(
            name: "CloudSyncSession",
            dependencies: [
                .product(name: "CloudKitCodable", package: "Cirrus")
            ]
        ),
        .testTarget(
            name: "CloudSyncSessionTests",
            dependencies: ["CloudSyncSession"]
        ),
    ]
)