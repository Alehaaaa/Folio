import SwiftUI
import UniformTypeIdentifiers

struct FolioMobileRootView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(FolioMobileNavigation.self) private var navigation
    @Environment(\.horizontalSizeClass) private var sizeClass
    @AppStorage("folioIOS.onboardingCompleted") private var onboardingCompleted = false
    @State private var importing = false
    @State private var showingShelves = false
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
                    FolioMobileHomeView(showImporter: { importing = true }, showShelves: { showingShelves = true })
                        .navigationDestination(for: UUID.self) { FolioMobileBookDetail(bookID: $0) }
                        .navigationDestination(for: HCBook.self) { FolioMobileBookDetail(book: $0) }
                }
            }
            Tab("Library", systemImage: "books.vertical.fill", value: .library) {
                NavigationStack {
                    FolioMobileLibraryView(showImporter: { importing = true })
                        .navigationDestination(for: UUID.self) { FolioMobileBookDetail(bookID: $0) }
                }
            }
            Tab("Discover", systemImage: "magnifyingglass", value: .search) {
                NavigationStack {
                    FolioMobileDiscoverView()
                        .navigationDestination(for: HCBook.self) { FolioMobileBookDetail(book: $0) }
                        .navigationDestination(for: UUID.self) { FolioMobileBookDetail(bookID: $0) }
                }
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: .downloads) {
                NavigationStack { FolioMobileDownloadsView() }
            }
            if sizeClass == .compact {
                Tab("More", systemImage: "ellipsis.circle", value: .settings) {
                    NavigationStack {
                        List {
                            NavigationLink {
                                FolioMobileShelvesView()
                            } label: {
                                Label("My Shelves", systemImage: "books.vertical")
                            }
                            NavigationLink {
                                FolioMobileSourcesView()
                            } label: {
                                Label("Sources", systemImage: "square.stack.3d.up")
                            }
                            NavigationLink {
                                FolioMobileSettingsView(showImporter: { importing = true })
                            } label: {
                                Label("Settings", systemImage: "gearshape")
                            }
                        }
                        .navigationTitle("More")
                    }
                }
            } else {
                Tab("Sources", systemImage: "square.stack.3d.up", value: .sources) {
                    NavigationStack { FolioMobileSourcesView() }
                }
                Tab("Settings", systemImage: "gearshape", value: .settings) {
                    NavigationStack { FolioMobileSettingsView(showImporter: { importing = true }) }
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
        }
        .sheet(isPresented: $showingShelves) {
            NavigationStack { FolioMobileShelvesView() }
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
                            .foregroundStyle(downloadToast.kind == .ready ? Color.green :
                                             downloadToast.kind == .failed ? Color.orange : Color.secondary)
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
                .folioGlassBackground(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
                .folioGlassBackground(in: Capsule())
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
    func openDownloads() { selectedTab = .downloads }
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let showImporter: () -> Void
    let showShelves: () -> Void

    @State private var discovery = FolioMobileHomeRecommendations()
    @State private var refreshNumber = 0
    @ScaledMetric(relativeTo: .body) private var shelfWidth: CGFloat = 140
    @ScaledMetric(relativeTo: .title) private var goalRingSize: CGFloat = 84

    private var nextBook: LocalBook? { store.continueReading.first }

    /// Refresh only when a meaningful preference changes, rather than every
    /// second of a reading session or every increment of page progress.
    private var discoveryKey: String {
        let library = store.books.map { "\($0.id):\($0.author):\($0.status.rawValue):\($0.hardcoverBookID ?? 0):\($0.lastOpenedAt == nil ? 0 : 1)" }
            .sorted().joined(separator: "|")
        let tracked = store.data.tracked.map { "\($0.id):\($0.author):\($0.rating):\($0.shelf)" }
            .sorted().joined(separator: "|")
        return "\(hardcover.user?.id ?? -1)-\(hardcover.revision)-\(refreshNumber)-\(library)-\(tracked)"
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                heading
                if let nextBook {
                    continueReadingCard(nextBook)
                } else if store.books.isEmpty {
                    emptyLibraryCard
                }
                readingGoal
                if store.continueReading.count > 1 {
                    localShelf("Also in Progress", subtitle: "Your other open books",
                               books: Array(store.continueReading.dropFirst().prefix(10)))
                }
                if !store.recentlyAdded.isEmpty {
                    localShelf("Recently Added", subtitle: "Waiting for your next reading session",
                               books: Array(store.recentlyAdded.prefix(12)))
                }
                discoverySection
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 36)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await refreshDiscovery() }
        .navigationTitle("Folio")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: discoveryKey) {
            await discovery.load(from: hardcover, books: store.books, tracked: store.data.tracked)
        }
    }

    private var heading: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 7) {
                Text("YOUR READING SPACE")
                    .font(.caption.weight(.bold))
                    .tracking(1.3)
                    .foregroundStyle(.tint)
                Text(nextBook == nil ? "Your next chapter starts here." : "Good to have you back.")
                    .font(.largeTitle.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Great stories, your progress, and books worth exploring.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: showImporter) {
                if dynamicTypeSize.isAccessibilitySize {
                    Label("Import", systemImage: "plus")
                        .frame(minHeight: 44)
                } else {
                    Image(systemName: "plus")
                        .frame(minWidth: 44, minHeight: 44)
                }
            }
            .folioGlassPill(prominent: true)
            .accessibilityLabel("Import books")
            .accessibilityHint("Choose books from Files to add to your library")
        }
    }

    private func continueReadingCard(_ book: LocalBook) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 16) {
                    continueCover(book).frame(width: 96, height: 140)
                    continueReadingDetails(book)
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    continueCover(book).frame(width: 110, height: 158)
                    continueReadingDetails(book)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func continueCover(_ book: LocalBook) -> some View {
        FolioMobileCover(book: book)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityHidden(true)
    }

    private func continueReadingDetails(_ book: LocalBook) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("CONTINUE READING", systemImage: "book.pages")
                .font(.caption.weight(.bold))
                .foregroundStyle(.tint)
            Text(book.title)
                .font(.title2.weight(.bold))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text(book.author.isEmpty ? "Unknown author" : book.author)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 8) {
                ProgressView(value: min(1, max(0, book.progress)))
                    .tint(.accentColor)
                    .accessibilityLabel("Reading progress")
                    .accessibilityValue(book.progressLabel)
                Text(book.progressLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            FolioGlassButton(title: "Keep Reading", systemImage: "arrow.right", prominent: true) {
                navigation.read(book.id)
            }
            .accessibilityLabel("Continue reading \(book.title)")
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyLibraryCard: some View {
        VStack(alignment: .leading, spacing: 15) {
            Image(systemName: "books.vertical.fill")
                .font(.largeTitle)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("Build a library that's yours")
                .font(.title2.weight(.bold))
            Text("Import an EPUB, PDF, comic or document. Your place, progress and reading history stay together in Folio.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            FolioGlassButton(title: "Import Your First Book", systemImage: "plus", prominent: true) {
                showImporter()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 24))
    }

    private var readingGoal: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text("Your Reading Goals")
                    .font(.title3.weight(.bold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button { showShelves() } label: {
                    Label("My Shelves", systemImage: "books.vertical")
                }
                .folioGlassPill()
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 18) { goalDetail }
            } else {
                HStack(alignment: .center, spacing: 18) { goalDetail }
            }
            Divider()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    goalStreak
                    Spacer(minLength: 0)
                    goalYearly
                }
                VStack(alignment: .leading, spacing: 8) {
                    goalStreak
                    goalYearly
                }
            }
            .font(.subheadline.weight(.medium))
        }
        .padding(20)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 24))
        .accessibilityElement(children: .contain)
    }

    private var goalStreak: some View {
        Label("\(store.streak)-day streak", systemImage: "flame.fill")
            .foregroundStyle(.orange)
    }

    private var goalYearly: some View {
        Text("\(store.finishedThisYear) of \(store.data.goals.booksPerYear) books this year")
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var goalDetail: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: 9)
            Circle()
                .trim(from: 0, to: min(1, store.todayMinutes / Double(max(1, store.data.goals.dailyMinutes))))
                .stroke(.tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(store.todayMinutes))")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                Text("min").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: min(goalRingSize, 132), height: min(goalRingSize, 132))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today's reading")
        .accessibilityValue("\(Int(store.todayMinutes)) of \(store.data.goals.dailyMinutes) minutes")

        VStack(alignment: .leading, spacing: 7) {
            Text("Today's Reading")
                .font(.headline)
            Text("\(Int(store.todayMinutes)) / \(store.data.goals.dailyMinutes) minutes")
                .font(.title3.weight(.semibold))
                .monospacedDigit()
            Text(store.isDailyGoalCompleted ? "Daily goal complete. Keep the momentum going." : "A little reading today goes a long way.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionHeading(_ title: String, subtitle: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title2.weight(.bold))
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func localShelf(_ title: String, subtitle: String, books: [LocalBook]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(title, subtitle: subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(books) { book in
                        NavigationLink(value: book.id) {
                            FolioMobileBookTile(book: book)
                                .frame(width: min(shelfWidth, 220))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(book.title), \(book.author.isEmpty ? "unknown author" : book.author), \(book.progressLabel)")
                        .accessibilityHint("Open book details")
                    }
                }
                .padding(.vertical, 5)
            }
            .contentMargins(.trailing, 18)
        }
    }

    @ViewBuilder
    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 18) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    sectionHeading("Explore Your Next Read", subtitle: "Books from Hardcover's live catalogue")
                    discoverAllButton
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    sectionHeading("Explore Your Next Read", subtitle: "Books from Hardcover's live catalogue")
                    Spacer(minLength: 0)
                    discoverAllButton
                }
            }

            if !hardcover.isConnected {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Connect Hardcover to discover books", systemImage: "books.vertical.circle")
                        .font(.headline)
                    Text("Connect your account in Settings to see real trending books and suggestions from authors you already read.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    FolioGlassButton(title: "Open Settings", systemImage: "gearshape") {
                        navigation.selectedTab = .settings
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
            } else {
                if !discovery.byYourAuthors.isEmpty {
                    remoteShelf(
                        "More From Authors You Read",
                        subtitle: "Based on your library and reading shelves: \(discovery.authorNames.joined(separator: ", "))",
                        books: discovery.byYourAuthors
                    )
                }
                if !discovery.trending.isEmpty {
                    remoteShelf("Trending & Popular on Hardcover",
                                subtitle: "Hardcover's trending feed or its popular-books fallback, not personalized recommendations",
                                books: discovery.trending)
                }
                if discovery.loading && discovery.trending.isEmpty && discovery.byYourAuthors.isEmpty {
                    discoverySkeleton
                }
                if let error = discovery.error, !discovery.loading {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Books couldn't be loaded", systemImage: "wifi.exclamationmark")
                            .font(.headline)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        FolioGlassButton(title: "Try Again", systemImage: "arrow.clockwise") {
                            refreshNumber += 1
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 20))
                } else if discovery.loading {
                    HStack(spacing: 9) {
                        ProgressView()
                        Text("Updating book suggestions…")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityLabel("Loading suggestions from Hardcover")
                }
            }
        }
    }

    private var discoverAllButton: some View {
        Button("Discover All") { navigation.selectedTab = .search }
            .folioGlassPill()
    }

    private func remoteShelf(_ title: String, subtitle: String, books: [HCBook]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(title, subtitle: subtitle)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(books) { book in
                        FolioMobileRemoteBookTile(book: book, width: min(shelfWidth, 220))
                    }
                }
                .padding(.vertical, 5)
            }
            .contentMargins(.trailing, 18)
        }
    }

    private var discoverySkeleton: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Loading books from Hardcover")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(0..<3, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 9) {
                            RoundedRectangle(cornerRadius: 11)
                                .fill(.quaternary)
                                .aspectRatio(0.69, contentMode: .fit)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.quaternary)
                                .frame(height: 13)
                            RoundedRectangle(cornerRadius: 5)
                                .fill(.quaternary)
                                .frame(width: 75, height: 10)
                        }
                        .frame(width: min(shelfWidth, 180))
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading live book suggestions")
    }

    private func refreshDiscovery() async {
        await discovery.load(from: hardcover, books: store.books, tracked: store.data.tracked)
    }
}

struct FolioMobileLibraryView: View {
    @Environment(LibraryStore.self) private var store
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 12)
        }
        .searchable(text: $search, prompt: "Title or author")
        .navigationTitle(collection.flatMap { id in store.data.collections.first { $0.id == id }?.name } ?? "Library")
        .toolbar {
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
                .clipShape(RoundedRectangle(cornerRadius: 9))
            Text(book.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Text(book.author.isEmpty ? "Unknown Author" : book.author)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if book.progress > 0 {
                ProgressView(value: min(1, book.progress))
                    .tint(.accentColor)
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
                ZStack {
                    Color.indigo.opacity(0.78)
                    VStack(spacing: 12) {
                        Image(systemName: book.format.symbol)
                            .font(.system(size: 29))
                            .foregroundStyle(.white.opacity(0.75))
                        Text(book.title)
                            .font(.system(size: 14, weight: .bold, design: .serif))
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                            .foregroundStyle(.white)
                    }
                    .padding(14)
                }
            }
        }
        .background(.secondary.opacity(0.1))
    }
}
