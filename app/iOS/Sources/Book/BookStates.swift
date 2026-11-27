import Foundation
import Observation

/// Your status and rating for one book, the one place both are decided.
/// Each field keeps when you set it, and whether a service has since shown the
/// same value back (confirmed). An unconfirmed value is yours and still on its
/// way out; a confirmed one follows the service when it changes there.
struct FolioBookState: Codable, Equatable {
    var status: HCStatus?
    var statusAt: Date?
    var statusConfirmed = false
    var rating: Double?
    var ratingAt: Date?
    var ratingConfirmed = false

    var isEmpty: Bool { statusAt == nil && ratingAt == nil }

    /// Each field from whichever side set it last.
    func merged(with other: FolioBookState) -> FolioBookState {
        var out = self
        if (other.statusAt ?? .distantPast) > (statusAt ?? .distantPast) {
            out.status = other.status
            out.statusAt = other.statusAt
            out.statusConfirmed = false
        }
        if (other.ratingAt ?? .distantPast) > (ratingAt ?? .distantPast) {
            out.rating = other.rating
            out.ratingAt = other.ratingAt
            out.ratingConfirmed = false
        }
        return out
    }
}

/// The single source of truth for what you've read and how you rated it, for
/// every book: in the library or not, on Hardcover or not. The book page, the
/// library, Folio Sync and the reading services all read and write it here;
/// Hardcover, Goodreads and the others are copies kept in step from it.
@Observable
@MainActor
final class FolioBookStates {
    static let shared = FolioBookStates()
    private static let defaultsKey = "folio.bookStates"
    private static let oldRatingsKey = "folio.myRatings"

    private(set) var entries: [String: FolioBookState] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([String: FolioBookState].self, from: data) {
            entries = saved
        }
        // Ratings kept before 1.0.135 become entries, as old as can be so any
        // other device's newer rating wins.
        if let old = UserDefaults.standard.dictionary(forKey: Self.oldRatingsKey) as? [String: Double] {
            for (key, value) in old where entries[key]?.ratingAt == nil {
                var state = entries[key] ?? FolioBookState()
                state.rating = value
                state.ratingAt = Date(timeIntervalSince1970: 1)
                entries[key] = state
            }
            UserDefaults.standard.removeObject(forKey: Self.oldRatingsKey)
            persist(announce: false)
        }
    }

    // MARK: Keys

    /// "hc-<id>" first when Hardcover knows the book, then its author and title.
    static func keys(hardcoverID: Int?, title: String, author: String) -> [String] {
        var out = ["t-" + BookMatch.key(author: author, title: title)]
        if let id = hardcoverID, id > 0 { out.insert("hc-\(id)", at: 0) }
        return out
    }

    static func keys(for book: HCBook) -> [String] {
        keys(hardcoverID: book.id, title: book.title, author: book.authors)
    }

    private func state(_ keys: [String]) -> (key: String, state: FolioBookState)? {
        keys.lazy.compactMap { k in self.entries[k].map { (k, $0) } }.first
    }

    // MARK: Reading

    /// The status you chose, or nil when you never chose one here. `.some(nil)`
    /// means you cleared it.
    func status(for book: HCBook) -> HCStatus?? {
        status(keys: Self.keys(for: book))
    }

    func status(keys: [String]) -> HCStatus?? {
        let found = keys.compactMap { self.entries[$0] }.filter { $0.statusAt != nil }
            .max { ($0.statusAt ?? .distantPast) < ($1.statusAt ?? .distantPast) }
        guard let found else { return nil }
        return .some(found.status)
    }

    /// Your exact rating, or nil when you never rated it here.
    func rating(for book: HCBook) -> Double?? {
        let found = Self.keys(for: book).compactMap { self.entries[$0] }.filter { $0.ratingAt != nil }
            .max { ($0.ratingAt ?? .distantPast) < ($1.ratingAt ?? .distantPast) }
        guard let found else { return nil }
        return .some(found.rating)
    }

    // MARK: Writing

    func setStatus(_ status: HCStatus?, for book: HCBook) {
        setStatus(status, keys: Self.keys(for: book))
        FolioReadBooks.shared.set(book, status: status)
    }

    func setStatus(_ status: HCStatus?, keys: [String], at: Date = Date()) {
        guard let primary = keys.first else { return }
        if let current = self.status(keys: keys), current == status { return }
        for k in keys.dropFirst() where entries[k]?.statusAt != nil {
            entries[k]?.statusAt = nil
            entries[k]?.status = nil
        }
        var s = entries[primary] ?? FolioBookState()
        s.status = status
        s.statusAt = at
        s.statusConfirmed = false
        entries[primary] = s
        persist()
    }

    func setRating(_ rating: Double?, for book: HCBook) {
        let keys = Self.keys(for: book)
        guard let primary = keys.first else { return }
        for k in keys.dropFirst() where entries[k]?.ratingAt != nil {
            entries[k]?.ratingAt = nil
            entries[k]?.rating = nil
        }
        var s = entries[primary] ?? FolioBookState()
        s.rating = rating.map(FolioMyRatings.quarter)
        s.ratingAt = Date()
        s.ratingConfirmed = false
        entries[primary] = s
        persist()
    }

    // MARK: Hardcover

    /// Hardcover's shelves, as just read. A value you set here and Hardcover
    /// now shows is confirmed; a confirmed value that changed on Hardcover
    /// (on the website, say) is taken; a value not yet confirmed is yours and
    /// is sent again.
    func adoptHardcover(_ shelf: [HCUserBook], hardcover: HardcoverClient = .shared) {
        var anyChanged = false
        for item in shelf {
            var changed = false
            let key = "hc-\(item.book.id)"
            let keys = Self.keys(for: item.book)
            let existing = state(keys)
            var s = existing?.state ?? FolioBookState()
            let at = Self.hardcoverDate(item.updatedAt) ?? Date()

            if s.statusAt == nil || s.statusConfirmed {
                if s.status != item.status || s.statusAt == nil {
                    s.status = item.status
                    s.statusAt = s.statusAt.map { max($0, at) } ?? at
                    changed = true
                    FolioReadBooks.shared.set(item.book, status: item.status)
                }
                if !s.statusConfirmed { s.statusConfirmed = true; changed = true }
            } else if s.status == item.status {
                s.statusConfirmed = true
                changed = true
            } else if let mine = s.status, hardcover.isConnected {
                Task { _ = await hardcover.setStatus(bookID: item.book.id, status: mine, editionID: item.editionID) }
            }

            let theirs = item.rating.flatMap { $0 > 0 ? $0 : nil }
            if s.ratingAt == nil || s.ratingConfirmed {
                if s.ratingAt == nil || s.rating.map(FolioMyRatings.half) != theirs {
                    if theirs != nil || s.ratingAt != nil {
                        s.rating = theirs
                        s.ratingAt = s.ratingAt.map { max($0, at) } ?? at
                        changed = true
                    }
                }
                if s.ratingAt != nil, !s.ratingConfirmed { s.ratingConfirmed = true; changed = true }
            } else if s.rating.map(FolioMyRatings.half) == theirs {
                s.ratingConfirmed = true
                changed = true
            } else if hardcover.isConnected {
                let sent = s.rating.map(FolioMyRatings.half)
                Task { await hardcover.setRating(userBookID: item.id, rating: sent) }
            }

            if changed {
                if let old = existing?.key, old != key { entries[old] = nil }
                entries[key] = s
                anyChanged = true
            }
        }
        if anyChanged { persist() }
    }

    private static func hardcoverDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    // MARK: Folio Sync

    var syncJSON: String? {
        // Confirmation is per device: only the values and their times travel.
        FolioSyncedJSON.encode(entries.mapValues { s -> FolioBookState in
            var t = s
            t.statusConfirmed = false
            t.ratingConfirmed = false
            return t
        })
    }

    /// Another device's states, merged book by book and field by field.
    func adoptSynced(_ json: String) {
        guard let theirs: [String: FolioBookState] = FolioSyncedJSON.decode(json) else { return }
        var changed = false
        for (key, other) in theirs {
            let mine = entries[key] ?? FolioBookState()
            let merged = mine.merged(with: other)
            guard merged != mine else { continue }
            entries[key] = merged
            changed = true
            if merged.statusAt != mine.statusAt { applyToLibrary(key: key, status: merged.status) }
        }
        if changed { persist(announce: false) }
    }

    /// A status from another device reaches the library copy of that book too.
    private func applyToLibrary(key: String, status: HCStatus?) {
        let library = LibraryStore.shared
        guard let book = library.books.first(where: { b in
            Self.keys(hardcoverID: b.hardcoverBookID, title: b.title, author: b.author).contains(key)
        }) else { return }
        let local = status?.local ?? ReadingStatus.none
        if book.status != local { library.setStatus(book.id, local) }
    }

    // MARK: Library

    /// Called for every status change of a library book (reading it, finishing
    /// it, choosing a shelf), so the library and this store never disagree.
    func libraryStatusChanged(_ book: LocalBook) {
        let keys = Self.keys(hardcoverID: book.hardcoverBookID, title: book.title, author: book.author)
        setStatus(book.status.hardcover, keys: keys, at: book.statusChangedAt ?? Date())
    }

    private func persist(announce: Bool = true) {
        entries = entries.filter { !$0.value.isEmpty }
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        if announce { FolioSyncedValues.changed() }
    }
}
