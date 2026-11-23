import SwiftUI
import UniformTypeIdentifiers

struct FolioMobileRootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(FolioMobileNavigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("folioIOS.onboardingCompleted") private var onboardingCompleted = false
    @State private var importing = false
    @State private var showingOnboarding = false
    @State private var importAfterOnboarding = false
    @State private var downloadToast: DownloadToast?

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
            }
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                NavigationStack {
                    FolioMobileLibraryView(showImporter: { importing = true })
                        .folioDetailDestinations()
                }
            }
            if sizeClass == .compact {
                Tab("More", systemImage: "ellipsis.circle", value: .settings) {
                    NavigationStack(path: $navigation.morePath) {
                        List {
                            Group {
                                NavigationLink(value: FolioMobileMoreRoute.downloads) {
                                    Label("Downloads", systemImage: "arrow.down.circle")
                                }
                                NavigationLink(value: FolioMobileMoreRoute.sources) {
                                    Label("Sources", systemImage: "square.stack.3d.up")
                                }
                                NavigationLink(value: FolioMobileMoreRoute.settings) {
                                    Label("Settings", systemImage: "gearshape")
                                }
                            }
                            .folioRow()
                        }
                        .navigationTitle("More")
                        .folioScreen()
                        .folioDetailDestinations()
                        .navigationDestination(for: FolioMobileMoreRoute.self) { route in
                            switch route {
                            case .downloads: FolioMobileDownloadsView()
                            case .sources: FolioMobileSourcesView()
                            case .settings: FolioMobileSettingsView(showImporter: { importing = true })
                            }
                        }
                    }
                }
            } else {
                Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                    NavigationStack { FolioMobileDownloadsView() }
                }
                Tab("Sources", systemImage: "square.stack.3d.up", value: .sources) {
                    NavigationStack { FolioMobileSourcesView() }
                }
                Tab("Settings", systemImage: "gearshape", value: .settings) {
                    NavigationStack { FolioMobileSettingsView(showImporter: { importing = true }) }
                }
            }
            // The search role sets Discover apart, at the trailing end of the tab bar.
            Tab("Discover", systemImage: "magnifyingglass", value: .search, role: .search) {
                NavigationStack {
                    FolioMobileDiscoverView()
                        .folioDetailDestinations()
                }
            }
        }
        .onAppear { navigation.compactTabs = sizeClass == .compact }
        .onChange(of: navigation.selectedTab) { _, tab in
            FolioLog.log("Tab \(tab), memory \(FolioLog.footprintMB()) MB", "nav")
        }
        .onChange(of: sizeClass) { _, value in
            navigation.compactTabs = value == .compact
            // iPad Split View can drop the Downloads and Sources tabs: show them under More.
            if value == .compact {
                switch navigation.selectedTab {
                case .downloads: navigation.openDownloads()
                case .sources:
                    navigation.selectedTab = .settings
                    navigation.morePath = NavigationPath([FolioMobileMoreRoute.sources])
                default: break
                }
            }
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
}

extension FolioMobileNavigation {
    func openSettings() {
        selectedTab = .settings
        if compactTabs { morePath = NavigationPath([FolioMobileMoreRoute.settings]) }
    }

    func openDownloads() {
        if compactTabs {
            selectedTab = .settings
            morePath = NavigationPath([FolioMobileMoreRoute.downloads])
        } else {
            selectedTab = .downloads
        }
    }
}

/// In-app confirmation only. Adding a background job never changes tabs.
enum FolioMobileDownloadNotice {
    static let name = Notification.Name("folio.mobile.download.enqueued")

    @MainActor
    static func enqueue(title: String, author: String, hardcoverBookID: Int? = nil,
                        hardcoverPages: Int? = nil, cover: URL? = nil) {
        let queue = DownloadQueue.shared
        let before = Set(queue.jobs.filter { $0.stage.isActive }.map(\.id))
        let id = queue.enqueue(title: title, author: author,
                               hardcoverBookID: hardcoverBookID, hardcoverPages: hardcoverPages,
                               cover: cover)
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

    /// Open books first, so the book you're reading sits at the start of the shelf.
    private var shelfBooks: [LocalBook] {
        let open = store.continueReading
        let openIDs = Set(open.map(\.id))
        return Array((open + store.recentlyAdded.filter { !openIDs.contains($0.id) }).prefix(24))
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                heading
                if store.books.isEmpty {
                    emptyLibrary
                } else {
                    FolioMobileBookshelf(books: shelfBooks)
                }
                remoteShelfRow("Currently reading", entries: shelfEntries(.reading), status: .reading)
                remoteShelfRow("Want to read", entries: shelfEntries(.wantToRead), status: .wantToRead)
                if !discovery.byYourAuthors.isEmpty {
                    section("For you") {
                        ForEach(discovery.byYourAuthors) { book in
                            FolioMobileRemoteBookTile(book: book, width: min(tileWidth, 180))
                        }
                    }
                }
                FolioMobileAuthorRows()
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 36)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable {
            await shelves.load(from: hardcover)
            await discovery.load(from: hardcover, books: store.books, tracked: store.data.tracked)
        }
        .navigationTitle("Folio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .folioScreen()
        .task(id: discoveryKey) {
            await discovery.load(from: hardcover, books: store.books, tracked: store.data.tracked)
        }
        .task(id: "\(hardcover.user?.id ?? -1)-\(hardcover.revision)") {
            await shelves.load(from: hardcover)
        }
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
                iconButton("gearshape", label: "Settings") { navigation.openSettings() }
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
        return Array(FolioMobileShelfEntry.merge(hardcover: remote, goodreads: tracked).prefix(15))
    }

    @ViewBuilder
    private func remoteShelfRow(_ title: String, entries: [FolioMobileShelfEntry], status: HCStatus) -> some View {
        if !entries.isEmpty {
            section(title, seeAll: { navigation.openShelf(status) }) {
                ForEach(entries) { entry in
                    if let item = entry.hardcover {
                        FolioMobileRemoteBookTile(book: item.book, width: min(tileWidth, 180))
                            .folioShelfEntryContextMenu(entry) { Task { await shelves.load(from: hardcover) } }
                    } else if let tracked = entry.goodreads {
                        FolioMobileRemoteBookTile(book: tracked.folioBook, width: min(tileWidth, 180))
                            .folioShelfEntryContextMenu(entry)
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

    var body: some View {
        @Bindable var navigation = navigation
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Show", selection: $navigation.libraryScope) {
                    ForEach(FolioMobileLibraryScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .accessibilityIdentifier("folio.libraryScope")

                if showingShelves {
                    FolioMobileShelvesView(search: search)
                } else {
                    booksContent
                }
            }
            .padding(.vertical, 12)
        }
        .folioScreen()
        .searchable(text: $search, prompt: showingShelves ? "Search your shelves" : "Title or author")
        .navigationTitle(showingShelves ? "Library"
                         : collection.flatMap { id in store.data.collections.first { $0.id == id }?.name } ?? "Library")
        .toolbar {
            if !showingShelves {
                ToolbarItem(placement: .topBarLeading) {
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
                        Label("Filter and Sort", systemImage: "line.3.horizontal.decrease")
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(action: showImporter) { Label("Import", systemImage: "plus") }
                    .folioGlassPill()
            }
        }
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

        if visibleBooks.isEmpty {
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 190), spacing: 16)], alignment: .leading, spacing: 24) {
                ForEach(visibleBooks) { book in
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

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            FolioMobileCover(book: book)
                .aspectRatio(0.7, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .shadow(color: .black.opacity(0.14), radius: 6, x: 1, y: 4)
            Text(book.title)
                .font(.system(.subheadline, design: .serif))
                .foregroundStyle(FolioTheme.ink)
                .lineLimit(2)
            Text(book.author.isEmpty ? "Unknown Author" : book.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if book.progress > 0 {
                ProgressView(value: min(1, book.progress))
                    .tint(FolioTheme.olive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

struct FolioMobileCover: View {
    @Environment(LibraryStore.self) private var store
    let book: LocalBook

    var body: some View {
        GeometryReader { geometry in
            if let url = store.coverURL(book), let image = UIImage(contentsOfFile: url.path) {
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
    }
}
