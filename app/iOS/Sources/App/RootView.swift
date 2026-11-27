import SwiftUI
import UniformTypeIdentifiers

#if os(iOS)
struct FolioMobileRootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(FolioMobileNavigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("folioIOS.onboardingCompleted") private var onboardingCompleted = false
    @State private var importing = false
    @State private var showingOnboarding = false
    @State private var importAfterOnboarding = false
    @State private var downloadToast: DownloadToast?
    @State private var windowWidth: CGFloat = 0

    private var tabLayout: FolioMobileTabLayout {
        FolioMobileTabLayout(width: windowWidth, regular: sizeClass == .regular,
                             phone: UIDevice.current.userInterfaceIdiom == .phone)
    }

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
        @Bindable var navigation = navigation
        TabView(selection: $navigation.selectedTab) {
            Tab("Home", systemImage: "house.fill", value: .home) {
                NavigationStack {
                    FolioMobileHomeView(showImporter: { importing = true })
                        .folioDetailDestinations()
                }
                .id(navigation.navigationRootID)
            }
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                NavigationStack {
                    FolioMobileLibraryView(showImporter: { importing = true })
                        .folioDetailDestinations()
                }
                .id(navigation.navigationRootID)
            }
            // Pages get their own tab when the window is wide enough, and fold into
            // More only when the bar would not fit them (see FolioMobileTabLayout).
            if tabLayout.hasTab(.downloads) {
                Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                    NavigationStack { FolioMobileDownloadsView() }
                        .id(navigation.navigationRootID)
                }
            }
            if tabLayout.hasTab(.settings) {
                Tab("Settings", systemImage: "gearshape", value: .settings) {
                    NavigationStack {
                        FolioMobileSettingsView(showImporter: { importing = true })
                            .folioDetailDestinations()
                    }
                    .id(navigation.navigationRootID)
                }
            }
            if !tabLayout.moreRoutes.isEmpty {
                Tab("More", systemImage: "ellipsis.circle", value: .more) {
                    moreTab(routes: tabLayout.moreRoutes)
                }
            }
            // The search role sets Discover apart, at the trailing end of the tab bar.
            Tab("Discover", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack {
                    FolioMobileDiscoverView()
                        .folioDetailDestinations()
                }
                .id(navigation.navigationRootID)
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
        .onChange(of: tabLayout, initial: true) { _, layout in navigation.apply(layout) }
        .onChange(of: navigation.selectedTab) { _, tab in
            FolioLog.log("Tab \(tab), memory \(FolioLog.footprintMB()) MB", "nav")
        }
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
        .fullScreenCover(item: $navigation.reading) { route in
            NavigationStack { FolioMobileReaderView(bookID: route.id) }
                .folioSyncReader(route.id)
                .environment(store)
                // The reader has its own themes; keep the app palette out of it.
                .tint(Color.accentColor)
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
        }
        .alert("Import Failed", isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button("OK") { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .overlay(alignment: .top) {
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
                                .foregroundStyle(FolioTheme.muted)
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
                                navigation.read(bookID)
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
                            navigation.openDownloads()
                            self.downloadToast = nil
                        }
                        .folioGlassPill()
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .folioCreamGlass(in: RoundedRectangle(cornerRadius: FolioTheme.panelRadius, style: .continuous))
                .padding(.horizontal, 14)
                .padding(.top, 6)
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
                .padding(.top, 6)
                .accessibilityIdentifier("folio.importing")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: FolioMobileDownloadNotice.name)) { event in
            let title = (event.userInfo?["title"] as? String) ?? "Book"
            let already = (event.userInfo?["alreadyInProgress"] as? Bool) ?? false
            withAnimation(.easeInOut(duration: 0.2)) {
                downloadToast = DownloadToast(title: already ? "\(title) · already in progress" : title, kind: .queued)
            }
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
        .task(id: downloadToast?.id) {
            guard downloadToast != nil else { return }
            try? await Task.sleep(for: .seconds(downloadToast?.kind == .ready ? 12 : 7))
            if !Task.isCancelled {
                withAnimation(.easeOut(duration: 0.2)) { downloadToast = nil }
            }
        }
        .task {
            if !onboardingCompleted { showingOnboarding = true }
        }
        .onChange(of: onboardingCompleted) { _, completed in
            if !completed && !showingOnboarding { showingOnboarding = true }
        }
    }

    private func moreTab(routes: [FolioMobileMoreRoute]) -> some View {
        @Bindable var navigation = navigation
        return NavigationStack(path: $navigation.morePath) {
            List {
                ForEach(routes, id: \.self) { route in
                    NavigationLink(value: route) {
                        switch route {
                        case .downloads: Label("Downloads", systemImage: "arrow.down.circle")
                        case .settings: Label("Settings", systemImage: "gearshape")
                        }
                    }
                    .folioRow()
                }
            }
            .navigationTitle("More")
            // The same header as Settings and the other tabs, at the screen margin.
            .folioPageHeader("More")
            .folioScreen()
            .folioDetailDestinations()
            .navigationDestination(for: FolioMobileMoreRoute.self) { route in
                Group {
                    switch route {
                    case .downloads: FolioMobileDownloadsView()
                    case .settings: FolioMobileSettingsView(showImporter: { importing = true })
                    }
                }
                .onAppear { navigation.moreRoute = route }
            }
        }
        .id(navigation.navigationRootID)
    }
}
#endif

extension FolioMobileNavigation {
    func openSettings() { open(.settings) }

    func openDownloads() { open(.downloads) }

    /// Opens Downloads or Settings from anywhere: its own tab when it has
    /// one, otherwise its page under More.
    func open(_ route: FolioMobileMoreRoute) {
        if tabLayout.hasTab(route) {
            selectedTab = route.tab
        } else {
            showInMore(route)
        }
    }

    /// Keeps the open page when the window is resized (Split View, Stage Manager,
    /// rotation) and the tabs change: a page that loses its tab opens under More,
    /// and a page under More that gains a tab moves to it.
    func apply(_ layout: FolioMobileTabLayout) {
        let old = tabLayout
        guard layout != old else { return }
        tabLayout = layout
        switch selectedTab {
        case .downloads, .settings:
            if let route = FolioMobileMoreRoute.allCases.first(where: { $0.tab == selectedTab }),
               !layout.hasTab(route) {
                showInMore(route)
            }
        case .more:
            if let route = morePath.isEmpty ? nil : moreRoute, layout.hasTab(route) {
                selectedTab = route.tab
            } else if layout.moreRoutes.isEmpty {
                selectedTab = .settings
            }
        default: break
        }
    }

    /// Opens a page of the More tab from anywhere. Pages that Settings pushes with a
    /// destination link (Extensions, Sync…) are not in `morePath`, so assigning
    /// the same path left them on screen. Popping to the root first and pushing on the
    /// next turn always lands on the requested page.
    private func showInMore(_ route: FolioMobileMoreRoute) {
        selectedTab = .more
        morePath = NavigationPath()
        moreRoute = route
        Task { @MainActor in self.morePath.append(route) }
    }
}

/// In-app confirmation only. Adding a background job never changes tabs.
enum FolioMobileDownloadNotice {
    static let name = Notification.Name("folio.mobile.download.enqueued")

    @MainActor
    static func enqueue(title: String, author: String, hardcoverBookID: Int? = nil,
                        hardcoverPages: Int? = nil, cover: URL? = nil, language: String? = nil,
                        editionTitle: String? = nil) {
        let queue = DownloadQueue.shared
        let before = Set(queue.jobs.filter { $0.stage.isActive }.map(\.id))
        let id = queue.enqueue(title: title, author: author,
                               hardcoverBookID: hardcoverBookID, hardcoverPages: hardcoverPages,
                               cover: cover, expectedLanguage: language, editionTitle: editionTitle)
        NotificationCenter.default.post(name: name, object: nil, userInfo: [
            "title": title, "alreadyInProgress": before.contains(id)
        ])
    }

    @MainActor
    static func enqueueSourceCopy(_ copy: ExtensionStore.Copy, cover: URL?, fallbackAuthor: String,
                                  hardcoverBookID: Int?, hardcoverPages: Int?, replacing failedJobID: UUID?) {
        let queue = DownloadQueue.shared
        let active = Set(queue.jobs.filter { $0.stage.isActive }.map(\.id))
        let id = queue.enqueueSourceCopy(copy, cover: cover, fallbackAuthor: fallbackAuthor,
                                         hardcoverBookID: hardcoverBookID, hardcoverPages: hardcoverPages,
                                         replacing: failedJobID)
        NotificationCenter.default.post(name: name, object: nil, userInfo: [
            "title": copy.result.title, "alreadyInProgress": active.contains(id)
        ])
    }
}
