import SwiftUI
import Observation

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
        FolioSyncedValues.changed()
    }

    /// Folio Sync: the saved series as one JSON value.
    var syncJSON: String? { FolioSyncedJSON.encode(items) }

    /// Takes another device's saved series.
    func adoptSynced(_ json: String) {
        guard let theirs: [FolioSavedSeriesItem] = FolioSyncedJSON.decode(json) else { return }
        items = theirs
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
                    Text(failure).foregroundStyle(FolioTheme.muted).folioRow()
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
        .task(id: route.id) { await HCPriority.$foreground.withValue(true) { await load() } }
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
        let owned = FolioBookOverrides.shared.libraryCopy(of: entry.book) != nil
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
                .foregroundStyle(FolioTheme.muted)
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
                            // The count sits right under the name, however many lines it takes.
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(.caption, design: .serif))
                                    .foregroundStyle(FolioTheme.ink)
                                    .lineLimit(2)
                                if let count = FolioSeriesCache.load(item.id)?.mainCount ?? item.count {
                                    Text(count == 1 ? "1 book" : "\(count) books")
                                        .font(.caption2)
                                        .foregroundStyle(FolioTheme.muted)
                                }
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
