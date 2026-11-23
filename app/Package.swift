// swift-tools-version:6.0
import PackageDescription

// The Mac app: the shared library, reader and download code in Sources/Folio,
// the same SwiftUI screens as the iPhone and iPad app from iOS/Sources, and
// the Mac glue in Mac/. iOS-only files (their own reader, update checker,
// Downloads and Find Source screens) are left out; the Mac keeps its own.

let excludedFromMac = [
    "FolioMobileReaderView.swift",
    "FolioMobileReaderEngine.swift",
    "FolioMobileAnnotationTools.swift",
    "FolioMobileReadingReferences.swift",
    "FolioMobileUpdates.swift",
    "FolioMobileSystemIntegration.swift",
    "FolioMobileDownloadsView.swift",
    "FolioMobileFindSourceView.swift",
    "MobileXMLCompat.swift",
    "MobileAutomaticEPUBChoice.swift",
    "MobileText.swift",
].map { "iOS/Sources/" + $0 }

let package = Package(
    name: "Folio",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Folio",
            path: ".",
            exclude: excludedFromMac,
            sources: ["Sources/Folio", "iOS/Sources", "Mac"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
