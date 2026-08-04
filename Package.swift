// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LiveTranslator",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "LiveTranslator", targets: ["LiveTranslator"])
    ],
    targets: [
        .executableTarget(
            name: "LiveTranslator",
            path: "Sources/LiveTranslator"
        )
    ]
)
