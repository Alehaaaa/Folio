import Foundation
import Observation

/// Books the reader has already finished, from every source: Hardcover's Read
/// shelf, Goodreads' read shelf and finished library files. Rows that suggest
/// what to read next (Home, Discover, search, recommendations) leave them out.
@Observable
@MainActor
final class FolioReadBooks {
    static let shared = FolioReadBooks()
    private static let defaultsKey = "folio.readBooks"

    private struct Stored: Codable {
        var ids: [Int]
        var keys: [String]
        var userID: Int?
    }

    /// Hardcover's Read shelf, saved so filters apply on the first frame.
    private(set) var hardcoverIDs: Set<Int> = []
    private(set) var hardcoverKeys: Set<String> = []
    private var loadedFor: String?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            hardcoverIDs = Set(stored.ids)
            hardcoverKeys = Set(stored.keys)
        }
    }

    /// Reloads the Read shelf when the account or its revision changes.
    func refresh(from hardcover: HardcoverClient) async {
        guard let user = hardcover.user else { return }
        let marker = "\(user.id)-\(hardcover.revision)"
        guard loadedFor != marker else { return }
        loadedFor = marker
        guard let read = try? await hardcover.readHistory() else {
            if loadedFor == marker { loadedFor = nil }
            return
        }
        guard loadedFor == marker, hardcover.user?.id == user.id else { return }
        FolioSync.adopt(read)
        hardcoverIDs = Set(read.map(\.book.id))
        hardcoverKeys = Set(read.flatMap { entry in
            Self.matchKeys(author: entry.book.authors, title: entry.book.title)
                + (entry.workTitle.map { Self.matchKeys(author: entry.book.authors, title: $0) } ?? [])
        })
        save(userID: user.id)
    }

    /// Record a status change right away, before Hardcover is asked again.
    func set(_ book: HCBook, read: Bool) {
        let keys = Self.matchKeys(author: book.authors, title: book.title)
            + (book.editionTitle.map { Self.matchKeys(author: book.authors, title: $0) } ?? [])
        if read {
            if book.id > 0 { hardcoverIDs.insert(book.id) }
            hardcoverKeys.formUnion(keys)
        } else {
            hardcoverIDs.remove(book.id)
            hardcoverKeys.subtract(keys)
        }
        save(userID: HardcoverClient.shared.user?.id)
    }

    func isRead(id: Int?, title: String, author: String, library: LibraryStore = .shared) -> Bool {
        isRead(id: id, title: title, author: author, local: localIndex(library))
    }

    private func isRead(id: Int?, title: String, author: String, local: (ids: Set<Int>, keys: Set<String>)) -> Bool {
        if let id, id > 0, hardcoverIDs.contains(id) || local.ids.contains(id) { return true }
        return Self.matchKeys(author: author, title: title).contains {
            hardcoverKeys.contains($0) || local.keys.contains($0)
        }
    }

    private static func matchKeys(author: String, title: String) -> [String] {
        let credited = FolioAuthorNames.split(author).filter { $0.split(whereSeparator: \.isWhitespace).count > 1 }
        return ([author] + credited).map { BookMatch.key(author: $0, title: title) }
    }

    @ObservationIgnored private var localCache: (version: Int, ids: Set<Int>, keys: Set<String>)?

    /// Finished library books and Goodreads read entries, rebuilt only after the library
    /// saves: Library asks once per tile, and rescanning every book each time was
    /// quadratic for large libraries.
    private func localIndex(_ library: LibraryStore) -> (ids: Set<Int>, keys: Set<String>) {
        if let cache = localCache, cache.version == library.changeCount { return (cache.ids, cache.keys) }
        let finished = library.books.filter { $0.status == .finished }
        let tracked = library.data.tracked.filter { $0.status == .read }
        let ids = Set(finished.compactMap(\.hardcoverBookID) + tracked.compactMap(\.hardcoverBookID))
        let keys = Set(finished.flatMap { Self.matchKeys(author: $0.author, title: $0.title) }
                       + tracked.flatMap { Self.matchKeys(author: $0.author, title: $0.title) })
        localCache = (library.changeCount, ids, keys)
        return (ids, keys)
    }

    func isRead(_ book: HCBook) -> Bool { isRead(id: book.id, title: book.title, author: book.authors) }

    func isRead(_ book: LocalBook) -> Bool {
        book.status == .finished || isRead(id: book.hardcoverBookID, title: book.title, author: book.author)
    }

    /// The unread books of a list, in order.
    func unread(_ books: [HCBook]) -> [HCBook] {
        // Check the library once per list, not once per book.
        let local = localIndex(.shared)
        return books.filter { book in
            guard !isRead(id: book.id, title: book.title, author: book.authors, local: local) else { return false }
            return book.editionTitle.map {
                !isRead(id: nil, title: $0, author: book.authors, local: local)
            } ?? true
        }
    }

    private func save(userID: Int?) {
        let stored = Stored(ids: Array(hardcoverIDs), keys: Array(hardcoverKeys), userID: userID)
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}
