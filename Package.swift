// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "zwm",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "zwm-server", targets: ["ZWMApp"]),
        .executable(name: "zwm", targets: ["ZWMCli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.5.5"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "ZWMApp",
            dependencies: ["ZWMServer"]
        ),
        .target(
            name: "ZWMServer",
            dependencies: [
                "ZWMCommon",
                "PrivateApi",
                "TOMLKit",
                .product(name: "OrderedCollections", package: "swift-collections"),
            ]
        ),
        .executableTarget(
            name: "ZWMCli",
            dependencies: ["ZWMCommon"]
        ),
        .target(
            name: "ZWMCommon"
        ),
        .target(
            name: "PrivateApi",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "ZWMServerTests",
            dependencies: ["ZWMServer"]
        ),
    ]
)
