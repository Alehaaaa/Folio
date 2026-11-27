import Foundation
import Observation

/// Hardcover supplies the "For you" row on Home: this model never invents
/// book records or presents trending books as personal recommendations.
/// Without a recommendation API, "More by your authors" is explicitly based
/// on authors found in the reader's own library and Hardcover shelves.
@Observable
@MainActor
final class FolioMobileHomeRecommendations {
    private(set) var byYourAuthors: [HCBook] = []
    private(set) var authorNames: [String] = []
    private(set) var loading = false
    private(set) var loaded = false
    private(set) var error: String?

    private var generation = UUID()

    func load(from hardcover: HardcoverClient, books: [LocalBook], tracked: [TrackedBook]) async {
        let run = UUID()
        generation = run
        error = nil
        loaded = false

        guard hardcover.isConnected else {
            byYourAuthors = []
            authorNames = []
            loading = false
            return
        }
        // Keep what is on screen, or show the last saved row, while refreshing.
        let userID = hardcover.user?.id ?? -1
        if byYourAuthors.isEmpty, let cached = FolioMobileHomeCache.forYou(for: userID) {
            byYourAuthors = cached
        }
        loading = true

        var knownIDs = Set(books.compactMap(\.hardcoverBookID))
        knownIDs.formUnion(tracked.compactMap(\.hardcoverBookID))
        var knownBooks = Set(books.map { BookMatch.key(author: $0.author, title: $0.title) })
        knownBooks.formUnion(tracked.map { BookMatch.key(author: $0.author, title: $0.title) })

        // Reading and highly rated books provide a concrete preference signal.
        // Want-to-read entries are weaker evidence than books actually enjoyed.
        var preferences: [String: (display: String, score: Double)] = [:]
        func prefer(_ author: String, score: Double) {
            let name = author.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = BookAutoMatch.words(name).sorted().joined(separator: " ")
            guard key.count > 2, score > 0 else { return }
            let previous = preferences[key]?.score ?? 0
            preferences[key] = (preferences[key]?.display ?? name, previous + score)
        }

        for local in books {
            let score: Double
            switch local.status {
            case .finished: score = 5
            case .reading: score = 4
            case .wantToRead: score = 1
            case .none: score = local.lastOpenedAt == nil ? 0.5 : 2
            }
            prefer(local.author, score: score)
        }

        for item in tracked {
            let score = item.rating >= 4 ? 5.0 : item.rating >= 3 ? 2.0 :
                item.status == .reading ? 3.0 : item.status == .read ? 1.5 : 0.5
            prefer(item.author, score: score)
        }

        var problems: [String] = []
        do {
            let shelf = try await hardcover.allUserBooks()
            guard generation == run, !Task.isCancelled else { return }
            for item in shelf {
                knownIDs.insert(item.book.id)
                knownBooks.insert(BookMatch.key(author: item.book.authors, title: item.book.title))
                let score = (item.rating ?? 0) >= 4 ? 6.0 :
                    item.status == .reading ? 4.0 : item.status == .read ? 2.0 :
                    item.status == .wantToRead ? 0.5 : 0.0
                prefer(item.book.authors, score: score)
            }
        } catch {
            problems.append("Your Hardcover shelves could not be loaded: \(error.localizedDescription)")
        }
        guard generation == run, !Task.isCancelled else { return }

        func notInLibrary(_ book: HCBook) -> Bool {
            !knownIDs.contains(book.id) &&
                !knownBooks.contains(BookMatch.key(author: book.authors, title: book.title)) &&
                FolioBookOverrides.shared.libraryCopy(of: book) == nil
        }

        let authors = preferences.values
            .sorted { $0.score == $1.score ? $0.display < $1.display : $0.score > $1.score }
            .prefix(2)
            .map(\.display)

        // Bounded, explicit author searches; avoid broad fuzzy matches and
        // pretend genre inference from unavailable Hardcover metadata.
        var authorGroups: [[HCBook]] = []
        var contributingAuthors: [String] = []
        for author in authors {
            do {
                let matches = try await FolioOpenLibrary.booksBy(author: author)
                guard generation == run, !Task.isCancelled else { return }
                let matching = matches.filter {
                    Self.matchesAuthor(author, in: $0.authors) && notInLibrary($0)
                }
                if !matching.isEmpty {
                    authorGroups.append(Array(matching.prefix(10)))
                    contributingAuthors.append(author)
                }
            } catch {
                problems.append("Could not search books by \(author): \(error.localizedDescription)")
            }
        }
        guard generation == run, !Task.isCancelled else { return }

        // Interleave the authors so one prolific writer cannot fill the shelf.
        var ids = Set<Int>()
        var chosen: [HCBook] = []
        let maxGroupCount = authorGroups.map(\.count).max() ?? 0
        for index in 0..<maxGroupCount {
            for group in authorGroups where group.indices.contains(index) {
                let candidate = group[index]
                if ids.insert(candidate.id).inserted { chosen.append(candidate) }
            }
            if chosen.count >= 12 { break }
        }
        byYourAuthors = Array(chosen.prefix(12))
        FolioImageCache.shared.prefetch(byYourAuthors.compactMap(\.imageURL))
        authorNames = contributingAuthors
        if problems.isEmpty || !byYourAuthors.isEmpty {
            FolioMobileHomeCache.saveForYou(userID: userID, books: byYourAuthors)
        }
        error = byYourAuthors.isEmpty ?
            (problems.first ?? "Hardcover did not return any new books. Try again later.") : nil
        loaded = true
        loading = false
    }

    /// Accept an exact author (including reversed name order) or an exact
    /// contiguous author name among multiple credited contributors.
    private static func matchesAuthor(_ wanted: String, in listed: String) -> Bool {
        if BookAutoMatch.sameAuthor(wanted, listed) { return true }
        let needle = BookAutoMatch.words(wanted)
        let haystack = BookAutoMatch.words(listed)
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        if needle.count == 1 { return haystack == needle }
        for index in 0...(haystack.count - needle.count) {
            if Array(haystack[index..<(index + needle.count)]) == needle { return true }
        }
        return false
    }
}
