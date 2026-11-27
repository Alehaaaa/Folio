import CoreSpotlight
import SwiftUI
import Observation

#if os(iOS)
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
    @Environment(\.scenePhase) private var scenePhase

    init() {
        FolioLog.start()
        FolioEncryptedDNS.shared.start()
        DownloadQueue.networkNote = { FolioEncryptedDNS.shared.logNote }
        FolioTheme.applyAppearance()
        FolioShelfSync.install()
    }

    var body: some Scene {
        WindowGroup {
            FolioMobileRootView()
                .folioCoverPeekHost()
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
                .folioCloudSync()
                // Coming back from the background, reconnect to Hardcover before a page asks.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { hardcover.warmUp() }
                }
                .task {
                    await extensions.checkForExtensionUpdates()
                    // Restore persisted jobs on every launch, even when Downloads
                    // has never been opened in the current session.
                    _ = DownloadQueue.shared
                    // Testing aid: FOLIO_IMPORT_DIR imports a folder of books on launch.
                    if let dir = ProcessInfo.processInfo.environment["FOLIO_IMPORT_DIR"],
                       let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
                        library.importFiles(names.map { URL(fileURLWithPath: dir).appendingPathComponent($0) })
                    }
                    await hardcover.restore()
                    FolioShelfSync.shared.pushPending(library: library)
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
#endif

enum FolioMobileTab: Hashable {
    case home
    case library
    case search
    case downloads
    case settings
    case more
}

/// Which pages get their own tab and which share More. It follows the width the
/// window actually has, not the device. Source extensions live inside Settings,
/// so a normal window fits every page as a tab.
enum FolioMobileTabLayout: Equatable {
    /// Home, Library, More (Downloads, Settings), Discover.
    case compact
    /// Home, Library, Downloads, Settings, Discover. No More tab.
    case full

    /// UIKit's own limit: a tab bar shows at most five tabs (Discover included) on
    /// every iPhone, in either orientation, and in a compact iPad window. A sixth tab
    /// makes UIKit fold the last ones, Discover too, into its own More list.
    static let maxTabs = 5

    /// Narrower than this (iPhone mini Display Zoom, iPad Slide Over), four tabs and
    /// Discover crowd the bar, so Downloads and Settings share More.
    static let fullWidth: CGFloat = 360

    init(width: CGFloat, regular: Bool, phone: Bool) {
        self = width > 0 && width < Self.fullWidth ? .compact : .full
    }

    /// The pages listed under More, in order. Empty means no More tab.
    var moreRoutes: [FolioMobileMoreRoute] {
        switch self {
        case .compact: [.downloads, .settings]
        case .full: []
        }
    }

    func hasTab(_ route: FolioMobileMoreRoute) -> Bool { !moreRoutes.contains(route) }
}

enum FolioMobileLibraryScope: String, CaseIterable, Identifiable {
    case books = "My Books", shelves = "My Shelves"
    var id: String { rawValue }
}

enum FolioMobileMoreRoute: Hashable, CaseIterable {
    case downloads, settings

    /// The tab this page has when it is not folded into More.
    var tab: FolioMobileTab {
        switch self {
        case .downloads: .downloads
        case .settings: .settings
        }
    }
}

struct FolioMobileReading: Identifiable {
    let id: UUID
}

@Observable
@MainActor
final class FolioMobileNavigation {
    /// Navigating to a top-level section starts it at its root rather than
    /// retaining a nested Settings/Library/Discover screen from a previous tab.
    /// This also covers programmatic routes and reselecting the current tab.
    /// Tapping the tab you are already on lands here too (the tab bar writes
    /// the same value again), and, as in Apple's own apps, closes whatever
    /// page is open in it: Settings, Downloads, a book page...
    var selectedTab: FolioMobileTab = .home {
        didSet {
            navigationRootID = UUID()
            morePath = NavigationPath()
        }
    }
    var navigationRootID = UUID()
    var reading: FolioMobileReading?
    /// A book to open once Home's Reading sheet has closed (a full-screen reader
    /// can't open over a sheet).
    var pendingRead: UUID?
    /// Library shows either the imported books or the Hardcover/Goodreads shelves.
    var libraryScope: FolioMobileLibraryScope = .books
    /// Pages pushed inside the More tab, so Downloads can be opened from anywhere.
    var morePath = NavigationPath()
    /// Which pages have their own tab right now; the rest are under More.
    var tabLayout: FolioMobileTabLayout = .compact
    /// The last page opened under More, so it can move to its own tab on resize.
    var moreRoute: FolioMobileMoreRoute?
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
