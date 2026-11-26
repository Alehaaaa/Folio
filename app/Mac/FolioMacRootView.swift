import SwiftUI
import UniformTypeIdentifiers

/// The Mac window shows the same tabs and screens as Folio on iPad: Home with
/// the nook, Library, Discover, Downloads and Settings, as a sidebar. Downloads
/// is the macOS Downloads page, and books open in the macOS reader window.
struct FolioMacRootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @AppStorage("folioIOS.onboardingCompleted") private var onboardingCompleted = false
    @State private var importing = false
    @State private var showingOnboarding = false
    @State private var importAfterOnboarding = false
    @State private var downloadToast: DownloadToast?
    @State private var shownBook: FolioMobileReading?
    @State private var showingExtensions = false

    /// A short, actionable handoff: the person decides when to leave the current page.
    private struct DownloadToast: Identifiable {
        enum Kind { case queued, ready, failed }
        let id = UUID()
        let title: String
        let kind: Kind
        var bookID: UUID?
        var jobID: UUID?
    }

    var body: some View {
        lifecycle(events(presentations(tabs)))
    }

    private static let sidebarTabs: [(FolioMobileTab, String, String)] = [
        (.home, "Home", "house"),
        (.library, "Library", "books.vertical"),
        (.search, "Discover", "magnifyingglass"),
        (.downloads, "Downloads", "arrow.down.circle"),
        (.settings, "Settings", "gearshape"),
    ]

    /// A native split view: the sidebar is the system's floating Liquid Glass
    /// panel, and each page's background extends under it.
    @ViewBuilder
    private var tabs: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            // Rows draw their own selection in the nook's olive, not the
            // system blue the Mac would otherwise use.
            List {
                ForEach(Self.sidebarTabs, id: \.0) { tab, title, symbol in
                    let selected = navigation.selectedTab == tab
                    Button { navigation.selectedTab = tab } label: {
                        Label {
                            Text(title).foregroundStyle(FolioTheme.ink)
                        } icon: {
                            Image(systemName: selected && symbol != "magnifyingglass" ? symbol + ".fill" : symbol)
                                .foregroundStyle(FolioTheme.olive)
                        }
                        .font(.body.weight(selected ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                        .padding(.horizontal, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background {
                        if selected {
                            Capsule().fill(FolioTheme.olive.opacity(0.22))
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            NavigationStack {
                page(navigation.selectedTab)
                    .environment(\.folioTabRoot, true)
                    .folioDetailDestinations()
            }
            // Each sidebar visit gets a fresh navigation stack. Without this,
            // macOS can keep a pushed Settings submenu visible after switching
            // to another sidebar section and back.
            .id(navigation.navigationRootID)
        }
        // Each screen draws its own title row, so the window toolbar only
        // carries the window buttons and floats clear over the content.
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Settings and other Forms use the grouped Mac style, like System Settings,
        // instead of the two-column default that misaligns the shared rows.
        .formStyle(.grouped)
        .onAppear {
            // The sidebar lists every page, so nothing goes under More.
            navigation.tabLayout = .full
            // Testing aid: screenshot runs can open a tab with FOLIO_SHOT_TAB.
            if ScreenshotMode.path != nil {
                switch ProcessInfo.processInfo.environment["FOLIO_SHOT_TAB"] {
                case "library": navigation.selectedTab = .library
                case "search": navigation.selectedTab = .search
                case "downloads": navigation.selectedTab = .downloads
                case "settings": navigation.selectedTab = .settings
                default: break
                }
            }
        }
        .onChange(of: navigation.reading?.id) { _, id in
            // The shared screens ask to read a book; on the Mac that is the reader window.
            guard let id else { return }
            navigation.reading = nil
            openWindow(id: "reader", value: id)
        }
    }

    @ViewBuilder
    private func page(_ tab: FolioMobileTab) -> some View {
        switch tab {
        case .home: FolioMobileHomeView(showImporter: { importing = true })
        case .library: FolioMobileLibraryView(showImporter: { importing = true })
        case .search: FolioMobileDiscoverView()
        case .downloads: DownloadingView().folioScreen()
        case .settings, .more: FolioMobileSettingsView(showImporter: { importing = true })
        }
    }

    private func presentations(_ content: some View) -> some View {
        content
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: BookFormat.importTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): store.importFiles(urls)
            case .failure(let error): store.lastError = error.localizedDescription
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let books = urls.filter { BookFormat.from(url: $0) != nil }
            store.importFiles(books)
            return !books.isEmpty
        }
        .sheet(item: $shownBook) { route in
            NavigationStack {
                FolioMobileBookDetail(bookID: route.id)
                    .folioDetailDestinations()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { shownBook = nil } }
                    }
            }
            .frame(minWidth: 720, minHeight: 640)
        }
        .sheet(isPresented: $showingExtensions) {
            NavigationStack {
                FolioMobileExtensionSettings()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { showingExtensions = false } }
                    }
            }
            .frame(minWidth: 620, minHeight: 560)
        }
        .sheet(isPresented: $showingOnboarding, onDismiss: {
            onboardingCompleted = true
            if importAfterOnboarding {
                importAfterOnboarding = false
                importing = true
            }
        }) {
            FolioMobileOnboardingView(
                finished: {
                    onboardingCompleted = true
                    showingOnboarding = false
                },
                importBooks: {
                    importAfterOnboarding = true
                    showingOnboarding = false
                }
            )
            .frame(width: 520, height: 640)
        }
        .alert("Import Failed", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .overlay(alignment: .top) { toast }
        .overlay { PopupHost() }
    }

    private func events(_ content: some View) -> some View {
        content
        .onReceive(NotificationCenter.default.publisher(for: .folioImport)) { _ in importing = true }
        .onReceive(NotificationCenter.default.publisher(for: .folioShowSources)) { _ in
            PopupCenter.shared.close()
            navigation.selectedTab = .settings
            showingExtensions = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioShowSettings)) { _ in
            navigation.selectedTab = .settings
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioShowBook)) { event in
            if let id = event.object as? UUID, store.book(id) != nil { shownBook = FolioMobileReading(id: id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: FolioMobileDownloadNotice.name)) { event in
            queuedToast(event)
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioDownloadEnqueued)) { event in
            queuedToast(event)
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioDownloadReady)) { event in
            let title = (event.userInfo?["title"] as? String) ?? "Book"
            withAnimation(.easeInOut(duration: 0.2)) {
                downloadToast = DownloadToast(title: title, kind: .ready,
                                              bookID: event.userInfo?["bookID"] as? UUID,
                                              jobID: event.userInfo?["jobID"] as? UUID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioDownloadFailed)) { event in
            let title = (event.userInfo?["title"] as? String) ?? "Book"
            withAnimation(.easeInOut(duration: 0.2)) {
                downloadToast = DownloadToast(title: title, kind: .failed,
                                              jobID: event.userInfo?["jobID"] as? UUID)
            }
        }
    }

    private func lifecycle(_ content: some View) -> some View {
        content
        .onOpenURL(perform: handleIncomingURL)
        .onChange(of: hardcover.revision) { _, _ in
            Task { await FolioWidgetBridge.refreshHardcover() }
        }
        .task(id: downloadToast?.id) {
            guard downloadToast != nil else { return }
            try? await Task.sleep(for: .seconds(downloadToast?.kind == .ready ? 12 : 7))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) { downloadToast = nil }
            }
        }
        .task {
            if !onboardingCompleted && ScreenshotMode.path == nil { showingOnboarding = true }
        }
        .onChange(of: onboardingCompleted) { _, completed in
            if !completed && !showingOnboarding { showingOnboarding = true }
        }
    }

    private func queuedToast(_ event: Notification) {
        let title = (event.userInfo?["title"] as? String) ?? "Book"
        let already = (event.userInfo?["alreadyInProgress"] as? Bool) ?? false
        withAnimation(.easeInOut(duration: 0.2)) {
            downloadToast = DownloadToast(title: already ? "\(title) · already in progress" : title, kind: .queued)
        }
    }

    @ViewBuilder
    private var toast: some View {
        if let downloadToast {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: downloadToast.kind == .ready ? "checkmark.circle.fill" :
                                      downloadToast.kind == .failed ? "exclamationmark.triangle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(downloadToast.kind == .ready ? FolioTheme.success :
                                         downloadToast.kind == .failed ? FolioTheme.caution : FolioTheme.olive)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(downloadToast.kind == .ready ? "Ready to read" :
                             downloadToast.kind == .failed ? "Download needs attention" : "Added to Downloads")
                            .font(.subheadline.weight(.semibold))
                        Text(downloadToast.title)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button { self.downloadToast = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss download notice")
                }
                HStack(spacing: 10) {
                    if downloadToast.kind == .ready,
                       let bookID = downloadToast.bookID, store.book(bookID) != nil {
                        Button("Read Now") {
                            openWindow(id: "reader", value: bookID)
                            self.downloadToast = nil
                        }
                        .folioGlassPill(prominent: true)
                    } else if downloadToast.kind == .failed, let jobID = downloadToast.jobID {
                        Button("Retry") {
                            DownloadQueue.shared.retry(jobID)
                            self.downloadToast = nil
                        }
                        .folioGlassPill(prominent: true)
                    }
                    Button("View Downloads") {
                        navigation.selectedTab = .downloads
                        self.downloadToast = nil
                    }
                    .folioGlassPill()
                }
                .font(.caption.weight(.semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: 420)
            .folioCreamGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.top, 10)
            .accessibilityIdentifier("folio.downloadToast")
            .transition(.move(edge: .top).combined(with: .opacity))
        } else if store.importing > 0 {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Importing books…").font(.subheadline)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .folioCreamGlass(in: Capsule())
            .padding(.top, 10)
            .accessibilityIdentifier("folio.importing")
        }
    }

    @MainActor
    private func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            store.importFiles([url])
            return
        }
        guard url.scheme == "folio-reader" else { return }
        let component = url.pathComponents.dropFirst().first
        switch url.host() {
        case "read":
            if let id = component.flatMap(UUID.init(uuidString:)), store.book(id) != nil {
                openWindow(id: "reader", value: id)
            }
        case "library", "collection": navigation.selectedTab = .library
        case "shelf":
            if let raw = component.flatMap(Int.init), let status = HCStatus(rawValue: raw) {
                navigation.openShelf(status)
            } else {
                navigation.selectedTab = .library
            }
        case "downloads": navigation.selectedTab = .downloads
        case "goals": navigation.selectedTab = .home
        default: break
        }
    }
}
