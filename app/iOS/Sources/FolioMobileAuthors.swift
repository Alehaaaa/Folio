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

struct FolioFollowedAuthor: Codable, Hashable, Identifiable {
    var id: String { FolioAuthorNames.key(name) }
    var hardcoverID: Int?
    var name: String
    var imageURL: URL?
}

/// Authors the reader follows, kept on this device.
@Observable
@MainActor
final class FolioFollowedAuthors {
    static let shared = FolioFollowedAuthors()
    private static let defaultsKey = "folio.followedAuthors"

    private(set) var authors: [FolioFollowedAuthor] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([FolioFollowedAuthor].self, from: data) {
            authors = saved
        }
    }

    func isFollowing(_ name: String) -> Bool {
        let key = FolioAuthorNames.key(name)
        return authors.contains { $0.id == key }
    }

    func toggle(name: String, hardcoverID: Int?, imageURL: URL?) {
        let key = FolioAuthorNames.key(name)
        if let index = authors.firstIndex(where: { $0.id == key }) {
            authors.remove(at: index)
        } else {
            authors.insert(FolioFollowedAuthor(hardcoverID: hardcoverID, name: name, imageURL: imageURL), at: 0)
        }
        save()
    }

    /// Fill in an id or portrait learned later.
    func refresh(name: String, hardcoverID: Int?, imageURL: URL?) {
        let key = FolioAuthorNames.key(name)
        guard let index = authors.firstIndex(where: { $0.id == key }) else { return }
        if authors[index].hardcoverID == hardcoverID && authors[index].imageURL == imageURL { return }
        authors[index].hardcoverID = hardcoverID ?? authors[index].hardcoverID
        authors[index].imageURL = imageURL ?? authors[index].imageURL
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(authors) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

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
            if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: url, options: .atomic) }
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

    private var initials: String {
        FolioAuthorNames.split(name).first.map { full in
            full.split(separator: " ").compactMap(\.first).prefix(2).map { String($0) }.joined()
        } ?? "?"
    }

    var body: some View {
        FolioCachedImage(url: url) {
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

/// Five stars filled to a rating, with halves.
struct FolioStars: View {
    let rating: Double
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: size * 0.15) {
            ForEach(1...5, id: \.self) { n in
                let value = rating - Double(n - 1)
                Image(systemName: value >= 0.75 ? "star.fill" : value >= 0.25 ? "star.leadinghalf.filled" : "star")
                    .font(.system(size: size))
            }
        }
        .foregroundStyle(FolioTheme.caution)
        .accessibilityElement()
        .accessibilityLabel("\(rating.formatted(.number.precision(.fractionLength(1)))) out of 5 stars")
    }
}

/// One serif title over a horizontal row, as on Home.
struct FolioMobileRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.folioDisplay(.title2))
                .foregroundStyle(FolioTheme.ink)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 20)
            .padding(.horizontal, -20)
        }
    }
}

extension String {
    /// "2014-07-15" as a readable date; other strings pass through.
    var folioReadableDate: String {
        guard let date = Self.folioDayParser.date(from: String(prefix(10))) else { return self }
        return date.formatted(date: .long, time: .omitted)
    }

    /// Made once: building a DateFormatter for every date shown is slow.
    private static let folioDayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()
}

// MARK: - Author page

struct FolioMobileAuthorView: View {
    let route: FolioMobileAuthorRoute

    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    @State private var follows = FolioFollowedAuthors.shared
    @State private var author: HCAuthor?
    @State private var books: [HCBook] = []
    @State private var series: [HCSeriesRef] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var bioExpanded = false

    private var name: String { author?.name ?? route.name }

    private var localBooks: [LocalBook] {
        library.books.filter { book in
            FolioAuthorNames.split(book.author).contains { BookAutoMatch.sameAuthor($0, name) }
        }
    }

    private var portraitURL: URL? {
        author?.imageURL ?? FolioAuthorCache.author(route.name)?.imageURL
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
                if !series.isEmpty { seriesSection }
                if !books.isEmpty {
                    FolioMobileRemoteBookGridSection(title: "Books", books: books)
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
                } else if let failure {
                    Text(failure).font(.subheadline).foregroundStyle(.secondary)
                }
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
    }

    init(route: FolioMobileAuthorRoute) {
        self.route = route
        // The saved page shows on the first frame; the network only refreshes it.
        if let cached = FolioAuthorCache.page(route.name)?.page {
            _author = State(initialValue: cached.author)
            _books = State(initialValue: cached.books)
            _series = State(initialValue: cached.series)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            FolioAuthorPortrait(name: name, url: portraitURL, size: 92)
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
                                Text("\(count)").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
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
            .folioCard(cornerRadius: 18)
        }
    }

    /// Up to three of the author's covers in the series, fanned like a stack.
    private func coverStack(_ item: HCSeriesRef) -> some View {
        let covers = item.bookIDs.compactMap { id in books.first { $0.id == id } }.prefix(3)
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

    @MainActor
    private func load() async {
        if let cached = FolioAuthorCache.page(route.name) {
            author = cached.page.author
            books = cached.page.books
            series = cached.page.series
            // Author pages change slowly; refresh twice a day at most.
            if Date().timeIntervalSince(cached.saved) < 60 * 60 * 12 { return }
        }
        // Open Library and Wikidata: no account needed, and no Hardcover requests.
        loading = true
        failure = nil
        defer { loading = false }
        do {
            guard let page = try await FolioOpenLibrary.authorPage(name: route.name) else {
                if books.isEmpty { failure = "Open Library has no author page for \(route.name)." }
                return
            }
            author = page.author
            books = page.books
            series = page.series
            FolioAuthorCache.save(page: page, for: route.name)
            follows.refresh(name: page.author.name, hardcoverID: nil, imageURL: page.author.imageURL)
        } catch is CancellationError {
            return
        } catch {
            FolioLog.log("Author page for \(route.name) failed: \(error.localizedDescription)", "discover")
            // Keep showing the saved page when a refresh fails.
            if books.isEmpty { failure = error.localizedDescription }
        }
    }
}

// MARK: - Series page

/// Series pages as last shown, so they open complete and the counts elsewhere
/// match the list the reader sees.
@MainActor
enum FolioSeriesCache {
    struct Entry: Codable {
        var books: [HCSeriesBook]
        var saved: Date
        /// Numbered main entries, the count shown everywhere for this series.
        var mainCount: Int { books.filter { FolioSeriesCache.isMain($0.position) }.count }
    }

    private static var memory: [Int: Entry] = [:]
    /// Series with nothing saved, so views asking on every redraw don't read the disk each time.
    private static var missing: Set<Int> = []

    /// Series rarely change: a list this young is shown without asking again.
    static let freshFor: TimeInterval = 3 * 24 * 60 * 60

    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-series", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    nonisolated static func isMain(_ position: Double?) -> Bool {
        guard let position else { return false }
        return position >= 1 && position == position.rounded()
    }

    static func load(_ id: Int) -> Entry? {
        if let hit = memory[id] { return hit }
        if missing.contains(id) { return nil }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("\(id).json")),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            missing.insert(id)
            return nil
        }
        memory[id] = entry
        return entry
    }

    static func save(_ books: [HCSeriesBook], for id: Int) {
        let entry = Entry(books: books, saved: Date())
        memory[id] = entry
        missing.remove(id)
        if let data = try? JSONEncoder().encode(entry) {
            try? data.write(to: directory.appendingPathComponent("\(id).json"), options: .atomic)
        }
    }
}

struct FolioSavedSeriesItem: Codable, Hashable, Identifiable {
    var id: Int
    var name: String
    var coverURL: URL?
    var count: Int?
}

/// Series the reader saved, kept on this device and shown on Home.
@Observable
@MainActor
final class FolioSavedSeries {
    static let shared = FolioSavedSeries()
    private static let defaultsKey = "folio.savedSeries"

    private(set) var items: [FolioSavedSeriesItem] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([FolioSavedSeriesItem].self, from: data) {
            items = saved
        }
    }

    func isSaved(_ id: Int) -> Bool { items.contains { $0.id == id } }

    func toggle(_ item: FolioSavedSeriesItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items.remove(at: index)
        } else {
            items.insert(item, at: 0)
        }
        persist()
    }

    /// Keep the cover and count of a saved series current.
    func refresh(_ item: FolioSavedSeriesItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }), items[index] != item else { return }
        items[index] = item
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }
}

struct FolioMobileSeriesView: View {
    let route: FolioMobileSeriesRoute

    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @State private var saved = FolioSavedSeries.shared
    @State private var entries: [HCSeriesBook]
    @State private var loading = false
    @State private var failure: String?

    init(route: FolioMobileSeriesRoute) {
        self.route = route
        _entries = State(initialValue: FolioSeriesCache.load(route.id)?.books ?? [])
    }

    /// Numbered books 1, 2, 3… in order.
    private var main: [HCSeriesBook] { entries.filter { FolioSeriesCache.isMain($0.position) } }
    /// Prequels, novellas (0.5, 2.5) and unnumbered companions.
    private var companions: [HCSeriesBook] { entries.filter { !FolioSeriesCache.isMain($0.position) } }

    private var savedItem: FolioSavedSeriesItem {
        FolioSavedSeriesItem(id: route.id, name: route.name,
                             coverURL: (main.first ?? entries.first)?.book.imageURL,
                             count: main.isEmpty ? nil : main.count)
    }

    var body: some View {
        List {
            if entries.isEmpty {
                if loading {
                    ProgressView().frame(maxWidth: .infinity).folioRow()
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary).folioRow()
                }
            }
            if !main.isEmpty {
                Section {
                    ForEach(main) { entry in bookLink(entry) }
                } header: {
                    Text(main.count == 1 ? "1 book" : "\(main.count) books")
                }
            }
            if !companions.isEmpty {
                Section(main.isEmpty ? "Books" : "Also in this series") {
                    ForEach(companions) { entry in bookLink(entry) }
                }
            }
        }
        .navigationTitle(route.name)
        .folioScreen()
        .folioPageHeader(route.name) {
            let isSaved = saved.isSaved(route.id)
            FolioHeaderIcon(symbol: isSaved ? "bookmark.fill" : "bookmark", label: isSaved ? "Saved" : "Save Series") {
                saved.toggle(savedItem)
            }
            .accessibilityIdentifier("folio.saveSeries")
        }
        .task(id: route.id) { await load() }
    }

    /// Wikidata series (negative ids) come with Open Library's books and need no account;
    /// series only Hardcover knows go through its paced client. Either way the list is
    /// cached, so the book page that linked here has usually fetched it already.
    @MainActor
    private func load() async {
        if let cached = FolioSeriesCache.load(route.id) {
            entries = cached.books
            if Date().timeIntervalSince(cached.saved) < FolioSeriesCache.freshFor { return }
        }
        guard route.id < 0 || hardcover.isConnected else { return }
        loading = true
        defer { loading = false }
        do {
            let books = route.id < 0
                ? try await FolioWikidataSeries.books(route.id)
                : try await hardcover.seriesBooks(route.id).map { HCSeriesBook(position: $0.position, book: $0.book) }
            entries = books
            failure = books.isEmpty ? "No books found in this series." : nil
            FolioSeriesCache.save(books, for: route.id)
            saved.refresh(savedItem)
        } catch is CancellationError {
            return
        } catch {
            if entries.isEmpty { failure = error.localizedDescription }
        }
    }

    private func bookLink(_ entry: HCSeriesBook) -> some View {
        NavigationLink(value: entry.book) {
            row(entry)
        }
        .listRowBackground(entry.book.id == route.currentBookID ? FolioTheme.sage : FolioTheme.surface)
    }

    private func row(_ entry: HCSeriesBook) -> some View {
        let owned = library.books.contains { $0.hardcoverBookID == entry.book.id }
            || library.localCopy(author: entry.book.authors, title: entry.book.title) != nil
        return HStack(spacing: 14) {
            Text(entry.position.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "–")
                .font(.system(.title3, design: .serif))
                .foregroundStyle(FolioTheme.olive)
                .frame(minWidth: 30)
                .monospacedDigit()
            // Your edition when you own it, as everywhere else.
            let shown = FolioBookOverrides.shared.apply(entry.book)
            FolioMobileRemoteCover(url: shown.imageURL, title: shown.title)
                .frame(width: 46, height: 68)
            VStack(alignment: .leading, spacing: 5) {
                Text(shown.title)
                    .font(.system(.body, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    if let year = entry.book.year { Text(String(year)) }
                    if let rating = entry.book.rating, rating > 0 {
                        Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill")
                    }
                    if owned { Label("In library", systemImage: "checkmark.circle.fill").foregroundStyle(FolioTheme.success) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Saved series on Home, each opening its series page.
struct FolioMobileSavedSeriesRow: View {
    @State private var saved = FolioSavedSeries.shared

    var body: some View {
        if !saved.items.isEmpty {
            FolioMobileRow(title: "Your series") {
                ForEach(saved.items) { item in
                    NavigationLink(value: FolioMobileSeriesRoute(id: item.id, name: item.name, currentBookID: nil)) {
                        VStack(alignment: .leading, spacing: 6) {
                            FolioMobileRemoteCover(url: item.coverURL, title: item.name)
                                .frame(width: 100, height: 146)
                            Text(item.name)
                                .font(.system(.caption, design: .serif))
                                .foregroundStyle(FolioTheme.ink)
                                .lineLimit(2, reservesSpace: true)
                            if let count = FolioSeriesCache.load(item.id)?.mainCount ?? item.count {
                                Text(count == 1 ? "1 book" : "\(count) books")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 100, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Ratings and reviews

/// Average, count and the five-bar distribution, as on Goodreads.
struct FolioMobileRatingsSummary: View {
    let stats: HCBookStats

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text((stats.rating ?? 0).formatted(.number.precision(.fractionLength(2))))
                    .font(.system(size: 44, weight: .regular, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 5) {
                    FolioStars(rating: stats.rating ?? 0, size: 16)
                    Text(countsLine)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            if stats.distribution.count == 5 {
                let total = max(1, stats.distribution.reduce(0, +))
                VStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
                        let share = Double(stats.distribution[index]) / Double(total)
                        HStack(spacing: 10) {
                            Text("\(5 - index)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(FolioTheme.line.opacity(0.6))
                                    Capsule().fill(FolioTheme.caution)
                                        .frame(width: max(share > 0 ? 4 : 0, geo.size.width * share))
                                }
                            }
                            .frame(height: 8)
                            Text("\(Int((share * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(5 - index) stars, \(Int((share * 100).rounded())) percent")
                    }
                }
            }
        }
    }

    private var countsLine: String {
        var parts: [String] = []
        if let n = stats.ratingsCount { parts.append("\(n.formatted()) ratings") }
        if let n = stats.reviewsCount, n > 0 { parts.append("\(n.formatted()) reviews") }
        return parts.isEmpty ? "No ratings yet" : parts.joined(separator: " · ")
    }
}

struct FolioMobileReviewRow: View {
    let review: HCReview
    var lineLimit: Int? = 6
    @State private var revealed = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                FolioAuthorPortrait(name: review.username ?? "Reader", url: review.userImage, size: 28)
                Text(review.username.map { "@\($0)" } ?? "A reader")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FolioTheme.ink)
                Spacer(minLength: 6)
                if let rating = review.rating, rating > 0 { FolioStars(rating: rating, size: 11) }
            }
            ZStack {
                Text(review.text)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(expanded ? nil : lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .blur(radius: review.spoilers && !revealed ? 6 : 0)
                if review.spoilers && !revealed {
                    Button("Show spoilers") { revealed = true }
                        .font(.subheadline)
                        .folioGlassPill()
                }
            }
            .onTapGesture { if !review.spoilers || revealed { expanded.toggle() } }
            HStack(spacing: 12) {
                if let date = review.date { Text(date.folioReadableDate) }
                if review.likes > 0 { Label("\(review.likes)", systemImage: "heart") }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct FolioMobileRatingsView: View {
    let route: FolioMobileRatingsRoute

    @Environment(HardcoverClient.self) private var hardcover
    @State private var stats: HCBookStats?
    @State private var reviews: [HCReview] = []
    @State private var reviewsFailed = false
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let stats {
                    FolioMobileRatingsSummary(stats: stats)
                        .padding(18)
                        .folioCard(cornerRadius: 18)
                    if let readers = stats.readersCount, readers > 0 {
                        HStack(spacing: 0) {
                            stat(readers, "readers")
                            if let read = stats.readCount, read > 0 { stat(read, "finished") }
                            if let n = stats.reviewsCount, n > 0 { stat(n, "reviews") }
                        }
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }
                if !reviews.isEmpty {
                    Text("Reviews")
                        .font(.folioDisplay(.title2))
                        .foregroundStyle(FolioTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(reviews.enumerated()), id: \.element.id) { index, review in
                            if index > 0 { Divider().padding(.vertical, 14) }
                            FolioMobileReviewRow(review: review, lineLimit: 10)
                        }
                    }
                    .padding(18)
                    .folioCard(cornerRadius: 18)
                } else if reviewsFailed {
                    Text("Reviews could not be loaded from Hardcover.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } else if !loading {
                    Text("No written reviews yet.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(route.title)
        .folioScreen()
        .folioPageHeader(route.title)
        .task(id: route.bookID) {
            loading = true
            stats = try? await hardcover.stats(bookID: route.bookID)
            do {
                reviews = try await hardcover.reviews(bookID: route.bookID, limit: 40)
            } catch {
                reviewsFailed = true
            }
            loading = false
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(.title3, design: .serif))
                .foregroundStyle(FolioTheme.ink)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

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
