// swift-tools-version:6.0
import PackageDescription
import Foundation

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

/// The target's root is this folder, so everything beside the compiled
/// folders (the iOS project and its build products, local Folio.app builds,
/// checks, the widget, Rust launcher...) is excluded, or SwiftPM would pick up
/// files such as PrivacyInfo.xcprivacy inside them as resources.
func everythingExcept(_ keep: Set<String>, in folder: String) -> [String] {
    let root = URL(fileURLWithPath: Context.packageDirectory).appendingPathComponent(folder)
    let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
    return names.filter { !keep.contains($0) && $0 != "Package.swift" }
        .map { folder.isEmpty ? $0 : folder + "/" + $0 }
}

let notMac = everythingExcept(["Sources", "iOS", "Mac"], in: "")
    + everythingExcept(["Sources"], in: "iOS")
    + excludedFromMac

let package = Package(
    name: "Folio",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Folio",
            path: ".",
            exclude: notMac,
            sources: ["Sources/Folio", "iOS/Sources", "Mac"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
