// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "BonePageTurnKit",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "BonePageTurnKit",
            targets: ["BonePageTurnKit"]
        )
    ],
    targets: [
        .target(name: "BonePageTurnKit"),
        .testTarget(name: "BonePageTurnKitTests", dependencies: ["BonePageTurnKit"])
    ]
)
