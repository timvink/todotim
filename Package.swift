// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [
    .library(name: "TodoCore", targets: ["TodoCore"]),
    // The engine behind the Omarchy (Linux) app; builds on macOS too, for tests.
    .executable(name: "todotim-engine", targets: ["todotim-engine"]),
]
var targets: [Target] = [
    .target(name: "TodoCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "TodoTimEngine", dependencies: ["TodoCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .executableTarget(name: "todotim-engine", dependencies: ["TodoTimEngine"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "TodoCoreTests", dependencies: ["TodoCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "TodoTimEngineTests", dependencies: ["TodoTimEngine", "TodoCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
]
// The Mac app needs AppKit; on Linux only TodoCore, the engine and their tests build.
#if !os(Linux)
products.insert(.executable(name: "TodoTim", targets: ["TodoTim"]), at: 0)
targets.insert(.executableTarget(name: "TodoTim", dependencies: ["TodoCore"], swiftSettings: [.swiftLanguageMode(.v5)]), at: 1)
#endif

let package = Package(
    name: "TodoTim",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets
)
