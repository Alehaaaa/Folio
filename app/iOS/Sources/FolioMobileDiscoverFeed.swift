import Foundation
import Observation

// MARK: - Topics

/// One browsable Discover list: a row on the Discover page, an entry in the
/// theme index, and a full page with filters.
struct FolioDiscoverTopic: Hashable, Identifiable {
    enum Kind: Hashable {
        case trending, popular, newThisYear, acclaimed, shortReads, longReads
        case genre(String)
        /// Books first published from `from` up to, but not including, `to`.
        case years(from: Int?, to: Int?)
    }

    let kind: Kind
    let title: String
    var id: String { title }
}

struct FolioDiscoverGroup: Identifiable {
    let title: String
    let topics: [FolioDiscoverTopic]
    /// Whether the group's topics appear as rows on the Discover page, or only in the index.
    var showsRows = true
    var id: String { title }
}

enum FolioDiscoverCatalog {
    private static func genre(_ name: String) -> FolioDiscoverTopic { .init(kind: .genre(name), title: name) }

    static let groups: [FolioDiscoverGroup] = [
        FolioDiscoverGroup(title: "Highlights", topics: [
            .init(kind: .trending, title: "Trending now"),
            .init(kind: .newThisYear, title: "New this year"),
            .init(kind: .acclaimed, title: "Acclaimed"),
            .init(kind: .popular, title: "All-time favorites"),
            .init(kind: .shortReads, title: "Short reads"),
            .init(kind: .longReads, title: "Epic reads")
        ]),
        FolioDiscoverGroup(title: "Fiction", topics: [
            "Fantasy", "Science Fiction", "Mystery", "Thriller", "Romance", "Historical Fiction",
            "Horror", "Literary Fiction", "Young Adult", "Classics", "Graphic Novels"
        ].map(genre)),
        FolioDiscoverGroup(title: "Nonfiction", topics: [
            "Nonfiction", "Biography", "History", "Science", "Self Help", "Philosophy", "Poetry"
        ].map(genre)),
        FolioDiscoverGroup(title: "By era", topics: [
            .init(kind: .years(from: 2020, to: nil), title: "2020s"),
            .init(kind: .years(from: 2010, to: 2020), title: "2010s"),
            .init(kind: .years(from: 2000, to: 2010), title: "2000s"),
            .init(kind: .years(from: 1900, to: 2000), title: "20th century"),
            .init(kind: .years(from: nil, to: 1900), title: "Before 1900")
        ], showsRows: false)
    ]

    static var rowTopics: [FolioDiscoverTopic] { groups.filter(\.showsRows).flatMap(\.topics) }
}

// MARK: - Filters

struct FolioDiscoverFilters: Hashable {
    enum Sort: String, CaseIterable, Identifiable {
        case popular = "Most read", rated = "Top rated", newest = "Newest", oldest = "Oldest"
        var id: String { rawValue }
    }

    enum Published: String, CaseIterable, Identifiable {
        case any = "Any year", thisYear = "This year", lastFive = "Last 5 years",
             twentyTens = "2010s", twoThousands = "2000s", twentieth = "20th century", older = "Before 1900"
        var id: String { rawValue }

        var range: (from: Int?, to: Int?)? {
            let year = Calendar.current.component(.year, from: .now)
            switch self {
            case .any: return nil
            case .thisYear: return (year, nil)
            case .lastFive: return (year - 4, nil)
            case .twentyTens: return (2010, 2020)
            case .twoThousands: return (2000, 2010)
            case .twentieth: return (1900, 2000)
            case .older: return (nil, 1900)
            }
        }
    }

    enum Rating: String, CaseIterable, Identifiable {
        case any = "Any rating", four = "4★ and up", fourHalf = "4.5★ and up"
        var id: String { rawValue }
        var minimum: Double? { self == .four ? 4 : self == .fourHalf ? 4.5 : nil }
    }

    var sort: Sort = .popular
    var published: Published = .any
    var rating: Rating = .any

    var isDefault: Bool { self == FolioDiscoverFilters() }

    /// Client-side version of the filters, for lists Hardcover can't filter (Trending).
    func apply(_ books: [HCBook]) -> [HCBook] {
        var out = books
        if let range = published.range {
            out = out.filter { book in
                guard let y = book.year else { return false }
                return (range.from.map { y >= $0 } ?? true) && (range.to.map { y < $0 } ?? true)
            }
        }
        if let minimum = rating.minimum { out = out.filter { ($0.rating ?? 0) >= minimum } }
        switch sort {
        case .popular: break
        case .rated: out.sort { ($0.rating ?? 0) > ($1.rating ?? 0) }
        case .newest: out.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        case .oldest: out.sort { ($0.year ?? .max) < ($1.year ?? .max) }
        }
        return out
    }
}

// MARK: - Hardcover queries

extension HardcoverClient {
    /// How Hardcover answered genre filters this session: the tag relation,
    /// the cached tag list, or neither.
    private enum GenreMode { case unknown, taggings, cachedTags, unsupported }
    private static var genreMode: GenreMode = .unknown

    /// One page of a Discover topic, with optional filters applied by Hardcover.
    func discoverBooks(_ topic: FolioDiscoverTopic, filters: FolioDiscoverFilters = .init(),
                       limit: Int = 24, offset: Int = 0) async throws -> [HCBook] {
        if case .trending = topic.kind {
            guard offset == 0 else { return [] }
            return filters.apply(try await trending())
        }

        var conditions: [String] = []
        var sort = filters.sort
        let year = Calendar.current.component(.year, from: .now)

        func years(_ from: Int?, _ to: Int?) {
            if let from { conditions.append("{release_year: {_gte: \(from)}}") }
            if let to { conditions.append("{release_year: {_lt: \(to)}}") }
        }

        switch topic.kind {
        case .trending, .popular, .genre: break
        case .newThisYear: years(year, nil)
        case .acclaimed:
            conditions.append("{ratings_count: {_gt: 2000}}")
            if filters.sort == .popular { sort = .rated }
        case .shortReads: conditions.append("{pages: {_gt: 60}}"); conditions.append("{pages: {_lt: 250}}")
        case .longReads: conditions.append("{pages: {_gt: 600}}")
        case .years(let from, let to): years(from, to)
        }
        if let range = filters.published.range { years(range.from, range.to) }
        if let minimum = filters.rating.minimum {
            conditions.append("{rating: {_gte: \(minimum)}}")
            conditions.append("{ratings_count: {_gt: 25}}")
        }
        if sort == .rated && filters.rating.minimum == nil, topic.kind != .acclaimed {
            // Top rated among books with a meaningful number of ratings.
            conditions.append("{ratings_count: {_gt: 200}}")
        }
        if sort == .newest || sort == .oldest { conditions.append("{release_year: {_is_null: false}}") }

        let order: String
        switch sort {
        case .popular: order = "{users_count: desc}"
        case .rated: order = "[{rating: desc_nulls_last}, {users_count: desc}]"
        case .newest: order = "[{release_year: desc}, {users_count: desc}]"
        case .oldest: order = "[{release_year: asc}, {users_count: desc}]"
        }

        func run(extra: String?, declarations: String, variables: [String: Any]) async throws -> [HCBook] {
            let all = conditions + (extra.map { [$0] } ?? [])
            let whereClause = all.isEmpty ? "{}" : "{_and: [\(all.joined(separator: ", "))]}"
            let header = declarations.isEmpty ? "query Discover" : "query Discover(\(declarations))"
            let d = try await query("""
            \(header) { books(where: \(whereClause), order_by: \(order), limit: \(limit), offset: \(offset)) { \(Self.bookFields) } }
            """, variables)
            return d["books"].array.compactMap(HCBook.from(book:))
        }

        guard case .genre(let genre) = topic.kind else {
            return try await run(extra: nil, declarations: "", variables: [:])
        }
        let viaTaggings = { try await run(extra: "{taggings: {tag: {tag: {_eq: $g}}}}", declarations: "$g: String!", variables: ["g": genre]) }
        let viaCache = { try await run(extra: "{cached_tags: {_contains: $tags}}", declarations: "$tags: jsonb!",
                                       variables: ["tags": ["Genre": [["tag": genre]]]]) }
        switch Self.genreMode {
        case .taggings: return try await viaTaggings()
        case .cachedTags: return try await viaCache()
        case .unsupported: return []
        case .unknown:
            if let books = try? await viaTaggings(), !books.isEmpty {
                Self.genreMode = .taggings
                return books
            }
            if let books = try? await viaCache(), !books.isEmpty {
                Self.genreMode = .cachedTags
                return books
            }
            return []
        }
    }
}

// MARK: - Discover page feed

/// The Discover page's rows. The last result is kept on disk, so the page
/// opens fully laid out at once and refreshes in the background.
@Observable
@MainActor
final class FolioMobileDiscoverFeed {
    /// Books per topic id. A missing key means the row hasn't loaded yet.
    private(set) var books: [String: [HCBook]] = [:]
    private(set) var loading = false
    private(set) var error: String?
    private var lastRefresh: Date?

    private static let freshFor: TimeInterval = 6 * 60 * 60

    init() {
        if let cache = Self.readCache() {
            books = cache.books.mapValues { FolioMobileDiscoverySections.unique($0.map(\.value)) }
            lastRefresh = cache.savedAt
            prefetchCovers()
        }
    }

    /// The first covers of every row, so rows show their covers as they scroll in.
    private func prefetchCovers() {
        let urls = FolioDiscoverCatalog.rowTopics.flatMap { topic in
            (books[topic.id] ?? []).prefix(8).compactMap(\.imageURL)
        }
        FolioImageCache.shared.prefetch(urls)
    }

    /// Rows to draw: loaded rows with enough books, plus rows still loading.
    var visibleTopics: [FolioDiscoverTopic] {
        FolioDiscoverCatalog.rowTopics.filter { topic in
            guard let list = books[topic.id] else { return loading || books.isEmpty }
            // Rows count only books not read yet.
            return FolioReadBooks.shared.unread(list).count >= 3
        }
    }

    func load(from hardcover: HardcoverClient, force: Bool = false) async {
        guard hardcover.isConnected else { return }
        if !force, let lastRefresh, Date().timeIntervalSince(lastRefresh) < Self.freshFor, !books.isEmpty { return }
        guard !loading else { return }
        loading = true
        defer { loading = false }
        error = nil
        FolioLog.log("Loading \(FolioDiscoverCatalog.rowTopics.count) rows (cached: \(books.count)), memory \(FolioLog.footprintMB()) MB", "discover")

        var fresh: [String: [HCBook]] = [:]
        var firstError: String?
        let topics = FolioDiscoverCatalog.rowTopics
        // A few requests at a time keeps well inside Hardcover's rate limit. Plain
        // tasks, not a task group: on iOS 27 a group whose children run on the main
        // actor ended early and its children then crashed the app ("Pure virtual
        // function called"). These tasks inherit the main actor, like the client.
        var start = 0
        while start < topics.count, !Task.isCancelled {
            let batch = Array(topics[start..<min(start + 4, topics.count)])
            start += batch.count
            let requests = batch.map { topic in
                (topic.id, Task { try await hardcover.discoverBooks(topic, limit: 20) })
            }
            for (id, request) in requests {
                switch await request.result {
                case .success(let found):
                    // Rows are lazy stacks keyed by book id, and a repeated id crashes them.
                    let list = FolioMobileDiscoverySections.unique(found)
                    FolioLog.log("\(id): \(found.count) books (\(found.count - list.count) repeats), memory \(FolioLog.footprintMB()) MB", "discover")
                    fresh[id] = list
                    // Replace a row only when it has new books, so nothing flickers away.
                    if list.count >= 3 || books[id] == nil { books[id] = list }
                case .failure(let failure):
                    if firstError == nil { firstError = failure.localizedDescription }
                    FolioLog.log("\(id) failed: \(failure.localizedDescription)", "discover")
                    if books[id] == nil { books[id] = [] }
                }
            }
        }
        FolioLog.log("Rows done, cancelled: \(Task.isCancelled), memory \(FolioLog.footprintMB()) MB", "discover")
        guard !Task.isCancelled else { return }
        prefetchCovers()
        if fresh.values.contains(where: { $0.count >= 3 }) {
            lastRefresh = Date()
            Self.writeCache(books: books, savedAt: lastRefresh!)
        } else if visibleTopics.isEmpty {
            error = firstError ?? "Hardcover didn't return any books. Try again later."
        }
    }

    // MARK: Your genres

    /// The genres the person reads most, from their Read and Currently Reading
    /// shelves. Saved, so the section shows on the first frame.
    private(set) var yourGenres: [String] = UserDefaults.standard.stringArray(forKey: "folio.discover.yourGenres") ?? []
    private var genresLoadedFor: String?

    /// Too broad to be useful as a pick.
    private static let broadGenres: Set<String> = ["fiction", "nonfiction", "non-fiction", "adult", "general"]

    func loadYourGenres(from hardcover: HardcoverClient) async {
        guard let user = hardcover.user else { return }
        let marker = "\(user.id)-\(hardcover.revision)"
        guard genresLoadedFor != marker else { return }
        genresLoadedFor = marker
        do {
            let d = try await hardcover.query("""
            query YourGenres($uid: Int!) {
              user_books(where: {user_id: {_eq: $uid}, status_id: {_in: [2, 3]}}, order_by: {updated_at: desc}, limit: 300) { book { cached_tags } }
            }
            """, ["uid": user.id])
            var counts: [String: Int] = [:]
            var firstSeen: [String: Int] = [:]
            for (index, entry) in d["user_books"].array.enumerated() {
                // A book's first few genres describe it; the long tail is noise.
                for name in HardcoverClient.genreNames(entry["book"]["cached_tags"]).prefix(4)
                where !Self.broadGenres.contains(name.lowercased()) {
                    counts[name, default: 0] += 1
                    if firstSeen[name] == nil { firstSeen[name] = index }
                }
            }
            let top = counts.filter { $0.value >= 2 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : firstSeen[$0.key, default: 0] < firstSeen[$1.key, default: 0] }
                .prefix(8).map(\.key)
            yourGenres = top
            UserDefaults.standard.set(top, forKey: "folio.discover.yourGenres")
            FolioLog.log("Your genres: \(top.joined(separator: ", "))", "discover")
        } catch {
            genresLoadedFor = nil
            FolioLog.log("Your genres failed: \(error.localizedDescription)", "discover")
        }
    }

    // MARK: Disk cache

    private struct StoredBook: Codable {
        var id: Int, title: String, authors: String, imageURL: URL?
        var year: Int?, pages: Int?, rating: Double?, ratingsCount: Int?, slug: String?

        init(_ b: HCBook) {
            id = b.id; title = b.title; authors = b.authors; imageURL = b.imageURL; year = b.year
            pages = b.pages; rating = b.rating; ratingsCount = b.ratingsCount; slug = b.slug
        }

        var value: HCBook {
            HCBook(id: id, title: title, authors: authors, imageURL: imageURL, year: year, pages: pages,
                   rating: rating, ratingsCount: ratingsCount, description: nil, slug: slug)
        }
    }

    private struct Stored: Codable {
        var savedAt: Date
        var books: [String: [StoredBook]]
    }

    nonisolated private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-discover-rows.json")
    }

    private static func readCache() -> Stored? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    private static func writeCache(books: [String: [HCBook]], savedAt: Date) {
        let stored = Stored(savedAt: savedAt, books: books.mapValues { $0.map(StoredBook.init) })
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(stored) { try? data.write(to: cacheURL, options: .atomic) }
        }
    }
}
