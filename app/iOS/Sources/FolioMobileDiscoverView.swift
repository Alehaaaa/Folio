import SwiftUI

/// Discover: search Hardcover, browse rows of books, open any row into a
/// filterable page, and jump to any theme from the index at the bottom.
struct FolioMobileDiscoverView: View {
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation

    @State private var query = ""
    @State private var feed = FolioMobileDiscoverFeed()
    @State private var searchHits: [HCBook] = []
    @State private var completedSearch: String?
    @State private var loading = false
    @State private var error: String?
    @State private var activeRequest = UUID()
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 118

    private var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isSearching: Bool { !searchText.isEmpty }
    private var taskKey: String { "\(hardcover.isConnected)|\(searchText)" }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 34) {
                if !hardcover.isConnected {
                    ContentUnavailableView {
                        Label("Connect Hardcover", systemImage: "person.crop.circle.badge.plus")
                    } description: {
                        Text("Connect your Hardcover account in Settings to explore and search books.")
                    } actions: {
                        Button("Open Settings") { navigation.openSettings() }
                            .folioGlassPill(prominent: true)
                    }
                } else if isSearching {
                    searchResults
                } else {
                    if let message = feed.error, feed.visibleTopics.isEmpty {
                        failureView(message)
                    }
                    ForEach(feed.visibleTopics) { topic in
                        row(topic)
                    }
                    FolioMobileDiscoverIndex()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Discover")
        .folioScreen()
        .navigationDestination(for: FolioDiscoverTopic.self) { topic in
            FolioMobileDiscoverTopicPage(topic: topic, initial: feed.books[topic.id] ?? [])
        }
        .searchable(text: $query, prompt: "Titles, authors or series")
        .refreshable {
            if isSearching { await search(searchText) }
            else { await feed.load(from: hardcover, force: true) }
        }
        .task(id: taskKey) {
            // Invalidate requests as soon as the search changes, not only after debounce.
            activeRequest = UUID()
            if !hardcover.isConnected {
                loading = false
                error = nil
            } else if !isSearching {
                loading = false
                await FolioReadBooks.shared.refresh(from: hardcover)
                await feed.load(from: hardcover)
            } else {
                loading = true
                do {
                    try await Task.sleep(for: .milliseconds(320))
                    guard !Task.isCancelled else { return }
                    await search(searchText)
                } catch {
                    // A newer search replaced this request.
                }
            }
        }
    }

    /// A row title that opens the full list, and a strip of covers. Rows
    /// still loading show placeholder covers in place, so nothing jumps.
    private func row(_ topic: FolioDiscoverTopic) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            NavigationLink(value: topic) {
                HStack(spacing: 6) {
                    Text(topic.title)
                        .font(.folioDisplay(.title2))
                        .foregroundStyle(FolioTheme.ink)
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FolioTheme.olive)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint("Show all books in \(topic.title)")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if let books = feed.books[topic.id].map(FolioReadBooks.shared.unread), !books.isEmpty {
                        ForEach(books) { book in
                            FolioMobileRemoteBookTile(book: book, width: min(tileWidth, 180))
                        }
                    } else {
                        ForEach(0..<6, id: \.self) { _ in
                            FolioMobileBookSkeleton(width: min(tileWidth, 180))
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 20)
            .padding(.horizontal, -20)
            .scrollDisabled(feed.books[topic.id]?.isEmpty ?? true)
        }
    }

    @ViewBuilder
    private var searchResults: some View {
        if loading || completedSearch != searchText {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 120)
        } else if let error {
            failureView(error)
        } else if FolioReadBooks.shared.unread(searchHits).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            FolioMobileRemoteBookGridSection(
                title: "Results",
                books: FolioReadBooks.shared.unread(FolioMobileDiscoverySections.unique(searchHits))
            )
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "wifi.exclamationmark")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry") {
                Task {
                    if isSearching { await search(searchText) }
                    else { await feed.load(from: hardcover, force: true) }
                }
            }
            .folioGlassPill(prominent: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func search(_ text: String) async {
        guard hardcover.isConnected, !text.isEmpty else { return }
        let requestID = UUID()
        activeRequest = requestID
        loading = true
        error = nil
        defer { if activeRequest == requestID { loading = false } }
        FolioLog.log("Search \"\(text)\"", "search")
        do {
            let books = try await hardcover.search(text)
            FolioLog.log("Search \"\(text)\": \(books.count) results, memory \(FolioLog.footprintMB()) MB", "search")
            guard !Task.isCancelled, activeRequest == requestID else { return }
            searchHits = FolioMobileDiscoverySections.unique(books)
            completedSearch = text
            error = nil
        } catch {
            guard !Task.isCancelled, activeRequest == requestID else { return }
            FolioLog.log("Search \"\(text)\" failed: \(error.localizedDescription)", "search")
            searchHits = []
            completedSearch = text
            self.error = error.localizedDescription
        }
    }
}

/// A cover-shaped placeholder with two text bars, the same size as a book tile.
struct FolioMobileBookSkeleton: View {
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(FolioTheme.line.opacity(0.55))
                .aspectRatio(0.69, contentMode: .fit)
            RoundedRectangle(cornerRadius: 4)
                .fill(FolioTheme.line.opacity(0.55))
                .frame(height: 12)
            RoundedRectangle(cornerRadius: 4)
                .fill(FolioTheme.line.opacity(0.4))
                .frame(width: (width ?? 120) * 0.6, height: 10)
            Spacer(minLength: 0)
        }
        .frame(width: width, alignment: .topLeading)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
        .accessibilityHidden(true)
    }
}

/// Every theme, grouped and tappable, at the end of Discover.
struct FolioMobileDiscoverIndex: View {
    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Browse by theme")
                .font(.folioDisplay(.title2))
                .foregroundStyle(FolioTheme.ink)
                .accessibilityAddTraits(.isHeader)
            ForEach(FolioDiscoverCatalog.groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FolioTheme.muted)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(group.topics) { topic in
                            NavigationLink(value: topic) {
                                HStack {
                                    Text(topic.title)
                                        .font(.system(.body, design: .serif))
                                        .foregroundStyle(FolioTheme.ink)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Spacer(minLength: 4)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(FolioTheme.olive)
                                }
                                .padding(.horizontal, 14)
                                .frame(minHeight: 48)
                                .folioCard(cornerRadius: 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.top, 6)
    }
}

/// A full list for one theme, with sort, year and rating filters and paging.
struct FolioMobileDiscoverTopicPage: View {
    let topic: FolioDiscoverTopic
    let initial: [HCBook]

    @Environment(HardcoverClient.self) private var hardcover
    @State private var filters = FolioDiscoverFilters()
    @State private var books: [HCBook] = []
    /// Books Hardcover has returned so far, repeats included, for the next page's offset.
    @State private var fetched = 0
    @State private var loading = false
    @State private var reachedEnd = false
    @State private var error: String?
    @State private var started = false

    private let pageSize = 30

    /// The loaded books without the ones already read.
    private var shown: [HCBook] { FolioReadBooks.shared.unread(books) }
    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 170), spacing: 14, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                filterBar
                if let error, shown.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(error, systemImage: "wifi.exclamationmark")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Retry") { Task { await reload() } }
                            .folioGlassPill(prominent: true)
                    }
                } else if shown.isEmpty && !loading && started && (reachedEnd || books.isEmpty) {
                    ContentUnavailableView("No Books Found", systemImage: "books.vertical",
                                           description: Text("Try another year or rating."))
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                        ForEach(shown) { book in
                            FolioMobileRemoteBookTile(book: book)
                                .onAppear {
                                    if book.id == shown.last?.id { Task { await loadMore() } }
                                }
                        }
                        if loading {
                            ForEach(0..<(shown.isEmpty ? 9 : 3), id: \.self) { _ in
                                FolioMobileBookSkeleton()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 30)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(topic.title)
        .navigationBarTitleDisplayMode(.large)
        .folioScreen()
        .task {
            guard !started else { return }
            started = true
            if !initial.isEmpty { books = initial }
            await reload()
        }
        .task(id: books.count) {
            // Pages full of books already read show few tiles: fetch on until the screen fills.
            if started, shown.count < 12, !books.isEmpty { await loadMore() }
        }
        .onChange(of: filters) { _, _ in
            books = []
            Task { await reload() }
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterMenu(filters.sort.rawValue, active: filters.sort != .popular,
                           selection: $filters.sort, options: FolioDiscoverFilters.Sort.allCases)
                filterMenu(filters.published.rawValue, active: filters.published != .any,
                           selection: $filters.published, options: FolioDiscoverFilters.Published.allCases)
                filterMenu(filters.rating.rawValue, active: filters.rating != .any,
                           selection: $filters.rating, options: FolioDiscoverFilters.Rating.allCases)
                if !filters.isDefault {
                    Button("Reset") { filters = FolioDiscoverFilters() }
                        .font(.subheadline)
                        .foregroundStyle(FolioTheme.olive)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.vertical, 2)
        }
        .contentMargins(.horizontal, 20)
        .padding(.horizontal, -20)
    }

    private func filterMenu<Option: Hashable & Identifiable & RawRepresentable>(
        _ label: String, active: Bool, selection: Binding<Option>, options: [Option]
    ) -> some View where Option.RawValue == String {
        Menu {
            Picker(label, selection: selection) {
                ForEach(options) { Text($0.rawValue).tag($0) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(active ? FolioTheme.surface : FolioTheme.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 8)
            .background(active ? FolioTheme.ink : FolioTheme.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(FolioTheme.line, lineWidth: active ? 0 : 0.8) }
        }
    }

    private func reload() async {
        reachedEnd = false
        error = nil
        let filtersNow = filters
        loading = true
        defer { loading = false }
        do {
            let page = try await hardcover.discoverBooks(topic, filters: filtersNow, limit: pageSize, offset: 0)
            guard filtersNow == filters else { return }
            books = FolioMobileDiscoverySections.unique(page)
            fetched = page.count
            reachedEnd = page.count < pageSize
        } catch {
            guard filtersNow == filters else { return }
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private func loadMore() async {
        guard !loading, !reachedEnd, error == nil else { return }
        let filtersNow = filters
        loading = true
        defer { loading = false }
        do {
            let page = try await hardcover.discoverBooks(topic, filters: filtersNow, limit: pageSize, offset: fetched)
            guard filtersNow == filters else { return }
            books = FolioMobileDiscoverySections.unique(books + page)
            fetched += page.count
            reachedEnd = page.count < pageSize
        } catch {
            reachedEnd = true
        }
    }
}
