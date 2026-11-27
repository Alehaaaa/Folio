import SwiftUI
import UniformTypeIdentifiers

struct FolioMobileLibraryView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(FolioMobileNavigation.self) private var navigation
    let showImporter: () -> Void
    @State private var search = ""
    @State private var filter: LibraryFilter = .all
    @State private var collection: UUID?
    @AppStorage("folio.librarySort") private var sorting: FolioMobileSort = .recent
    @AppStorage("folio.libraryHideRead") private var hideRead = false
    @AppStorage("folio.libraryReversed") private var reversed = false
    @State private var newCollection = ""
    @State private var addingCollection = false

    private var visibleBooks: [LocalBook] {
        var candidates = collection.map { store.books(in: $0, search: search) }
            ?? store.books(filter, search: search)
        // The Finished shelf is all read books, so Hide Read leaves it alone.
        if hideRead, collection != nil || filter != .finished {
            let read = FolioReadBooks.shared
            candidates.removeAll { read.isRead($0) }
        }
        let sorted = sorting.sorted(candidates)
        return reversed ? sorted.reversed() : sorted
    }

    private var showingShelves: Bool { navigation.libraryScope == .shelves }

    private var title: String {
        showingShelves ? "Library"
            : collection.flatMap { id in store.data.collections.first { $0.id == id }?.name } ?? "Library"
    }

    var body: some View {
        @Bindable var navigation = navigation
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                FolioTabHeader(title: title) {
                    if !showingShelves {
                        Menu {
                            Picker("Sort", selection: $sorting) {
                                ForEach(FolioMobileSort.allCases) { option in
                                    Text(option.label).tag(option)
                                }
                            }
                            Toggle("Reverse Order", systemImage: "arrow.up.arrow.down", isOn: $reversed)
                            Toggle("Hide Read", systemImage: "eye.slash", isOn: $hideRead)
                            Divider()
                            Button("All Books") { collection = nil }
                            ForEach(store.data.collections) { c in
                                Button(c.name) { collection = c.id }
                            }
                            Button("New Collection", systemImage: "plus") { addingCollection = true }
                        } label: {
                            FolioHeaderIconLabel(symbol: "line.3.horizontal.decrease")
                        }
                        .menuIndicator(.hidden)
                        .buttonStyle(.plain)
                        .foregroundStyle(FolioTheme.ink)
                        .accessibilityLabel("Filter and Sort")
                    }
                    FolioHeaderIcon(symbol: "plus", label: "Import books", action: showImporter)
                }
                .padding(.horizontal, 20)

                FolioSearchField(text: $search, prompt: showingShelves ? "Search your shelves" : "Title or author")
                    .padding(.horizontal, 16)

                Picker("Show", selection: $navigation.libraryScope) {
                    ForEach(FolioMobileLibraryScope.allCases) { scope in
                        Text(scope.rawValue).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .accessibilityIdentifier("folio.libraryScope")

                if showingShelves {
                    FolioMobileShelvesView(search: search)
                } else {
                    booksContent
                }
            }
            .padding(.top, 12)
            .padding(.bottom, 12)
        }
        .scrollDismissesKeyboard(.immediately)
        .refreshable {
            if showingShelves {
                await FolioMobileShelvesModel.shared.refresh(navigation.shelfStatus, hardcover: hardcover,
                                                             library: store, includeGoodreads: true)
            } else {
                FolioSync.pushPending(library: store, hardcover: hardcover)
            }
        }
        .folioScreen()
        .task(id: sorting) {
            if sorting == .series || sorting == .author { await store.fillInSeriesFromHardcover() }
        }
        .navigationTitle(title)
        .toolbar(.hidden, for: .navigationBar)
        .alert("New Collection", isPresented: $addingCollection) {
            TextField("Collection name", text: $newCollection)
            Button("Cancel", role: .cancel) { newCollection = "" }
            Button("Create") {
                let name = newCollection.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { collection = store.addCollection(name) }
                newCollection = ""
            }
        }
    }

    @ViewBuilder
    private var booksContent: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { option in
                    Button {
                        filter = option
                        collection = nil
                    } label: {
                        Text(option.label)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 9)
                    }
                    .folioGlassPill(prominent: collection == nil && filter == option)
                }
            }
            .padding(.horizontal, 16)
        }

        let books = visibleBooks
        if books.isEmpty {
            ContentUnavailableView {
                Label(search.isEmpty ? "No Books Yet" : "No Matches", systemImage: "books.vertical")
            } description: {
                Text(search.isEmpty ? "Import books to start reading." : "Try another title or author.")
            } actions: {
                if search.isEmpty {
                    Button("Import Books", action: showImporter)
                        .folioGlassPill(prominent: true)
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 136, maximum: 190), spacing: 16, alignment: .top)], alignment: .leading, spacing: 24) {
                ForEach(books) { book in
                    NavigationLink(value: book.id) {
                        FolioMobileBookTile(book: book, showsSeries: sorting == .series)
                    }
                    .buttonStyle(.plain)
                    .folioBookContextMenu(book)
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

enum FolioMobileSort: String, CaseIterable, Identifiable {
    case recent, added, title, author, series, progress, published
    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: "Recently Opened"
        case .added: "Recently Added"
        case .title: "Title"
        case .author: "Author"
        case .series: "Series"
        case .progress: "Progress"
        case .published: "Publication Date"
        }
    }

    @MainActor
    func sorted(_ books: [LocalBook]) -> [LocalBook] {
        switch self {
        case .recent:
            return books.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        case .added:
            return books.sorted { $0.addedAt > $1.addedAt }
        case .title:
            return books.sorted { Self.ascending($0.title, $1.title) }
        case .author:
            // Within an author, a saga stays together and in reading order.
            let keys = Self.seriesKeys(books)
            return books.sorted { a, b in
                let order = a.author.localizedStandardCompare(b.author)
                if order != .orderedSame { return order == .orderedAscending }
                return keys[a.id]!.precedes(keys[b.id]!)
            }
        case .series:
            let keys = Self.seriesKeys(books)
            return books.sorted { keys[$0.id]!.precedes(keys[$1.id]!) }
        case .progress:
            // Books under way first, furthest along on top, then unstarted, then finished.
            func rank(_ b: LocalBook) -> Int {
                if FolioReadBooks.shared.isRead(b) { return 2 }
                return b.progress > 0.001 ? 0 : 1
            }
            return books.sorted { a, b in
                let ra = rank(a), rb = rank(b)
                if ra != rb { return ra < rb }
                if ra == 0, a.progress != b.progress { return a.progress > b.progress }
                return (a.lastOpenedAt ?? a.addedAt) > (b.lastOpenedAt ?? b.addedAt)
            }
        case .published:
            // Newest first; books without a year go last, by title.
            return books.sorted { a, b in
                switch (a.publishedYear, b.publishedYear) {
                case let (x?, y?) where x != y: return x > y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return Self.ascending(a.title, b.title)
                }
            }
        }
    }

    private static func ascending(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    /// A saga's books sit together under the saga's name, in volume order; a book
    /// outside any saga files under its own title among them.
    struct SeriesKey {
        var shelf: String
        var group: String?
        var index: Double?
        var title: String

        func precedes(_ other: SeriesKey) -> Bool {
            let order = shelf.localizedStandardCompare(other.shelf)
            if order != .orderedSame { return order == .orderedAscending }
            if (group == nil) != (other.group == nil) { return group != nil }
            if let g = group, let h = other.group, g != h { return g < h }
            switch (index, other.index) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return title.localizedStandardCompare(other.title) == .orderedAscending
            }
        }
    }

    @MainActor
    private static func seriesKeys(_ books: [LocalBook]) -> [UUID: SeriesKey] {
        func name(_ b: LocalBook) -> String? {
            let s = b.series?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return s.isEmpty ? nil : s
        }
        // "Red Rising" and "Red Rising Saga" are one saga: file both under the fuller name.
        var shelfNames: [String: String] = [:]
        for b in books {
            guard let s = name(b) else { continue }
            let g = HardcoverClient.seriesKey(s)
            if let current = shelfNames[g], current.count >= s.count { continue }
            shelfNames[g] = s
        }
        var keys: [UUID: SeriesKey] = [:]
        for b in books {
            if let s = name(b) {
                let g = HardcoverClient.seriesKey(s)
                keys[b.id] = SeriesKey(shelf: shelfNames[g] ?? s, group: g, index: b.seriesIndex, title: b.title)
            } else {
                keys[b.id] = SeriesKey(shelf: b.title, group: nil, index: nil, title: b.title)
            }
        }
        return keys
    }
}
