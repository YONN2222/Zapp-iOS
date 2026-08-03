// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Zapp-iOS",
    defaultLocalization: "en",
    platforms: [
        .iOS(.v18)
    ],
    products: [
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "Zapp",
            path: "Zapp",
            resources: [
                .process("Resources"),
                .process("Assets.xcassets")
            ]
        )
    ]
)
