// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TodoTim",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TodoTim", targets: ["TodoTim"]),
        .library(name: "TodoCore", targets: ["TodoCore"]),
    ],
    targets: [
        .target(name: "TodoCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "TodoTim", dependencies: ["TodoCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "TodoCoreTests", dependencies: ["TodoCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
