import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Edits to books outside the library

/// Changes the reader made to a Hardcover book they don't own a file for: kept on
/// this device and shown wherever the book appears, without touching Hardcover.
struct FolioBookOverride: Codable, Hashable {
    var title: String?
    var authors: String?
    var summary: String?
    var coverURL: URL?
    var publisher: String?
    var year: Int?
    var pages: Int?
    var language: String?
    var isbn: String?
    var series: String?
    var seriesIndex: Double?
    var genres: [String]?

    var isEmpty: Bool { self == FolioBookOverride() }
}

/// The edition a book page showed for a work you don't own a file for.
/// A book's real edition titles in one language, to show its best-formed one.
struct FolioEditionTitles: Codable, Hashable {
    var language: String
    var titles: [String]
    var fetched: Date
}

struct FolioShownEdition: Codable, Hashable {
    var editionID: Int?
    var title: String?
    var coverURL: URL?
}

@Observable
@MainActor
final class FolioBookOverrides {
    static let shared = FolioBookOverrides()
    private static let defaultsKey = "folio.bookOverrides"

    private static let shownKey = "folio.book.shownEditions"

    private(set) var items: [Int: FolioBookOverride] = [:]
    /// The edition each book page last showed, so every list shows that same one.
    private(set) var shown: [Int: FolioShownEdition] = [:]
    private static let editionTitlesKey = "folio.book.editionTitles.v2"
    /// Real edition titles of books in the reading language (see `bestTitle`).
    private var editionTitles: [String: [Int: FolioEditionTitles]] = [:]
    @ObservationIgnored private var pendingTitleIDs: [String: Set<Int>] = [:]
    @ObservationIgnored private var inFlightTitleIDs: [String: Set<Int>] = [:]
    @ObservationIgnored private var retryTitlesAfter: [String: [Int: Date]] = [:]
    @ObservationIgnored private var titleFetch: Task<Void, Never>?
    @ObservationIgnored private var matchKeys: [String: String] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.defaultsKey),
           let saved = try? JSONDecoder().decode([Int: FolioBookOverride].self, from: data) {
            items = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.shownKey),
           let saved = try? JSONDecoder().decode([Int: FolioShownEdition].self, from: data) {
            shown = saved
        }
        if let data = UserDefaults.standard.data(forKey: Self.editionTitlesKey) {
            if let saved = try? JSONDecoder().decode([String: [Int: FolioEditionTitles]].self, from: data) {
                editionTitles = saved

            }
        }
    }

    /// The book's title as its edition in the reading language is published:
    /// "The Way of Kings" and "CAMINO DE LOS REYES (EL ARCHIVO DE LAS TORMENTAS
    /// 1)" both show as "El camino de los reyes". Titles are picked among the
    /// book's real edition titles, never rewritten. They are fetched once, in
    /// batches, the first time the book shows anywhere. Reading in English,
    /// only a messy title is replaced.
    func bestTitle(_ title: String, for id: Int, language: String = BookLanguage.reading) -> String {
        guard id > 0 else { return title }
        guard language != "en" || EditionTitle.penalty(title) > 0 else { return title }
        return EditionTitle.languageTitle(title, among: titles(for: id, language: language))
    }

    /// Never a bilingual title ("Divergente / Divergent") for a book you don't
    /// own: the work's own title shows instead.
    func singleLanguage(_ title: String, of book: HCBook?) -> String {
        guard let book else { return title }
        return EditionTitle.singleLanguage(title, among: [book.title] + (book.alternateTitles ?? []))
    }

    func downloadedTitle(_ book: LocalBook) -> String {
        let hint = DownloadQueue.shared.jobs.first {
            $0.importedBookID == book.id && $0.editionTitle != nil
        }?.editionTitle
        var candidates = hint.map { [$0] } ?? []
        if let id = book.hardcoverBookID, id > 0, let language = BookLanguage.code(book.language) {
            candidates += titles(for: id, language: language)
        }
        return EditionTitle.best(book.title, among: candidates)
    }

    private func titles(for id: Int, language: String) -> [String] {
        let known = editionTitles[language]?[id]
        if known.map({ $0.fetched < Date().addingTimeInterval(-30 * 86_400) }) ?? true {
            requestEditionTitles(id, language: language)
        }
        return known?.titles ?? []
    }

    private func requestEditionTitles(_ id: Int, language: String) {
        guard inFlightTitleIDs[language]?.contains(id) != true,
              (retryTitlesAfter[language]?[id] ?? .distantPast) <= Date(),
              pendingTitleIDs[language, default: []].insert(id).inserted else { return }
        guard titleFetch == nil else { return }
        // Called while views draw: gather the screen's books, then ask once.
        titleFetch = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            await self?.fetchEditionTitles()
        }
    }

    private func fetchEditionTitles() async {
        while true {
            guard let (language, ids) = pendingTitleIDs.first else { titleFetch = nil; return }
            let batch = Set(ids.sorted().prefix(10))
            let remaining = ids.subtracting(batch)
            pendingTitleIDs[language] = remaining.isEmpty ? nil : remaining
            inFlightTitleIDs[language] = batch
            let found = try? await HardcoverClient.shared.editionTitles(bookIDs: batch.sorted(), language: language)
            inFlightTitleIDs[language] = nil
            guard let found else {
                let retryAfter = Date().addingTimeInterval(30)
                for id in batch { retryTitlesAfter[language, default: [:]][id] = retryAfter }
                FolioLog.log("edition titles failed for \(batch.count) book(s)", "titles")
                continue
            }
            let now = Date()
            for id in batch {
                retryTitlesAfter[language]?[id] = nil
                editionTitles[language, default: [:]][id] = FolioEditionTitles(
                    language: language, titles: found[id] ?? [], fetched: now)
            }
            FolioLog.log("edition titles for \(found.count) book(s)", "titles")
            if let data = try? JSONEncoder().encode(editionTitles) {
                UserDefaults.standard.set(data, forKey: Self.editionTitlesKey)
            }
        }
    }

    func shownEdition(for id: Int) -> FolioShownEdition? { shown[id] }

    /// Remembers the edition a book page showed (title and cover, without edits).
    func recordShown(_ edition: FolioShownEdition, for id: Int) {
        guard id > 0, shown[id] != edition else { return }
        shown[id] = edition
        if let data = try? JSONEncoder().encode(shown) {
            UserDefaults.standard.set(data, forKey: Self.shownKey)
        }
    }

    /// The library copy that stands for a Hardcover book: one linked to it, else an
    /// unlinked file with the same title and author (a download not matched yet).
    /// Matched by any title the book is known by, so the Spanish file
    /// "Juramentada" stands for "Juramentada / Oathbringer" and "Oathbringer".
    /// Open Library books (Home's For you) can't be linked to a file, so any copy
    /// with one of their titles counts.
    func libraryCopy(of book: HCBook) -> LocalBook? {
        let library = LibraryStore.shared
        let books = library.books
        if book.id > 0 {
            if let linked = books.first(where: { $0.hardcoverBookID == book.id }) { return linked }
            // A finished download of this work, whatever title its file came with.
            if let job = DownloadQueue.shared.jobs.first(where: {
                $0.stage == .completed && $0.hardcoverBookID == book.id && $0.importedBookID != nil
            }), let copy = job.importedBookID.flatMap({ library.book($0) }) { return copy }
        }
        var titles = [book.title] + (book.editionTitle.map { [$0] } ?? []) + (book.alternateTitles ?? [])
        titles += titles.flatMap(EditionTitle.bilingualParts)
        let wanted = Set(titles.map { matchKey(author: book.authors, title: $0) })
        let anyCopy = book.id <= 0
        return books.first {
            (anyCopy || $0.hardcoverBookID == nil) && wanted.contains(matchKey(author: $0.author, title: $0.title))
        }
    }

    private func matchKey(author: String, title: String) -> String {
        let raw = author + "\u{1F}" + title
        if let hit = matchKeys[raw] { return hit }
        let key = BookMatch.key(author: author, title: title)
        matchKeys[raw] = key
        return key
    }

    func override(for id: Int) -> FolioBookOverride? { items[id] }

    func set(_ override: FolioBookOverride?, for id: Int) {
        items[id] = override?.isEmpty == false ? override : nil
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
        FolioSyncedValues.changed()
    }

    /// Folio Sync: your edits to books outside the library, as one JSON value.
    var syncJSON: String? { FolioSyncedJSON.encode(items) }

    /// Takes another device's edits.
    func adoptSynced(_ json: String) {
        guard let theirs: [Int: FolioBookOverride] = FolioSyncedJSON.decode(json) else { return }
        items = theirs
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    /// The book as the reader edited it.
    /// The book as you have it: your library copy's own title and cover when
    /// you own it (often a translated edition, "Nacidos de la bruma"), then
    /// your own edits on top. Ratings and other work-wide numbers stay the
    /// work's. Like a bookstore app, the edition you own is the one you see.
    func apply(_ book: HCBook) -> HCBook {
        var out = book
        let library = LibraryStore.shared
        let owned = libraryCopy(of: book)
        if let local = owned {
            let title = downloadedTitle(local).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                out.title = title
                out.editionTitle = title
            }
            if let cover = library.coverURL(local), FileManager.default.fileExists(atPath: cover.path) {
                out.imageURL = cover
            }
        } else if let edition = shown[book.id], book.editionID == nil || book.editionID == edition.editionID {
            // Not owned: the edition its book page shows ("El nombre del viento").
            if let title = edition.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
               !BookAutoMatch.sameTitle(title, book.title) {
                out.title = title
                out.editionTitle = title
            }
            if let cover = edition.coverURL { out.imageURL = cover }
        }
        // Your own file keeps its title (it may be another language's
        // edition); every other book shows its reading-language edition title.
        if owned == nil {
            out.title = singleLanguage(bestTitle(out.title, for: book.id), of: book)
        }
        guard let o = items[book.id] else { return out }
        if let title = o.title { out.title = title }
        if let authors = o.authors { out.authors = authors }
        if let summary = o.summary { out.description = summary }
        if let cover = o.coverURL { out.imageURL = cover }
        if let year = o.year { out.year = year }
        if let pages = o.pages { out.pages = pages }
        return out
    }
}


// MARK: - Press-and-hold cover peek

/// The cover being peeked at, shown enlarged over the screen while a finger stays down.
@Observable
@MainActor
final class FolioCoverPeek {
    static let shared = FolioCoverPeek()
    private(set) var fileURL: URL?
    private(set) var remoteURL: URL?
    private(set) var image: UIImage?
    private(set) var active = false
    private var loadID = 0

    func show(fileURL: URL?, remoteURL: URL?) {
        loadID += 1
        let id = loadID
        self.fileURL = fileURL
        self.remoteURL = remoteURL
        image = fileURL.flatMap { UIImage(contentsOfFile: $0.path) } ?? remoteURL.flatMap { FolioImageCache.shared.memoryHit($0) }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(duration: 0.28, bounce: 0.18)) { active = true }
        // Swap in the full-resolution image when the list copy is downsized.
        guard fileURL == nil, let remoteURL else { return }
        Task {
            if let (data, _) = try? await URLSession.shared.data(from: remoteURL), let full = UIImage(data: data),
               id == loadID, active {
                image = full
            }
        }
    }

    func hide() {
        withAnimation(.spring(duration: 0.22)) { active = false }
    }
}

/// Shows the peeked cover; put one at the root of each presentation (the app, each sheet).
struct FolioCoverPeekHost: ViewModifier {
    @State private var peek = FolioCoverPeek.shared

    func body(content: Content) -> some View {
        content.overlay {
            if peek.active {
                ZStack {
                    Rectangle().fill(.ultraThinMaterial).ignoresSafeArea()
                    Color.black.opacity(0.25).ignoresSafeArea()
                    if let image = peek.image {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .shadow(color: .black.opacity(0.35), radius: 30, y: 12)
                            .padding(28)
                    } else {
                        ProgressView()
                    }
                }
                .transition(.opacity.combined(with: .scale(scale: 0.4)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
    }
}

/// Press and hold a cover to see it large; letting go puts it back.
struct FolioCoverPeekGesture: ViewModifier {
    let fileURL: URL?
    let remoteURL: URL?
    @GestureState private var holding = false

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.3)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .updating($holding) { value, state, _ in
                        if case .second(true, _) = value { state = true }
                    }
            )
            .onChange(of: holding) { _, isHolding in
                if isHolding { FolioCoverPeek.shared.show(fileURL: fileURL, remoteURL: remoteURL) }
                else { FolioCoverPeek.shared.hide() }
            }
            .accessibilityAction(named: "Show cover large") {
                FolioCoverPeek.shared.show(fileURL: fileURL, remoteURL: remoteURL)
                Task { try? await Task.sleep(for: .seconds(3)); FolioCoverPeek.shared.hide() }
            }
    }
}

extension View {
    func folioCoverPeekHost() -> some View { modifier(FolioCoverPeekHost()) }
    func folioCoverPeek(fileURL: URL? = nil, remoteURL: URL?) -> some View {
        modifier(FolioCoverPeekGesture(fileURL: fileURL, remoteURL: remoteURL))
    }
}
