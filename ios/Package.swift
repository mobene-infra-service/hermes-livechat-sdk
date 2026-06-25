// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "HermesLiveChat",
    platforms: [
        // 升到 iOS 15：swift-markdown 自渲染 + 现代 UIKit API；已确认不需向下兼容。
        .iOS(.v15),
    ],
    products: [
        .library(name: "HermesLiveChat", targets: ["HermesLiveChat"]),
    ],
    dependencies: [
        .package(url: "https://github.com/centrifugal/centrifuge-swift.git", from: "0.8.2"),
        // Apple 官方 Markdown 解析库（cmark-gfm），仅解析产出 AST，无 UIKit 依赖。
        // 仅发布 DEVELOPMENT-SNAPSHOT tag，按惯例锁 main 分支跟随工具链。
        .package(url: "https://github.com/swiftlang/swift-markdown.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "HermesLiveChat",
            dependencies: [
                .product(name: "SwiftCentrifuge", package: "centrifuge-swift"),
                .product(name: "Markdown", package: "swift-markdown"),
            ]
        ),
        .testTarget(
            name: "HermesLiveChatTests",
            dependencies: ["HermesLiveChat"]
        ),
    ]
)
