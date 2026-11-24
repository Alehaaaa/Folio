// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GoodreadsLab",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GoodreadsLab", targets: ["GoodreadsLab"])],
    targets: [
        .executableTarget(
            name: "GoodreadsLab",
            resources: [.copy("GoodreadsBridge.js"), .copy("GoodreadsTrafficProbe.js")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
