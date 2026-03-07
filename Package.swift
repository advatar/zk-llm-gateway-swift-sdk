// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "zk-llm-gateway-swift-sdk",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "ZKLLMGatewaySDK",
            targets: ["ZKLLMGatewaySDK"]
        ),
    ],
    targets: [
        .target(
            name: "ZKLLMGatewaySDK"
        ),
        .testTarget(
            name: "ZKLLMGatewaySDKTests",
            dependencies: ["ZKLLMGatewaySDK"]
        ),
    ]
)
