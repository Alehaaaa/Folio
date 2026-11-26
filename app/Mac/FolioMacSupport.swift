import AppKit
import SwiftUI

// The Mac pieces that sit behind the shared iPhone/iPad screens: the macOS
// Find Source picker and Downloads keep their own implementation, books open
// in the macOS reader window, and the iOS-only system hooks become no-ops.

extension Notification.Name {
    /// In-app confirmation that Find Source queued or reused a background job.
    /// `userInfo` contains `title` and `alreadyInProgress`; never changes pages.
    static let folioDownloadEnqueued = Notification.Name("folio.download.enqueued")
    /// Opens a library book's page over the current tab. `object` is its UUID.
    static let folioShowBook = Notification.Name("folio.mac.showBook")
    /// Opens Settings › Extensions in the main window.
    static let folioShowSources = Notification.Name("folio.mac.showSources")
    /// Switches the main window to the Settings tab (Folio > Settings…, ⌘,).
    static let folioShowSettings = Notification.Name("folio.mac.showSettings")
}

/// Used by the macOS Downloads page to show a finished book's page.
@MainActor
enum BookDetailsPresenter {
    static func showLocal(_ id: UUID) {
        NotificationCenter.default.post(name: .folioShowBook, object: id)
    }
}

/// The shared book page asks for this sheet when someone wants to choose a
/// specific copy. On the Mac it is the macOS source picker, which searches the
/// sources and downloads exactly as the Mac app always has.
struct FolioMobileFindSourceView: View {
    let title: String
    let author: String
    let hardcoverBookID: Int?
    let hardcoverPages: Int?
    let cover: URL?
    let failedJobID: UUID?

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                FindCopyPanel(title: title, author: author, hardcoverBookID: hardcoverBookID,
                              hardcoverPages: hardcoverPages, cover: cover, failedJobID: failedJobID)
            }
            .folioScreen()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
        .frame(minWidth: 600, minHeight: 460)
        .onChange(of: library.localCopy(author: author, title: title) != nil) { _, found in
            if found { dismiss() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioShowSources)) { _ in dismiss() }
    }
}

/// A remote cover cut to its frame, with a cloth cover while it loads.
struct FolioMobileRemoteCover: View {
    let url: URL?
    let title: String

    var body: some View {
        GeometryReader { geometry in
            FolioCachedImage(url: url) {
                FolioClothCover(title: title, compact: true)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .accessibilityHidden(true)
    }
}

/// Spotlight and Home Screen quick actions are iPhone and iPad features.
@MainActor
enum FolioSystemIntegration {
    static func update(_ library: LibraryStore) {}
}

/// Settings > About: the Mac build is published as the "macos" GitHub release.
struct FolioUpdateRow: View {
    static let releaseURL = URL(string: "https://github.com/Alehaaaa/Folio/releases/tag/macos")!

    var body: some View {
        Link(destination: Self.releaseURL) {
            LabeledContent("Check for Updates") {
                Image(systemName: "arrow.up.right.square")
            }
        }
    }
}
