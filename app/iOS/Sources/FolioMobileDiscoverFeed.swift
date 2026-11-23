import Foundation
import Observation

/// Curated Hardcover lists for the iOS Discover tab.
extension HardcoverClient {
    /// Books Hardcover readers have shelved most, optionally filtered.
    func popularBooks(where filter: String = "", limit: Int = 24) async throws -> [HCBook] {
        let clause = filter.isEmpty ? "" : "where: {\(filter)}, "
        let d = try await query("query Popular { books(\(clause)order_by: {users_count: desc}, limit: \(limit)) { \(Self.bookFields) } }")
        return d["books"].array.compactMap(HCBook.from(book:))
    }

    /// The best-rated books among those with plenty of ratings.
    func acclaimedBooks(limit: Int = 24) async throws -> [HCBook] {
        let d = try await query("""
        query Acclaimed { books(where: {ratings_count: {_gt: 2000}}, order_by: {rating: desc}, limit: \(limit)) { \(Self.bookFields) } }
        """)
        return d["books"].array.compactMap(HCBook.from(book:))
    }

    /// Popular books carrying a Hardcover genre tag. Falls back to the cached
    /// tag list when the tag relation can't be queried.
    func genreBooks(_ genre: String, limit: Int = 20) async throws -> [HCBook] {
        if let d = try? await query("""
        query Genre($g: String!) { books(where: {taggings: {tag: {tag: {_eq: $g}}}}, order_by: {users_count: desc}, limit: \(limit)) { \(Self.bookFields) } }
        """, ["g": genre]) {
            let books = d["books"].array.compactMap(HCBook.from(book:))
            if !books.isEmpty { return books }
        }
        let d = try await query("""
        query GenreCached($tags: jsonb!) { books(where: {cached_tags: {_contains: $tags}}, order_by: {users_count: desc}, limit: \(limit)) { \(Self.bookFields) } }
        """, ["tags": ["Genre": [["tag": genre]]]])
        return d["books"].array.compactMap(HCBook.from(book:))
    }
}

/// The Discover tab's rows: one short title each, loaded in parallel. A row
/// that fails or comes back empty is left out rather than shown broken.
@Observable
@MainActor
final class FolioMobileDiscoverFeed {
    struct Row: Identifiable {
        let id: String
        let title: String
        let books: [HCBook]
    }

    static let genres = ["Fantasy", "Science Fiction", "Mystery", "Romance",
                         "Historical Fiction", "Horror", "Nonfiction", "Classics"]

    private(set) var rows: [Row] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?

    private enum Kind: Sendable {
        case trending, newThisYear, acclaimed, allTime, genre(String)
    }

    func load(from hardcover: HardcoverClient, force: Bool = false) async {
        guard hardcover.isConnected else { rows = []; loaded = false; return }
        if loaded && !force { return }
        loading = true
        defer { loading = false }

        let year = Calendar.current.component(.year, from: .now)
        var plan: [(String, String, Kind)] = [
            ("trending", "Trending now", .trending),
            ("new", "New this year", .newThisYear),
            ("acclaimed", "Acclaimed", .acclaimed),
            ("alltime", "All-time favorites", .allTime)
        ]
        plan += Self.genres.map { ("genre-\($0)", $0, .genre($0)) }

        var results: [String: [HCBook]] = [:]
        var firstError: String?
        await withTaskGroup(of: (String, Result<[HCBook], Error>).self) { group in
            for (id, _, kind) in plan {
                group.addTask { @MainActor in
                    do {
                        let books: [HCBook]
                        switch kind {
                        case .trending: books = try await hardcover.trending()
                        case .newThisYear: books = try await hardcover.popularBooks(where: "release_year: {_eq: \(year)}")
                        case .acclaimed: books = try await hardcover.acclaimedBooks()
                        case .allTime: books = try await hardcover.popularBooks()
                        case .genre(let name): books = try await hardcover.genreBooks(name)
                        }
                        return (id, .success(books))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }
            for await (id, result) in group {
                switch result {
                case .success(let books): results[id] = books
                case .failure(let failure): if firstError == nil { firstError = failure.localizedDescription }
                }
            }
        }
        guard !Task.isCancelled else { return }

        // Keep each book in one row only, in the order the rows appear.
        var seen = Set<Int>()
        rows = plan.compactMap { id, title, _ in
            let books = (results[id] ?? []).filter { seen.insert($0.id).inserted }
            return books.count >= 3 ? Row(id: id, title: title, books: Array(books.prefix(16))) : nil
        }
        error = rows.isEmpty ? (firstError ?? "Hardcover didn't return any books. Try again later.") : nil
        loaded = true
    }
}
