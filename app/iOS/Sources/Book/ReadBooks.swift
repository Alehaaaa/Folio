import Foundation
import Observation

/// Books the reader has already finished, from every source: Hardcover's Read
/// shelf, Goodreads' read shelf and finished library files. Rows that suggest
/// what to read next (Home, Discover, search, recommendations) leave them out,
/// together with books being read, paused or abandoned.
///
/// A book counts in any language: besides its Hardcover id and its title, each
/// work is known by its most-read edition titles (translations included) and its
/// numbered places in series, so "El nombre del viento" is hidden once "The Name
/// of the Wind" is read, even when Hardcover keeps the translation as its own book.
@Observable
@MainActor
final class FolioReadBooks {
    static let shared = FolioReadBooks()
    private static let defaultsKey = "folio.readBooks"

    private struct Stored: Codable {
        var ids: [Int]
        var keys: [String]
        var userID: Int?
        var activeIDs: [Int]? = nil
        var activeKeys: [String]? = nil
    }

    /// The keys a set of works is known by.
    struct Known: Codable {
        var keys: Set<String> = []
        var titles: Set<String> = []
        var places: Set<String> = []

        mutating func formUnion(_ other: Known) {
            keys.formUnion(other.keys); titles.formUnion(other.titles); places.formUnion(other.places)
        }
    }

    /// Editions and series places of works, saved between launches.
    private struct Identities: Codable {
        var works: [Int: HCWorkIdentity] = [:]
        var known: Known = Known()
    }

    /// Hardcover's Read shelf, saved so filters apply on the first frame.
    private(set) var hardcoverIDs: Set<Int> = []
    private(set) var hardcoverKeys: Set<String> = []
    /// Hardcover books being read, paused or abandoned: not recommended, not marked read.
    private(set) var activeIDs: Set<Int> = []
    private(set) var activeKeys: Set<String> = []
    /// Every edition title and series place of the books above and of the library's.
    private(set) var siblings = Known()
    /// Bumped when series places of listed books arrive, so rows filter again.
    private(set) var placesRevision = 0

    private var loadedFor: String?
    @ObservationIgnored private var works: [Int: HCWorkIdentity] = [:]
    @ObservationIgnored private var candidatePlaces: [Int: [HCWorkIdentity.Place]] = [:]
    @ObservationIgnored private var pendingPlaces: Set<Int> = []
    @ObservationIgnored private var placesTask: Task<Void, Never>?

    nonisolated private static var identitiesFile: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-read-identities.json")
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode(Stored.self, from: data) {
            hardcoverIDs = Set(stored.ids)
            hardcoverKeys = Set(stored.keys)
            activeIDs = Set(stored.activeIDs ?? [])
            activeKeys = Set(stored.activeKeys ?? [])
        }
        if let data = try? Data(contentsOf: Self.identitiesFile),
           let saved = try? JSONDecoder().decode(Identities.self, from: data) {
            works = saved.works
            siblings = saved.known
        }
    }

    /// Reloads the shelves when the account or its revision changes.
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
        hardcoverKeys = Set(read.flatMap(Self.keys(of:)))
        var entries = read
        if let active = try? await hardcover.shelfEntries([.reading, .paused, .dnf]),
           hardcover.user?.id == user.id {
            activeIDs = Set(active.map(\.book.id))
            activeKeys = Set(active.flatMap(Self.keys(of:)))
            entries += active
        }
        save(userID: user.id)
        await refreshSiblings(from: hardcover, entries: entries)
    }

    private static func keys(of entry: HCUserBook) -> [String] {
        matchKeys(author: entry.book.authors, title: entry.book.title)
            + (entry.workTitle.map { matchKeys(author: entry.book.authors, title: $0) } ?? [])
    }

    /// Looks up the editions and series places of works not seen before, then
    /// rebuilds the keys they add, away from the main thread.
    private func refreshSiblings(from hardcover: HardcoverClient, entries: [HCUserBook]) async {
        let library = LibraryStore.shared
        var bylines: [Int: String] = [:]
        for book in library.books where book.status == .finished || book.status == .reading {
            if let id = book.hardcoverBookID { bylines[id] = book.author }
        }
        for item in library.data.tracked where [.read, .reading, .paused, .dnf].contains(item.status) {
            if let id = item.hardcoverBookID { bylines[id] = item.author }
        }
        let ids = hardcoverIDs.union(activeIDs).union(bylines.keys)
        let missing = ids.filter { works[$0] == nil }
        if !missing.isEmpty, let found = try? await hardcover.workIdentities(bookIDs: Array(missing).sorted()) {
            works.merge(found) { _, new in new }
        }
        let wanted = works.filter { ids.contains($0.key) }
        // Credit each work to its own author; the Hardcover entries know it best.
        for entry in entries { bylines[entry.book.id] = entry.book.authors }
        let snapshot = wanted
        let names = bylines
        let known = await Task.detached(priority: .utility) {
            var known = Known()
            for (id, work) in snapshot {
                let author = names[id] ?? ""
                for title in work.titles {
                    known.keys.formUnion(Self.matchKeys(author: author, title: title))
                    known.titles.insert(BookMatch.key(author: "", title: title))
                }
                known.places.formUnion(Self.placeKeys(work.places, author: author))
            }
            return known
        }.value
        siblings = known
        works = wanted
        let saved = Identities(works: wanted, known: known)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(saved) { try? data.write(to: Self.identitiesFile, options: .atomic) }
        }
    }

    /// Record a status change right away, before Hardcover is asked again.
    func set(_ book: HCBook, read: Bool) {
        set(book, status: read ? .read : nil)
    }

    func set(_ book: HCBook, status: HCStatus?) {
        let keys = Self.matchKeys(author: book.authors, title: book.title)
            + (book.editionTitle.map { Self.matchKeys(author: book.authors, title: $0) } ?? [])
        hardcoverIDs.remove(book.id)
        hardcoverKeys.subtract(keys)
        activeIDs.remove(book.id)
        activeKeys.subtract(keys)
        switch status {
        case .read:
            if book.id > 0 { hardcoverIDs.insert(book.id) }
            hardcoverKeys.formUnion(keys)
        case .reading, .paused, .dnf:
            if book.id > 0 { activeIDs.insert(book.id) }
            activeKeys.formUnion(keys)
        case .wantToRead, nil:
            break
        }
        save(userID: HardcoverClient.shared.user?.id)
    }

    func isRead(id: Int?, title: String, author: String, library: LibraryStore = .shared) -> Bool {
        isRead(id: id, title: title, author: author, local: localIndex(library))
    }

    private func isRead(id: Int?, title: String, author: String, local: LocalIndex) -> Bool {
        if let id, id > 0, hardcoverIDs.contains(id) || local.readIDs.contains(id) { return true }
        return Self.matchKeys(author: author, title: title).contains {
            hardcoverKeys.contains($0) || local.readKeys.contains($0)
        }
    }

    nonisolated private static func matchKeys(author: String, title: String) -> [String] {
        let credited = FolioAuthorNames.split(author).filter { $0.split(whereSeparator: \.isWhitespace).count > 1 }
        return ([author] + credited).map { BookMatch.key(author: $0, title: title) }
    }

    /// A numbered place in a series: by series id, which translated copies share,
    /// and by series name with the author's surname, for copies filed under a twin series.
    nonisolated private static func placeKeys(_ places: [HCWorkIdentity.Place], author: String) -> Set<String> {
        let surname = BookAutoMatch.words(FolioAuthorNames.split(author).first ?? author).last ?? ""
        var out = Set<String>()
        for place in places {
            let position = String(format: "%g", place.position)
            if let id = place.seriesID { out.insert("s\(id)#\(position)") }
            let filler: Set<String> = ["the", "saga", "series", "trilogy", "cycle", "chronicles", "sequence", "books", "novels", "universe"]
            let name = BookAutoMatch.words(place.name).filter { !filler.contains($0) }.joined(separator: " ")
            if !name.isEmpty, !surname.isEmpty { out.insert("n\(name)#\(position)#\(surname)") }
        }
        return out
    }

    private struct LocalIndex {
        var readIDs: Set<Int> = []
        var readKeys: Set<String> = []
        var activeIDs: Set<Int> = []
        var activeKeys: Set<String> = []
    }

    @ObservationIgnored private var localCache: (version: Int, index: LocalIndex)?

    /// Finished and current library books and Goodreads entries, rebuilt only after the
    /// library saves: Library asks once per tile, and rescanning every book each time was
    /// quadratic for large libraries.
    private func localIndex(_ library: LibraryStore) -> LocalIndex {
        if let cache = localCache, cache.version == library.changeCount { return cache.index }
        var index = LocalIndex()
        let finished = library.books.filter { $0.status == .finished }
        let tracked = library.data.tracked.filter { $0.status == .read }
        index.readIDs = Set(finished.compactMap(\.hardcoverBookID) + tracked.compactMap(\.hardcoverBookID))
        index.readKeys = Set(finished.flatMap { Self.matchKeys(author: $0.author, title: $0.title) }
                             + tracked.flatMap { Self.matchKeys(author: $0.author, title: $0.title) })
        let reading = library.books.filter { $0.status == .reading }
        let current = library.data.tracked.filter { [.reading, .paused, .dnf].contains($0.status) }
        index.activeIDs = Set(reading.compactMap(\.hardcoverBookID) + current.compactMap(\.hardcoverBookID))
        index.activeKeys = Set(reading.flatMap { Self.matchKeys(author: $0.author, title: $0.title) }
                               + current.flatMap { Self.matchKeys(author: $0.author, title: $0.title) })
        localCache = (library.changeCount, index)
        return index
    }

    func isRead(_ book: HCBook) -> Bool { isRead(id: book.id, title: book.title, author: book.authors) }

    func isRead(_ book: LocalBook) -> Bool {
        book.status == .finished || isRead(id: book.hardcoverBookID, title: book.title, author: book.author)
    }

    /// The books of a list the reader hasn't read and isn't reading, in order.
    /// Search results pass `recommendations: false`: they only drop the exact
    /// books on the Read shelf, so a search still finds the book being read or
    /// another language's edition of a read one.
    func unread(_ books: [HCBook], recommendations: Bool = true) -> [HCBook] {
        // Check the library once per list, not once per book.
        let local = localIndex(.shared)
        guard recommendations else {
            return books.filter { book in
                guard !isRead(id: book.id, title: book.title, author: book.authors, local: local) else { return false }
                return book.editionTitle.map { !isRead(id: nil, title: $0, author: book.authors, local: local) } ?? true
            }
        }
        _ = placesRevision
        let checkPlaces = !siblings.places.isEmpty
        var unknown: [Int] = []
        let kept = books.filter { book in
            if book.id > 0, hardcoverIDs.contains(book.id) || activeIDs.contains(book.id)
                || local.readIDs.contains(book.id) || local.activeIDs.contains(book.id) { return false }
            var titles = [book.title]
            if let edition = book.editionTitle { titles.append(edition) }
            titles += book.alternateTitles ?? []
            for title in titles {
                let keys = Self.matchKeys(author: book.authors, title: title)
                if keys.contains(where: {
                    hardcoverKeys.contains($0) || activeKeys.contains($0) || siblings.keys.contains($0)
                        || local.readKeys.contains($0) || local.activeKeys.contains($0)
                }) { return false }
                // Translated copies on Hardcover often carry no author.
                if book.authors.isEmpty, siblings.titles.contains(BookMatch.key(author: "", title: title)) { return false }
            }
            guard checkPlaces, book.id > 0 else { return true }
            if let places = candidatePlaces[book.id] {
                return places.isEmpty || Self.placeKeys(places, author: book.authors).isDisjoint(with: siblings.places)
            }
            unknown.append(book.id)
            return true
        }
        if !unknown.isEmpty { lookUpPlaces(unknown) }
        return kept
    }

    /// Asks Hardcover, in batches, where listed books sit in their series; rows
    /// filter again once the answer arrives.
    private func lookUpPlaces(_ ids: [Int]) {
        pendingPlaces.formUnion(ids)
        guard placesTask == nil else { return }
        placesTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            while let self, !self.pendingPlaces.isEmpty {
                let batch = Array(self.pendingPlaces.prefix(100))
                self.pendingPlaces.subtract(batch)
                guard HardcoverClient.shared.isConnected,
                      let found = try? await HardcoverClient.shared.seriesPlaces(forBooks: batch) else {
                    for id in batch { self.candidatePlaces[id] = [] }
                    continue
                }
                for id in batch { self.candidatePlaces[id] = found[id] ?? [] }
                self.placesRevision &+= 1
            }
            self?.placesTask = nil
        }
    }

    private func save(userID: Int?) {
        let stored = Stored(ids: Array(hardcoverIDs), keys: Array(hardcoverKeys), userID: userID,
                            activeIDs: Array(activeIDs), activeKeys: Array(activeKeys))
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: Self.defaultsKey) }
    }
}
