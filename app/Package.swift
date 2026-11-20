// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Folio",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Folio",
            path: "Sources/Folio",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
