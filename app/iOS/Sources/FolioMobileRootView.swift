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
            if tabLayout.hasTab(.sources) {
                Tab("Sources", systemImage: "square.stack.3d.up", value: .sources) {
                    NavigationStack {
                        FolioMobileSourcesView()
                            .folioDetailDestinations()
                    }
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
                .folioCreamGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                        case .sources: Label("Sources", systemImage: "square.stack.3d.up")
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
                    case .sources: FolioMobileSourcesView()
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

    func openSources() { open(.sources) }

    func openDownloads() { open(.downloads) }

    /// Opens Downloads, Sources or Settings from anywhere: its own tab when it has
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
        case .downloads, .sources, .settings:
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
    /// destination link (Source Extensions, Sync…) are not in `morePath`, so assigning
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
}

struct FolioMobileHomeView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    let showImporter: () -> Void

    @State private var discovery = FolioMobileHomeRecommendations()
    @State private var shelves = FolioMobileHomeShelves()
    @State private var showingGoals = false
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 118

    /// Refresh only when a meaningful preference changes, rather than every
    /// second of a reading session or every increment of page progress.
    private var discoveryKey: String {
        let library = store.books.map { "\($0.id):\($0.author):\($0.status.rawValue):\($0.hardcoverBookID ?? 0):\($0.lastOpenedAt == nil ? 0 : 1)" }
            .sorted().joined(separator: "|")
        let tracked = store.data.tracked.map { "\($0.id):\($0.author):\($0.rating):\($0.shelf)" }
            .sorted().joined(separator: "|")
        return "\(hardcover.user?.id ?? -1)-\(hardcover.revision)-\(library)-\(tracked)"
    }

    /// The books being read (opened or marked reading in the library, or on a
    /// Currently Reading shelf), each in the place it has kept on the shelf.
    private var nookItems: [FolioNookItem] {
        FolioNookShelf.items(library: store, reading: shelves.reading)
    }

    /// Changes when a book joins or leaves the nook, to give new books a place.
    private func nookKey(_ items: [FolioNookItem]) -> String {
        items.map { $0.id + ($0.coverKey ?? "") }.joined(separator: "|")
            + "#\(FolioNookStore.shared.order.isEmpty)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                heading
                let items = nookItems
                if store.books.isEmpty && items.isEmpty {
                    emptyLibrary
                } else {
                    // The page spans the screen like Library, so rows of covers run to its
                    // edge; the nook keeps the width its shelves were designed for.
                    FolioMobileBookshelf(items: FolioNookStore.shared.arranged(items))
                        .frame(maxWidth: 900, alignment: .leading)
                        .task(id: nookKey(items)) {
                            FolioNookStore.shared.register(items)
                            FolioSpinePalettes.shared.prepare(items)
                        }
                }
                remoteShelfRow("Want to read", entries: shelfEntries(.wantToRead), status: .wantToRead)
                let forYou = FolioReadBooks.shared.unread(discovery.byYourAuthors)
                if !forYou.isEmpty {
                    section("For you") {
                        ForEach(forYou) { book in
                            FolioMobileRemoteBookTile(book: book, width: min(tileWidth, 180))
                        }
                    }
                }
                FolioMobileHighlightOfTheDay()
                FolioMobileBecauseYouReadRow(tileWidth: min(tileWidth, 180))
                FolioMobileAuthorRows()
                FolioMobileSavedSeriesRow()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 36)
        }
        // A book in the hand on the shelf holds the page still.
        .scrollDisabled(FolioNookStore.shared.holding)
        // Books in the rows can be dragged onto the shelf.
        .environment(\.folioNookDragSource, true)
        .refreshable {
            await shelves.load(from: hardcover)
            await discovery.load(from: hardcover, books: store.books, tracked: store.data.tracked)
        }
        .navigationTitle("Folio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .folioScreen()
        .sheet(isPresented: $showingGoals, onDismiss: openPendingBook) {
            NavigationStack {
                FolioMobileReadingActivity()
                    .folioDetailDestinations()
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { showingGoals = false }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onChange(of: navigation.pendingRead) { _, id in
            guard id != nil else { return }
            if showingGoals { showingGoals = false } else { openPendingBook() }
        }
        .task(id: "\(hardcover.user?.id ?? -1)-\(FolioBecauseYouRead.seed(in: store)?.hardcoverBookID ?? 0)") {
            await FolioBecauseYouRead.shared.load(library: store, hardcover: hardcover)
        }
        .task(id: discoveryKey) {
            await discovery.load(from: hardcover, books: store.books, tracked: store.data.tracked)
        }
        .task(id: "\(hardcover.user?.id ?? -1)-\(hardcover.revision)-\(hardcover.progressRevision)") {
            await shelves.load(from: hardcover)
            await FolioReadBooks.shared.refresh(from: hardcover)
        }
    }

    private func openPendingBook() {
        guard let id = navigation.pendingRead else { return }
        navigation.pendingRead = nil
        navigation.read(id)
    }

    /// The Folio wordmark and a single serif line, as on a book's title page.
    private var heading: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 6) {
                Text("folio")
                    .font(.system(size: 46, weight: .regular, design: .serif))
                    .tracking(-2)
                    .foregroundStyle(FolioTheme.ink)
                    .accessibilityLabel("Folio")
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                iconButton("plus", label: "Import books", action: showImporter)
                FolioMobileGoalRingsButton { showingGoals = true }
            }
            Text(store.books.isEmpty ? "A little room for every story." : "A little room for your next chapter.")
                .font(.folioDisplay(.title))
                .foregroundStyle(FolioTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.light))
                .frame(minWidth: 44, minHeight: 44)
        }
        .buttonStyle(.plain)
        .foregroundStyle(FolioTheme.ink)
        .accessibilityLabel(label)
    }

    private var emptyLibrary: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Import an EPUB, PDF, comic or document to start your shelf.")
                .font(.body)
                .foregroundStyle(FolioTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            FolioGlassButton(title: "Import Books", systemImage: "plus", prominent: true, action: showImporter)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .folioCard()
    }

    /// One serif title, an optional "See all", and a horizontal row of covers.
    private func section<Content: View>(_ title: String, seeAll: (() -> Void)? = nil,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.folioDisplay(.title2))
                    .foregroundStyle(FolioTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let seeAll {
                    Button("See all", action: seeAll)
                        .font(.subheadline)
                        .foregroundStyle(FolioTheme.olive)
                        .accessibilityLabel("See all \(title)")
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 20)
            .padding(.horizontal, -20)
        }
    }

    private func shelfEntries(_ status: HCStatus) -> [FolioMobileShelfEntry] {
        let remote = status == .reading ? shelves.reading : shelves.wantToRead
        let tracked = status.goodreadsShelf.map { store.tracked($0) } ?? []
        let read = FolioReadBooks.shared
        let entries = FolioMobileShelfEntry.merge(hardcover: remote, goodreads: tracked).filter { entry in
            !read.isRead(id: entry.hardcover?.book.id ?? entry.goodreads?.hardcoverBookID,
                         title: entry.title, author: entry.author)
        }
        return Array(entries.prefix(15))
    }

    @ViewBuilder
    private func remoteShelfRow(_ title: String, entries: [FolioMobileShelfEntry], status: HCStatus) -> some View {
        if !entries.isEmpty {
            section(title, seeAll: { navigation.openShelf(status) }) {
                ForEach(entries) { entry in
                    if let item = entry.hardcover {
                        FolioMobileRemoteBookTile(book: item.book, width: min(tileWidth, 180), entry: entry) {
                            Task { await shelves.load(from: hardcover) }
                        }
                    } else if let tracked = entry.goodreads {
                        FolioMobileRemoteBookTile(book: tracked.folioBook, width: min(tileWidth, 180), entry: entry)
                    }
                }
            }
        }
    }
}

/// Currently Reading and Want to Read from Hardcover, loaded for the Home screen.
@Observable
@MainActor
final class FolioMobileHomeShelves {
    var reading: [HCUserBook] = []
    var wantToRead: [HCUserBook] = []
    var loading = false
    var error: String?

    func load(from hardcover: HardcoverClient) async {
        guard hardcover.isConnected else {
            reading = []
            wantToRead = []
            error = nil
            return
        }
        let userID = hardcover.user?.id ?? -1
        // Show the last known shelves at once; the network only refreshes them.
        if reading.isEmpty && wantToRead.isEmpty, let cached = FolioMobileHomeCache.shelves(for: userID) {
            reading = cached.reading
            wantToRead = cached.wantToRead
        }
        loading = true
        defer { loading = false }
        do {
            async let current = hardcover.shelf(.reading)
            async let wanted = hardcover.shelf(.wantToRead)
            let (r, w) = try await (current, wanted)
            reading = r
            wantToRead = w
            error = nil
            FolioMobileHomeCache.saveShelves(userID: userID, reading: r, wantToRead: w)
            FolioSync.adopt(r + w)
            FolioSync.pushPending(hardcover: hardcover)
            FolioImageCache.shared.prefetch((r.prefix(15) + w.prefix(15)).compactMap(\.book.imageURL))
        } catch is CancellationError {
            return
        } catch let urlError as URLError where urlError.code == .cancelled {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

struct FolioMobileLibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(FolioMobileNavigation.self) private var navigation
    let showImporter: () -> Void
    @State private var search = ""
    @State private var filter: LibraryFilter = .all
    @State private var collection: UUID?
    @State private var sorting: FolioMobileSort = .recent
    @State private var newCollection = ""
    @State private var addingCollection = false

    private var visibleBooks: [LocalBook] {
        let candidates = collection.map { store.books(in: $0, search: search) }
            ?? store.books(filter, search: search)
        switch sorting {
        case .recent: return candidates.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .title: return candidates.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: return candidates.sorted { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
    }

    private var showingShelves: Bool { navigation.libraryScope == .shelves }

    private var title: String {
        showingShelves ? "Library"
            : collection.flatMap { id in store.data.collections.first { $0.id == id }?.name } ?? "Library"
    }

    var body: some View {
        @Bindable var navigation = navigation
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FolioTabHeader(title: title) {
                    if !showingShelves {
                        Menu {
                            Picker("Sort", selection: $sorting) {
                                ForEach(FolioMobileSort.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            Divider()
                            Button("All Books") { collection = nil }
                            ForEach(store.data.collections) { c in
                                Button(c.name) { collection = c.id }
                            }
                            Button("New Collection", systemImage: "plus") { addingCollection = true }
                        } label: {
                            FolioHeaderIconLabel(symbol: "line.3.horizontal.decrease")
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .foregroundStyle(FolioTheme.ink)
                        .accessibilityLabel("Filter and Sort")
                    }
                    FolioHeaderIcon(symbol: "plus", label: "Import books", action: showImporter)
                }
                .padding(.horizontal, 20)

                FolioSearchField(text: $search, prompt: showingShelves ? "Search your shelves" : "Title or author")
                    .padding(.horizontal, 16)

                Picker("Show", selection: $navigation.libraryScope) {
                    ForEach(FolioMobileLibraryScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .accessibilityIdentifier("folio.libraryScope")

                if showingShelves {
                    FolioMobileShelvesView(search: search)
                } else {
                    booksContent
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .folioScreen()
        .navigationTitle(title)
        .toolbar(.hidden, for: .navigationBar)
        .alert("New Collection", isPresented: $addingCollection) {
            TextField("Collection name", text: $newCollection)
            Button("Cancel", role: .cancel) { newCollection = "" }
            Button("Create") {
                let name = newCollection.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { collection = store.addCollection(name) }
                newCollection = ""
            }
        }
    }

    @ViewBuilder
    private var booksContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { option in
                    Button {
                        filter = option
                        collection = nil
                    } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                    }
                    .folioGlassPill(prominent: collection == nil && filter == option)
                }
            }
            .padding(.horizontal, 16)
        }

        let books = visibleBooks
        if books.isEmpty {
            ContentUnavailableView {
                Label(search.isEmpty ? "No Books Yet" : "No Matches", systemImage: "books.vertical")
            } description: {
                Text(search.isEmpty ? "Import books to start reading." : "Try another title or author.")
            } actions: {
                if search.isEmpty {
                    Button("Import Books", action: showImporter)
                        .folioGlassPill(prominent: true)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 190), spacing: 16, alignment: .top)], alignment: .leading, spacing: 24) {
                ForEach(books) { book in
                    NavigationLink(value: book.id) {
                        FolioMobileBookTile(book: book)
                    }
                    .buttonStyle(.plain)
                    .folioBookContextMenu(book)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

enum FolioMobileSort: String, CaseIterable, Identifiable {
    case recent, title, author
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct FolioMobileBookTile: View {
    @Environment(LibraryStore.self) private var store
    let book: LocalBook

    /// Every tile has the same parts at the same heights: the cover, two lines of title,
    /// the author, and a footer row for the progress bar, so a row of tiles lines up.
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FolioMobileCover(book: book)
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 6, x: 1, y: 4)
            Text(book.title)
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(FolioTheme.ink)
                .lineLimit(2, reservesSpace: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(book.author.isEmpty ? "Unknown Author" : book.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                // A read book shows a plain check by its author, not a full bar.
                if finished {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FolioTheme.olive)
                        .transition(.scale(scale: 0.3).combined(with: .opacity))
                        .accessibilityHidden(true)
                }
            }
            // Marking a book read collapses its bar toward the start and hides it; the
            // empty row stays so the grid keeps its alignment.
            ZStack(alignment: .leading) {
                if !finished, book.progress > 0 {
                    ProgressView(value: min(1, book.progress))
                        .tint(FolioTheme.olive)
                        .transition(.scale(scale: 0.01, anchor: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 4)
        }
        .animation(.spring(duration: 0.45, bounce: 0.15), value: finished)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityValue(finished ? "Finished" : "")
    }

    private var finished: Bool { FolioReadBooks.shared.isRead(book) }
}

struct FolioMobileCover: View {
    @Environment(LibraryStore.self) private var store
    let book: LocalBook
    /// The cover read in the background, with the file it came from.
    @State private var loaded: (file: URL, image: UIImage)?

    var body: some View {
        let file = store.coverURL(book)
        // Only memory here: reading and decoding the file while building the view
        // stalled every scroll that brought new covers on screen.
        let image = file.flatMap { file in
            FolioImageCache.shared.localCoverInMemory(file) ?? (loaded?.file == file ? loaded?.image : nil)
        }
        GeometryReader { geometry in
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .clipped()
            } else {
                FolioClothCover(title: book.title,
                                subtitle: book.author.isEmpty ? nil : book.author,
                                systemImage: book.format.symbol,
                                compact: geometry.size.width < 90)
            }
        }
        .background(FolioTheme.sage)
        .task(id: file) {
            guard let file else { return }
            if let image = await FolioImageCache.shared.loadLocalCover(file) { loaded = (file, image) }
        }
    }
}
