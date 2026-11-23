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
        guard let read = try? await hardcover.shelf(.read) else {
            loadedFor = nil
            return
        }
        FolioSync.adopt(read)
        hardcoverIDs = Set(read.map(\.book.id))
        hardcoverKeys = Set(read.map { BookMatch.key(author: $0.book.authors, title: $0.book.title) })
        save(userID: user.id)
    }

    /// Record a status change right away, before Hardcover is asked again.
    func set(_ book: HCBook, read: Bool) {
        let key = BookMatch.key(author: book.authors, title: book.title)
        if read {
            if book.id > 0 { hardcoverIDs.insert(book.id) }
            hardcoverKeys.insert(key)
        } else {
            hardcoverIDs.remove(book.id)
            hardcoverKeys.remove(key)
        }
        save(userID: HardcoverClient.shared.user?.id)
    }

    func isRead(id: Int?, title: String, author: String, library: LibraryStore = .shared) -> Bool {
        isRead(id: id, title: title, author: author, local: localIndex(library))
    }

    private func isRead(id: Int?, title: String, author: String, local: (ids: Set<Int>, keys: Set<String>)) -> Bool {
        if let id, id > 0, hardcoverIDs.contains(id) || local.ids.contains(id) { return true }
        let key = BookMatch.key(author: author, title: title)
        return hardcoverKeys.contains(key) || local.keys.contains(key)
    }

    @ObservationIgnored private var localCache: (version: Int, ids: Set<Int>, keys: Set<String>)?

    /// Finished library books and Goodreads read entries, rebuilt only after the library
    /// saves: Library asks once per tile, and rescanning every book each time was
    /// quadratic for large libraries.
    private func localIndex(_ library: LibraryStore) -> (ids: Set<Int>, keys: Set<String>) {
        if let cache = localCache, cache.version == library.changeCount { return (cache.ids, cache.keys) }
        let finished = library.books.filter { $0.status == .finished }
        let tracked = library.data.tracked.filter { $0.status == .read }
        let ids = Set(finished.compactMap(\.hardcoverBookID))
        let keys = Set(finished.map { BookMatch.key(author: $0.author, title: $0.title) }
                       + tracked.map { BookMatch.key(author: $0.author, title: $0.title) })
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
        return books.filter { !isRead(id: $0.id, title: $0.title, author: $0.authors, local: local) }
    }

    private func save(userID: Int?) {
        let stored = Stored(ids: Array(hardcoverIDs), keys: Array(hardcoverKeys), userID: userID)
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}
