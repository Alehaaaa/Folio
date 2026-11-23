import CoreSpotlight
import SwiftUI
import Observation

/// The iPhone and iPad app shares its library, metadata, account and
/// reading-preference implementations with the desktop target.
@main
struct FolioIOSApp: App {
    @UIApplicationDelegateAdaptor(FolioAppDelegate.self) private var appDelegate
    @State private var shortcuts = FolioShortcutRouter.shared
    @State private var library = LibraryStore.shared
    @State private var hardcover = HardcoverClient.shared
    @State private var preferences = ReaderPrefsStore.shared
    @State private var extensions = ExtensionStore.shared
    @State private var navigation = FolioMobileNavigation()

    init() {
        FolioLog.start()
        FolioTheme.applyAppearance()
    }

    var body: some Scene {
        WindowGroup {
            FolioMobileRootView()
                .tint(FolioTheme.accent)
                .environment(library)
                .environment(hardcover)
                .environment(preferences)
                .environment(extensions)
                .environment(navigation)
                .onOpenURL(perform: handleIncomingURL)
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = FolioSystemIntegration.bookID(from: activity), library.book(id) != nil {
                        navigation.read(id)
                    }
                }
                .onChange(of: shortcuts.pending, initial: true) { _, id in
                    guard let id else { return }
                    shortcuts.pending = nil
                    if library.book(id) != nil { navigation.read(id) }
                }
                .folioUpdatePrompt()
                .folioLogsLifecycle()
                .task {
                    // Restore persisted jobs on every launch, even when Downloads
                    // has never been opened in the current session.
                    _ = DownloadQueue.shared
                    await hardcover.restore()
                    library.enqueueUnlinkedEPUBs()
                    await ReadingReminders.shared.startup()
                    FolioWidgetBridge.publish()
                    FolioSystemIntegration.update(library)
                    await FolioWidgetBridge.refreshHardcover()
                }
        }
    }

    @MainActor
    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            library.importFiles([url])
            return
        }
        guard url.scheme == "folio-reader" else { return }
        let component = url.pathComponents.dropFirst().first
        if url.host() == "read",
           let id = component.flatMap(UUID.init(uuidString:)),
           library.book(id) != nil {
            navigation.read(id)
        } else if url.host() == "library" {
            navigation.selectedTab = .library
        } else if url.host() == "goals" {
            navigation.selectedTab = .home
        }
    }
}

enum FolioMobileTab: Hashable {
    case home
    case library
    case search
    case downloads
    case sources
    case settings
}

enum FolioMobileLibraryScope: String, CaseIterable, Identifiable {
    case books = "My Books", shelves = "My Shelves"
    var id: String { rawValue }
}

enum FolioMobileMoreRoute: Hashable {
    case downloads, sources, settings
}

struct FolioMobileReading: Identifiable {
    let id: UUID
}

@Observable
@MainActor
final class FolioMobileNavigation {
    var selectedTab: FolioMobileTab = .home
    var reading: FolioMobileReading?
    /// A book to open once Home's Reading sheet has closed (a full-screen reader
    /// can't open over a sheet).
    var pendingRead: UUID?
    /// Library shows either the imported books or the Hardcover/Goodreads shelves.
    var libraryScope: FolioMobileLibraryScope = .books
    /// Pages pushed inside the More tab, so Downloads can be opened from anywhere.
    var morePath = NavigationPath()
    /// iPhone layout: Downloads, Sources and Settings live under More.
    var compactTabs = true
    var shelfStatus: HCStatus = .reading

    func openShelf(_ status: HCStatus) {
        shelfStatus = status
        libraryScope = .shelves
        selectedTab = .library
    }

    func read(_ id: UUID) {
        reading = FolioMobileReading(id: id)
    }
}
