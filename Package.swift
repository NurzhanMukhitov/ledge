// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ledge",
    // macOS 15 for Translation.framework, which the translate tab runs on.
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Ledge", targets: ["Ledge"])
    ],
    targets: [
        .executableTarget(
            name: "Ledge",
            path: "Sources/Ledge",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
