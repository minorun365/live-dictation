// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LiveDictation",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "LiveDictation", targets: ["LiveDictation"])
    ],
    targets: [
        .executableTarget(
            name: "LiveDictation",
            path: "Sources/LiveTranslator"
        )
    ]
)
