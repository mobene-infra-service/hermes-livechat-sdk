// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HermesLiveChat",
    platforms: [
        .iOS(.v13),
    ],
    products: [
        .library(name: "HermesLiveChat", targets: ["HermesLiveChat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/centrifugal/centrifuge-swift.git", from: "0.8.2"),
    ],
    targets: [
        .target(
            name: "HermesLiveChat",
            dependencies: [
                .product(name: "SwiftCentrifuge", package: "centrifuge-swift"),
            ]
        ),
    ]
)
