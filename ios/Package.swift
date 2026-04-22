// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "iPhoneCam",
    platforms: [
        .iOS(.v17),
    ],
    products: [
        .library(
            name: "iPhoneCam",
            targets: ["iPhoneCam"]
        ),
    ],
    targets: [
        .target(
            name: "iPhoneCam",
            path: "Sources/iPhoneCam",
            exclude: ["Info.plist"]   // xtool handles Info.plist via xtool.yml
        ),
    ]
)
