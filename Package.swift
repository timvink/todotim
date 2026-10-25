// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.library(name: "TodoCore", targets: ["TodoCore"])]
var targets: [Target] = [
    .target(name: "TodoCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "TodoCoreTests", dependencies: ["TodoCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
]
// The app needs AppKit; on Linux only TodoCore and its tests build (for a fast test loop).
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
