import SwiftUI
import Observation

// MARK: - Routes

/// An author page, opened from a byline. Local books only know the name, so the
/// Hardcover id is optional and resolved on the page.
struct FolioMobileAuthorRoute: Hashable {
    var name: String
    var id: Int?
}

struct FolioMobileSeriesRoute: Hashable {
    var id: Int
    var name: String
    var currentBookID: Int?
}

struct FolioMobileRatingsRoute: Hashable {
    var bookID: Int
    var title: String
}

extension View {
    /// Every page a book can lead to, registered once per navigation stack.
    func folioDetailDestinations() -> some View {
        self
            .navigationDestination(for: UUID.self) { FolioMobileBookDetail(bookID: $0) }
            .navigationDestination(for: HCBook.self) { FolioMobileBookDetail(book: $0) }
            .navigationDestination(for: FolioMobileAuthorRoute.self) { FolioMobileAuthorView(route: $0) }
            .navigationDestination(for: FolioMobileSeriesRoute.self) { FolioMobileSeriesView(route: $0) }
            .navigationDestination(for: FolioMobileRatingsRoute.self) { FolioMobileRatingsView(route: $0) }
            .navigationDestination(for: FolioMobileListRoute.self) { FolioMobileListView(route: $0) }
            .navigationDestination(for: FolioMobileListsRoute.self) { FolioMobileListsView(route: $0) }
            .navigationDestination(for: FolioMobileTopicRoute.self) { route in
                FolioMobileDiscoverTopicPage(topic: route.topic, initial: route.initial,
                                             filters: FolioDiscoverFilters(sort: route.sort))
            }
    }
}

/// A full grid with filters (as Discover's "See all"), opened from any page:
/// an author's books, or a genre.
struct FolioMobileTopicRoute: Hashable {
    var topic: FolioDiscoverTopic
    var sort: FolioDiscoverFilters.Sort = .popular
    /// Shown while the first page loads.
    var initial: [HCBook] = []

    static func author(_ name: String, title: String, sort: FolioDiscoverFilters.Sort = .popular,
                       initial: [HCBook] = []) -> Self {
        Self(topic: FolioDiscoverTopic(kind: .author(name), title: title), sort: sort, initial: initial)
    }

    static func genre(_ name: String) -> Self {
        Self(topic: FolioDiscoverTopic(kind: .genre(name), title: name))
    }
}

enum FolioAuthorNames {
    /// "A, B & C" becomes three authors.
    static func split(_ byline: String) -> [String] {
        byline
            .replacingOccurrences(of: " & ", with: ",")
            .replacingOccurrences(of: " and ", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.lowercased() != "unknown author" }
    }

    static func key(_ name: String) -> String {
        BookAutoMatch.words(name).sorted().joined(separator: " ")
    }
}

// MARK: - Followed authors

// MARK: - On-disk cache

/// Author portraits and the "From authors you follow" row, saved so Home and
/// author bylines show at once and only refresh from the network.
@MainActor
enum FolioAuthorCache {
    struct Author: Codable {
        var id: Int?
        var name: String
        var imageURL: URL?
        var checked: Date
    }

    struct Book: Codable {
        var id: Int
        var title: String
        var authors: String
        var imageURL: URL?
        var year: Int?
        var rating: Double?
        var slug: String?

        init(_ b: HCBook) {
            id = b.id; title = b.title; authors = b.authors; imageURL = b.imageURL
            year = b.year; rating = b.rating; slug = b.slug
        }

        var value: HCBook {
            HCBook(id: id, title: title, authors: authors, imageURL: imageURL, year: year, pages: nil,
                   rating: rating, ratingsCount: nil, description: nil, slug: slug)
        }
    }

    private struct Snapshot: Codable {
        var authors: [String: Author] = [:]
        var followedKey = ""
        var followedBooks: [Book] = []
        var followedSaved: Date?
        var pages: [String: Page]?
    }

    struct Page: Codable {
        var page: HCAuthorPage
        var saved: Date
    }

    private static var loaded: Snapshot?

    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-authors.json")
    }

    private static var snapshot: Snapshot {
        get {
            if let loaded { return loaded }
            let value = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Snapshot.self, from: $0) } ?? Snapshot()
            loaded = value
            return value
        }
        set {
            loaded = newValue
            scheduleWrite()
        }
    }

    private static var pendingWrite: Task<Void, Never>?
    private static let writer = DispatchQueue(label: "folio.author-pages", qos: .utility)

    /// The file holds every saved author page, so it is written once after a burst of
    /// changes (Home resolves up to 25 names at once), off the main thread.
    private static func scheduleWrite() {
        pendingWrite?.cancel()
        pendingWrite = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let value = loaded else { return }
            let target = url
            writer.async {
                if let data = try? JSONEncoder().encode(value) { try? data.write(to: target, options: .atomic) }
            }
        }
    }

    static func author(_ name: String) -> Author? { snapshot.authors[FolioAuthorNames.key(name)] }

    static func save(author: HCAuthor?, for name: String) {
        var s = snapshot
        s.authors[FolioAuthorNames.key(name)] = Author(id: author?.id, name: author?.name ?? name,
                                                        imageURL: author?.imageURL, checked: Date())
        snapshot = s
    }

    static func followedBooks(key: String) -> (books: [HCBook], saved: Date?)? {
        let s = snapshot
        guard s.followedKey == key, !s.followedBooks.isEmpty else { return nil }
        return (s.followedBooks.map(\.value), s.followedSaved)
    }

    static func saveFollowedBooks(_ books: [HCBook], key: String) {
        var s = snapshot
        s.followedKey = key
        s.followedBooks = books.map(Book.init)
        s.followedSaved = Date()
        snapshot = s
    }

    /// A saved author page, only when it has books (an empty one is never worth showing).
    static func page(_ name: String) -> Page? {
        guard let page = snapshot.pages?[FolioAuthorNames.key(name)], !page.page.books.isEmpty else { return nil }
        return page
    }

    static func save(page: HCAuthorPage, for name: String) {
        guard !page.books.isEmpty else { return }
        var s = snapshot
        var pages = s.pages ?? [:]
        let entry = Page(page: page, saved: Date())
        pages[FolioAuthorNames.key(name)] = entry
        pages[FolioAuthorNames.key(page.author.name)] = entry
        // Keep the most recent pages only.
        if pages.count > 60 {
            for key in pages.sorted(by: { $0.value.saved < $1.value.saved }).prefix(pages.count - 60).map(\.key) {
                pages[key] = nil
            }
        }
        s.pages = pages
        s.authors[FolioAuthorNames.key(name)] = Author(id: page.author.id, name: page.author.name,
                                                        imageURL: page.author.imageURL, checked: Date())
        snapshot = s
    }

    /// Look up every unknown name in one request, remembering misses for two weeks.
    static func resolveAll(_ names: [String], hardcover: HardcoverClient) async {
        let fresh = names.filter { name in
            guard let cached = author(name) else { return true }
            return Date().timeIntervalSince(cached.checked) > 60 * 60 * 24 * 14
        }
        guard !fresh.isEmpty, hardcover.isConnected,
              let found = try? await hardcover.authors(named: Array(fresh.prefix(25))) else { return }
        for name in fresh.prefix(25) {
            save(author: found[name], for: name)
        }
    }

    /// Resolve an author by name once, then reuse the answer.
    static func resolve(_ name: String, hardcover: HardcoverClient) async -> Author? {
        if let cached = author(name), Date().timeIntervalSince(cached.checked) < 60 * 60 * 24 * 14 { return cached }
        guard hardcover.isConnected else { return author(name) }
        do {
            // Remember misses too, so unknown names are not looked up every launch.
            let found = try await hardcover.author(named: name)
            save(author: found, for: name)
        } catch {
            return author(name)
        }
        return author(name)
    }
}

// MARK: - Shared pieces

/// A round author portrait, or initials on cloth when there is no photo.
struct FolioAuthorPortrait: View {
    let name: String
    let url: URL?
    var size: CGFloat = 76
    /// Ahead of the covers loading at the same time, for the author page's own portrait.
    var urgent = false

    private var initials: String {
        FolioAuthorNames.split(name).first.map { full in
            full.split(separator: " ").compactMap(\.first).prefix(2).map { String($0) }.joined()
        } ?? "?"
    }

    var body: some View {
        // Kept at the size it draws (3x), not the 600 pixels a cover keeps.
        FolioCachedImage(url: url, maxPixels: Int(size * 3), urgent: urgent) {
            ZStack {
                FolioTheme.spine(for: name)
                Text(initials)
                    .font(.system(size: size * 0.34, weight: .regular, design: .serif))
                    .foregroundStyle(Color(hex: "#F3EBD8"))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay { Circle().strokeBorder(FolioTheme.line, lineWidth: 0.8) }
        .accessibilityHidden(true)
    }
}

// MARK: - Author page

struct FolioMobileAuthorView: View {
    let route: FolioMobileAuthorRoute

    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    @State private var follows = FolioFollowedAuthors.shared
    @State private var author: HCAuthor?
    /// Most-read first.
    @State private var books: [HCBook] = []
    @State private var newest: [HCBook] = []
    @State private var series: [HCSeriesRef] = []
    /// The photo, known from the first quick request, before the full record arrives.
    @State private var earlyPortrait: URL?
    /// Discover genres (or Open Library subjects) the author's books are filed under.
    @State private var genres: [String] = []
    /// Popular books by other authors in the same genres.
    @State private var similar: [HCBook] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var bioExpanded = false
    @State private var order: Order = .popular

    /// How "All books" is sorted.
    enum Order: String, CaseIterable, Identifiable {
        case popular = "Most read", newest = "Newest", oldest = "Oldest", rating = "Highest rated", title = "Title"
        var id: String { rawValue }
    }

    private var name: String { author?.name ?? route.name }

    private var localBooks: [LocalBook] {
        library.books.filter { book in
            FolioAuthorNames.split(book.author).contains { BookAutoMatch.sameAuthor($0, name) }
        }
    }

    private var portraitURL: URL? {
        author?.imageURL ?? earlyPortrait ?? FolioAuthorCache.author(route.name)?.imageURL
    }

    /// Newest first: the dedicated list when there is one, else the known books by year.
    private var newestBooks: [HCBook] {
        let source = newest.isEmpty ? books.filter { $0.year != nil }.sorted { ($0.year ?? 0) > ($1.year ?? 0) } : newest
        return Array(FolioMobileDiscoverySections.unique(source).prefix(15))
    }

    /// Books with enough ratings for the average to mean something, best first.
    private var highestRated: [HCBook] {
        let rated = books.filter { ($0.rating ?? 0) > 0 && ($0.ratingsCount ?? 0) >= 5 }
        guard rated.count >= 4 else { return [] }
        return Array(rated.sorted { ($0.rating ?? 0, $0.ratingsCount ?? 0) > ($1.rating ?? 0, $1.ratingsCount ?? 0) }.prefix(15))
    }

    /// Every known book, newest ones the popular list missed included.
    private var allBooks: [HCBook] {
        let merged = FolioMobileDiscoverySections.unique(books + newest)
        switch order {
        case .popular: return merged
        case .newest: return merged.sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .oldest: return merged.sorted { ($0.year ?? .max) < ($1.year ?? .max) }
        case .rating: return merged.sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .title: return merged.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                if let bio = author?.bio {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bio)
                            .font(.body)
                            .foregroundStyle(FolioTheme.ink)
                            .lineLimit(bioExpanded ? nil : 5)
                            .textSelection(.enabled)
                        if bio.count > 280 {
                            Button(bioExpanded ? "Less" : "More") {
                                withAnimation(.easeInOut(duration: 0.2)) { bioExpanded.toggle() }
                            }
                            .font(.subheadline)
                            .foregroundStyle(FolioTheme.olive)
                        }
                    }
                }
                if !genres.isEmpty { genreChips }
                if !localBooks.isEmpty {
                    FolioMobileRow(title: "In your library") {
                        ForEach(localBooks) { book in
                            NavigationLink(value: book.id) {
                                FolioMobileBookTile(book: book).frame(width: 118)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !books.isEmpty {
                    FolioMobileRow(title: "Popular", seeAll: allRoute(sort: .popular, initial: books)) {
                        ForEach(Array(books.prefix(15))) { book in
                            FolioMobileRemoteBookTile(book: book, width: 118)
                        }
                    }
                } else if loading {
                    skeletonRow
                } else if let failure {
                    Text(failure).font(.subheadline).foregroundStyle(FolioTheme.muted)
                }
                if newestBooks.count >= 3 {
                    FolioMobileRow(title: "Newest", seeAll: allRoute(sort: .newest, initial: newestBooks)) {
                        ForEach(newestBooks) { book in
                            FolioMobileRemoteBookTile(book: book, width: 118)
                        }
                    }
                }
                if !series.isEmpty { seriesSection }
                if !highestRated.isEmpty {
                    FolioMobileRow(title: "Highest rated", seeAll: allRoute(sort: .rated, initial: highestRated)) {
                        ForEach(highestRated) { book in
                            FolioMobileRemoteBookTile(book: book, width: 118)
                        }
                    }
                }
                if similar.count >= 3 {
                    FolioMobileRow(title: "More like this", seeAll: genres.first.map { FolioMobileTopicRoute.genre($0) }) {
                        ForEach(similar) { book in
                            FolioMobileRemoteBookTile(book: book, width: 118)
                        }
                    }
                }
                if books.count > 15 || newest.count > 15 { allBooksSection }
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(name)
        .folioScreen()
        .folioPageHeader(name) {
            if let url = author?.webURL {
                Link(destination: url) { FolioHeaderIconLabel(symbol: "arrow.up.right.square") }
                    .foregroundStyle(FolioTheme.ink)
                    .accessibilityLabel(author?.id ?? 0 < 0 ? "Open on Open Library" : "Open on Hardcover")
            }
        }
        .task(id: "\(route.name)-\(route.id ?? 0)") { await load() }
        .task(id: books.first?.id) { await loadRelated() }
    }

    /// Every book by the author in the filterable grid, opened from a section title.
    private func allRoute(sort: FolioDiscoverFilters.Sort, initial: [HCBook]) -> FolioMobileTopicRoute {
        .author(route.name, title: name, sort: sort, initial: initial)
    }

    /// The author's genres as links to their Discover lists.
    private var genreChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(genres, id: \.self) { genre in
                    NavigationLink(value: FolioMobileTopicRoute.genre(genre)) {
                        Text(genre)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(FolioTheme.ink)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 7)
                            .background(FolioTheme.surface, in: Capsule())
                            .overlay { Capsule().strokeBorder(FolioTheme.line, lineWidth: 0.8) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Show popular \(genre) books")
                }
            }
            .padding(.vertical, 2)
        }
        .contentMargins(.horizontal, 20)
        .padding(.horizontal, -20)
    }

    /// Genres from the subjects on the author's books, Discover's own names first
    /// (their lists are the fullest), then "More like this" from the top two.
    @MainActor
    private func loadRelated() async {
        guard !books.isEmpty else { return }
        let subjects = await FolioOpenLibrary.authorSubjects(name: route.name)
        guard !Task.isCancelled else { return }
        let catalog = FolioDiscoverCatalog.groups.flatMap(\.topics).compactMap { topic -> String? in
            if case .genre(let genre) = topic.kind { return genre }
            return nil
        }
        var picked: [String] = []
        func add(_ genre: String) {
            if !picked.contains(where: { $0.caseInsensitiveCompare(genre) == .orderedSame }) { picked.append(genre) }
        }
        for subject in subjects.prefix(12) {
            let key = subject.lowercased()
            if let known = catalog.first(where: { key == $0.lowercased() || key == $0.lowercased() + " fiction"
                || ($0 == "Young Adult" && key.contains("young adult")) }) {
                add(known)
            }
        }
        for subject in subjects where picked.count < 6 { add(subject) }
        picked = Array(picked.prefix(6))
        if picked != genres { genres = picked }
        guard let base = books.first, !picked.isEmpty,
              let found = try? await FolioOpenLibrary.similar(to: base, genres: Array(picked.prefix(2))),
              !Task.isCancelled else { return }
        let others = found.filter { book in !FolioAuthorNames.split(book.authors).contains { BookAutoMatch.sameAuthor($0, name) } }
        similar = Array(FolioMobileDiscoverySections.unique(others).prefix(15))
    }

    init(route: FolioMobileAuthorRoute) {
        self.route = route
        // The saved page shows on the first frame; the network only refreshes it.
        if let cached = FolioAuthorCache.page(route.name)?.page {
            _author = State(initialValue: cached.author)
            _books = State(initialValue: cached.books)
            _series = State(initialValue: cached.series)
            _newest = State(initialValue: cached.newest ?? [])
        }
    }

    /// Book-shaped placeholders while the first list loads.
    /// Laid out like the real row: four fixed-width tiles in a plain HStack are wider
    /// than a phone, and that widened the whole page and pushed it off the left edge.
    private var skeletonRow: some View {
        FolioMobileRow(title: "Popular") {
            ForEach(0..<4, id: \.self) { _ in FolioMobileBookSkeleton(width: 118) }
        }
        .scrollDisabled(true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading books")
    }

    private var allBooksSection: some View {
        let columns = [GridItem(.adaptive(minimum: 104, maximum: 150), spacing: 14, alignment: .top)]
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("All books")
                    .font(.folioDisplay(.title2))
                    .foregroundStyle(FolioTheme.ink)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Menu {
                    Picker("Sort", selection: $order) {
                        ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(order.rawValue)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(FolioTheme.olive)
                }
                .accessibilityLabel("Sort all books, \(order.rawValue)")
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(allBooks) { book in
                    FolioMobileRemoteBookTile(book: book)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            FolioAuthorPortrait(name: name, url: portraitURL, size: 92, urgent: true)
            VStack(alignment: .leading, spacing: 8) {
                Text(name)
                    .font(.system(size: 28, weight: .regular, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let facts = facts {
                    Text(facts).font(.footnote).foregroundStyle(FolioTheme.muted)
                }
                let following = follows.isFollowing(name)
                Button {
                    follows.toggle(name: name, hardcoverID: author?.id ?? route.id, imageURL: portraitURL)
                } label: {
                    Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus")
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 6)
                }
                .folioGlassPill(prominent: !following)
                .accessibilityIdentifier("folio.followAuthor")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Lifespan, book count and followers on one quiet line.
    private var facts: String? {
        var parts: [String] = []
        if let born = author?.bornYear {
            parts.append(author?.deathYear.map { "\(born)–\($0)" } ?? "Born \(born)")
        }
        if let count = author?.booksCount, count > 0 { parts.append("\(count) books") }
        if let followers = author?.followers, followers > 0 {
            parts.append("\(followers.formatted(.number.notation(.compactName))) readers")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Series")
                .font(.folioDisplay(.title2))
                .foregroundStyle(FolioTheme.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(series.prefix(8).enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.leading, 86) }
                    NavigationLink(value: FolioMobileSeriesRoute(id: item.id, name: item.name, currentBookID: nil)) {
                        HStack(spacing: 14) {
                            coverStack(item)
                            Text(item.name)
                                .font(.system(.body, design: .serif))
                                .foregroundStyle(FolioTheme.ink)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 6)
                            if let count = FolioSeriesCache.load(item.id)?.mainCount ?? item.booksCount, count > 0 {
                                Text("\(count)").font(.subheadline).foregroundStyle(FolioTheme.muted).monospacedDigit()
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .folioCard(cornerRadius: FolioTheme.panelRadius)
        }
    }

    /// Up to three of the author's covers in the series, fanned like a stack.
    private func coverStack(_ item: HCSeriesRef) -> some View {
        let known = FolioMobileDiscoverySections.unique(books + newest)
        let covers = item.bookIDs.compactMap { id in known.first { $0.id == id } }.prefix(3)
        return ZStack(alignment: .leading) {
            if covers.isEmpty {
                FolioClothCover(title: item.name, compact: true)
                    .frame(width: 40, height: 58)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            ForEach(Array(covers.enumerated().reversed()), id: \.element.id) { index, book in
                FolioMobileRemoteCover(url: FolioBookOverrides.shared.apply(book).imageURL, title: book.title)
                    .frame(width: 40, height: 58)
                    .shadow(color: .black.opacity(0.15), radius: 2, x: 1, y: 1)
                    .offset(x: CGFloat(index) * 9)
            }
        }
        .frame(width: 58, height: 58, alignment: .leading)
    }

    /// One part of the page, as it arrives.
    private enum Piece {
        case popular([HCBook]?)
        case newest([HCBook]?)
        case profile(HCAuthor?, wikidata: String?)
        case series([HCSeriesRef]?)
        case portrait(URL?)
    }

    /// Open Library and Wikidata: no account needed, and no Hardcover requests.
    /// The books need only the name, so they load alongside the author's record
    /// instead of after it, and each section shows as soon as its list arrives.
    @MainActor
    private func load() async {
        if let cached = FolioAuthorCache.page(route.name) {
            author = cached.page.author
            books = cached.page.books
            series = cached.page.series
            newest = cached.page.newest ?? []
            // Author pages change slowly; refresh twice a day at most.
            if Date().timeIntervalSince(cached.saved) < 60 * 60 * 12, cached.page.newest != nil { return }
        }
        loading = true
        failure = nil
        defer { loading = false }
        let name = route.name
        var found: HCAuthor?
        var popular: [HCBook]?
        var latest: [HCBook]?
        var foundSeries: [HCSeriesRef]?
        await withTaskGroup(of: Piece.self) { group in
            // First, so the photo starts downloading after one small request.
            if portraitURL == nil {
                group.addTask { .portrait(await FolioOpenLibrary.authorPhoto(name: name)) }
            }
            group.addTask { .popular(try? await FolioOpenLibrary.booksBy(author: name, limit: FolioOpenLibrary.authorPageLimit)) }
            group.addTask { .newest(try? await FolioOpenLibrary.newestBooks(author: name)) }
            group.addTask {
                let profile = try? await FolioOpenLibrary.authorProfile(name: name)
                return .profile(profile?.author, wikidata: profile?.wikidata)
            }
            while let piece = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                switch piece {
                case .popular(let list):
                    popular = list
                    if let list, !list.isEmpty {
                        withAnimation(.easeOut(duration: 0.2)) { books = list }
                    }
                case .newest(let list):
                    latest = list
                    if let list, !list.isEmpty { newest = list }
                case .profile(let profile, let qid):
                    found = profile
                    if let profile { author = profile }
                    if let qid {
                        group.addTask { .series(try? await FolioWikidataSeries.series(ofAuthor: qid)) }
                    }
                case .series(let list):
                    foundSeries = list
                    if let list { series = list }
                case .portrait(let url):
                    if author?.imageURL == nil, let url { earlyPortrait = url }
                }
            }
        }
        guard !Task.isCancelled else { return }
        // Open Library may file the books under the record's spelling of the name.
        if popular?.isEmpty ?? true, let canonical = found?.name, canonical != name,
           let list = try? await FolioOpenLibrary.booksBy(author: canonical, limit: FolioOpenLibrary.authorPageLimit) {
            popular = list
            if !list.isEmpty { books = list }
        }
        guard let popular, !popular.isEmpty else {
            if books.isEmpty {
                failure = popular == nil ? "Couldn't reach Open Library. Try again in a moment."
                    : "Open Library has no books by \(route.name)."
            }
            return
        }
        let profile = found ?? author ?? HCAuthor(id: 0, name: name)
        let page = HCAuthorPage(author: profile, books: popular, series: foundSeries ?? series,
                                newest: latest ?? newest)
        FolioAuthorCache.save(page: page, for: route.name)
        if found != nil {
            follows.refresh(name: profile.name, hardcoverID: nil, imageURL: profile.imageURL)
        }
    }
}

// MARK: - Series page

// MARK: - Ratings and reviews

// MARK: - Home rows

/// "Authors for you" and "From authors you follow" on Home. Both draw from the
/// on-disk cache first, then refresh quietly.
struct FolioMobileAuthorRows: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @State private var follows = FolioFollowedAuthors.shared
    @State private var portraits: [String: URL] = [:]
    @State private var followedBooks: [HCBook] = []
    @ScaledMetric(relativeTo: .body) private var tileWidth: CGFloat = 118

    /// Followed authors first, then the authors the reader spends the most time with.
    private var recommended: [FolioAuthorRef] {
        var scores: [String: (name: String, score: Double)] = [:]
        func add(_ byline: String, _ score: Double) {
            for name in FolioAuthorNames.split(byline) {
                let key = FolioAuthorNames.key(name)
                guard key.count > 2 else { continue }
                scores[key] = (scores[key]?.name ?? name, (scores[key]?.score ?? 0) + score)
            }
        }
        for book in store.books {
            switch book.status {
            case .finished: add(book.author, 5)
            case .reading: add(book.author, 4)
            case .wantToRead: add(book.author, 1)
            case .none: add(book.author, book.lastOpenedAt == nil ? 0.5 : 2)
            }
        }
        for item in store.data.tracked {
            add(item.author, item.rating >= 4 ? 5 : item.rating >= 3 ? 2 : 1)
        }
        let followed = follows.authors.map { FolioAuthorRef(name: $0.name, id: $0.hardcoverID, following: true) }
        let followedKeys = Set(follows.authors.map(\.id))
        let others = scores.filter { !followedKeys.contains($0.key) }.values
            .sorted { $0.score == $1.score ? $0.name < $1.name : $0.score > $1.score }
            .map { FolioAuthorRef(name: $0.name, id: nil, following: false) }
        return Array((followed + others).prefix(14))
    }

    private var followKey: String {
        follows.authors.map(\.id).sorted().joined(separator: "|")
    }

    var body: some View {
        let authors = recommended
        if !authors.isEmpty {
            FolioMobileRow(title: "Authors for you") {
                ForEach(authors, id: \.key) { author in
                    NavigationLink(value: FolioMobileAuthorRoute(name: author.name, id: author.id)) {
                        VStack(spacing: 8) {
                            FolioAuthorPortrait(name: author.name,
                                                url: portraits[author.key] ?? FolioAuthorCache.author(author.name)?.imageURL,
                                                size: 78)
                                .overlay(alignment: .bottomTrailing) {
                                    if author.following {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(FolioTheme.olive, FolioTheme.surface)
                                    }
                                }
                            Text(author.name)
                                .font(.system(.caption, design: .serif))
                                .foregroundStyle(FolioTheme.ink)
                                .multilineTextAlignment(.center)
                                .lineLimit(2, reservesSpace: true)
                        }
                        .frame(width: 88)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(author.following ? "\(author.name), following" : author.name)
                }
            }
            .task(id: authors.map(\.name).joined(separator: "|") + "\(hardcover.isConnected)") {
                await loadPortraits(authors)
            }
            .task(id: "\(followKey)-\(hardcover.isConnected)") { await loadFollowedBooks() }
        }
        // The saved row shows on the first frame; the task only refreshes it.
        let shownBooks = FolioReadBooks.shared.unread(followedBooks.isEmpty && !follows.authors.isEmpty
            ? (FolioAuthorCache.followedBooks(key: followKey)?.books ?? []) : followedBooks)
        if !shownBooks.isEmpty {
            FolioMobileRow(title: "From authors you follow") {
                ForEach(shownBooks) { book in
                    FolioMobileRemoteBookTile(book: book, width: min(tileWidth, 180))
                }
            }
        }
    }

    @MainActor
    private func loadPortraits(_ authors: [FolioAuthorRef]) async {
        // Cached portraits first, all at once.
        for author in authors {
            if let url = FolioAuthorCache.author(author.name)?.imageURL {
                portraits[FolioAuthorNames.key(author.name)] = url
            }
        }
        let missing = authors.filter { portraits[$0.key] == nil }.map(\.name)
        guard !missing.isEmpty, !Task.isCancelled else { return }
        await FolioAuthorCache.resolveAll(missing, hardcover: hardcover)
        for name in missing {
            if let found = FolioAuthorCache.author(name), let url = found.imageURL {
                portraits[FolioAuthorNames.key(name)] = url
                follows.refresh(name: name, hardcoverID: found.id, imageURL: url)
            }
        }
    }

    @MainActor
    private func loadFollowedBooks() async {
        let key = followKey
        guard !follows.authors.isEmpty else {
            followedBooks = []
            return
        }
        let cached = FolioAuthorCache.followedBooks(key: key)
        if let cached { followedBooks = cached.books }
        // Refresh at most every few hours; the cached row shows instantly meanwhile.
        if let saved = cached?.saved, Date().timeIntervalSince(saved) < 60 * 60 * 6 { return }
        let knownIDs = Set(store.books.compactMap(\.hardcoverBookID))
        let followedNow = Array(follows.authors.prefix(6))
        var groups: [[HCBook]] = []
        for followed in followedNow {
            guard !Task.isCancelled else { return }
            let books: [HCBook]
            if let page = FolioAuthorCache.page(followed.name), Date().timeIntervalSince(page.saved) < 60 * 60 * 24 {
                books = page.page.books
            } else {
                guard let fetched = try? await FolioOpenLibrary.booksBy(author: followed.name) else { continue }
                books = fetched
            }
            let fresh = books.filter {
                !knownIDs.contains($0.id) && store.localCopy(author: $0.authors, title: $0.title) == nil
            }
            groups.append(Array(fresh.prefix(8)))
        }
        guard !Task.isCancelled else { return }
        var ids = Set<Int>()
        var chosen: [HCBook] = []
        for index in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where group.indices.contains(index) {
                if ids.insert(group[index].id).inserted { chosen.append(group[index]) }
            }
        }
        followedBooks = Array(chosen.prefix(18))
        FolioAuthorCache.saveFollowedBooks(followedBooks, key: key)
    }
}

struct FolioAuthorRef: Hashable {
    var key: String { FolioAuthorNames.key(name) }
    var name: String
    var id: Int?
    var following: Bool
}
