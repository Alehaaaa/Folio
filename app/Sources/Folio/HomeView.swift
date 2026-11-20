import SwiftUI
import Charts

struct HomeView: View {
    @Binding var selection: SidebarItem?
    var onSearch: (String) -> Void = { _ in }
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hc
    @Environment(\.openWindow) private var openWindow

    @State private var searchText = ""
    @State private var hcReading: [HCUserBook] = []
    @State private var hcWant: [HCUserBook] = []
    @State private var recommended: [HCBook] = []
    @State private var trending: [HCBook] = []
    @State private var recommendationAuthors: [String] = []
    @State private var loadingDiscovery = false
    @State private var discoveryError: String?
    @State private var detail: HCBook?

    private var heroBook: LocalBook? {
        store.continueReading.first
            ?? store.books.first(where: { $0.status == .wantToRead && $0.lastOpenedAt == nil })
            ?? store.recentlyAdded.first
    }

    private var readingRowBooks: [LocalBook] {
        Array(store.books(.reading).filter { $0.id != heroBook?.id }.prefix(12))
    }

    private var nextBooks: [LocalBook] {
        let currentID = heroBook?.id
        return store.books(.wantToRead).filter { $0.id != currentID }
    }

    /// A local file is the best entry point for a linked book. Only show its
    /// Hardcover counterpart when that book is absent from the local shelf.
    private func remoteOnly(_ items: [HCUserBook], excluding local: [LocalBook]) -> [HCUserBook] {
        var seenIDs = Set(local.compactMap(\.hardcoverBookID))
        var seenKeys = Set(local.map { ShelfItem.key($0.title, $0.author) })
        return items.filter { item in
            let key = ShelfItem.key(item.book.title, item.book.authors)
            guard !seenIDs.contains(item.book.id), !seenKeys.contains(key) else { return false }
            seenIDs.insert(item.book.id)
            seenKeys.insert(key)
            return true
        }
    }

    private var readingRemoteBooks: [HCUserBook] {
        remoteOnly(hcReading, excluding: store.books(.reading))
    }

    private var wantRemoteBooks: [HCUserBook] {
        remoteOnly(hcWant, excluding: store.books(.wantToRead))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 31) {
                welcomeHeader

                if let book = heroBook {
                    hero(book)
                } else if store.books.isEmpty {
                    emptyLibraryCard
                }

                BookJourneyCard { selection = .downloading }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 17) {
                        goalsCard
                        discoveryCard
                    }
                    VStack(alignment: .leading, spacing: 17) {
                        goalsCard
                        discoveryCard
                    }
                }

                if !readingRowBooks.isEmpty || !readingRemoteBooks.isEmpty {
                    shelfRow("Keep Reading", subtitle: "Your current books, all in one shelf",
                             books: readingRowBooks, remote: Array(readingRemoteBooks.prefix(12)), more: .shelf(.reading))
                }

                if !nextBooks.isEmpty || !wantRemoteBooks.isEmpty {
                    shelfRow("Up Next", subtitle: "Books on your Want to Read shelf",
                             books: Array(nextBooks.prefix(12)), remote: Array(wantRemoteBooks.prefix(12)), more: .shelf(.wantToRead))
                }

                if !recommended.isEmpty {
                    discoveryRow("Recommended for You", subtitle: recommendationSubtitle,
                                 books: recommended, symbol: "sparkles", showRefresh: true)
                }

                if !trending.isEmpty {
                    discoveryRow("Popular Right Now", subtitle: "Trending this month with Hardcover readers",
                                 books: trending, symbol: "chart.line.uptrend.xyaxis", showRefresh: false)
                } else if loadingDiscovery && hc.isConnected {
                    discoveryLoading
                }

                if let discoveryError, hc.isConnected, !loadingDiscovery {
                    HStack(spacing: 10) {
                        Label(discoveryError, systemImage: "wifi.exclamationmark")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Retry") { Task { await loadRemote() } }
                            .buttonStyle(.glass)
                    }
                }

                if !store.books.isEmpty {
                    shelfRow("Recently Added", subtitle: "Fresh on your shelves", books: Array(store.recentlyAdded.prefix(12)), more: .library(.all))
                }
            }
            .padding(.horizontal, 34)
            .padding(.vertical, 30)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .toolbar { LibraryToolbar() }
        .task(id: hc.revision) { await loadRemote() }
        .bookPopup(item: $detail) { HCBookDetail(book: $0) }
    }

    private func loadRemote() async {
        guard hc.isConnected else {
            hcReading = []
            hcWant = []
            recommended = []
            trending = []
            recommendationAuthors = []
            discoveryError = nil
            loadingDiscovery = false
            return
        }
        loadingDiscovery = true
        discoveryError = nil
        defer { loadingDiscovery = false }

        async let readingRequest = hc.shelf(.reading)
        async let wantRequest = hc.shelf(.wantToRead)
        async let trendingRequest = hc.trending()
        let reading = (try? await readingRequest) ?? []
        let want = (try? await wantRequest) ?? []
        guard !Task.isCancelled else { return }
        hcReading = reading
        hcWant = Array(want.prefix(14))

        let local = store.books
        let known = Set(local.map { BookMatch.key(author: $0.author, title: $0.title) })
            .union(store.data.tracked.map { BookMatch.key(author: $0.author, title: $0.title) })
            .union((reading + want).map { BookMatch.key(author: $0.book.authors, title: $0.book.title) })

        if let popular = try? await trendingRequest {
            trending = Array(popular.filter { !known.contains(BookMatch.key(author: $0.authors, title: $0.title)) }.prefix(14))
        } else {
            trending = []
            discoveryError = "Popular books are unavailable right now."
        }

        let authors = favoriteAuthors(local: local, reading: reading)
        recommendationAuthors = authors
        var candidates: [HCBook] = []
        var seen = Set<Int>()
        for author in authors {
            if Task.isCancelled { return }
            guard let results = try? await hc.search(author) else { continue }
            for book in results where Names.matches(book.authors, author)
                && !known.contains(BookMatch.key(author: book.authors, title: book.title)) {
                if seen.insert(book.id).inserted { candidates.append(book) }
            }
        }
        if Task.isCancelled { return }
        // Search relevance comes first, with broad reader ratings as a tie-breaker.
        recommended = Array(candidates.sorted {
            let first = ($0.rating ?? 0) * log2(Double(($0.ratingsCount ?? 0) + 2))
            let second = ($1.rating ?? 0) * log2(Double(($1.ratingsCount ?? 0) + 2))
            return first > second
        }.prefix(12))
    }

    private func favoriteAuthors(local: [LocalBook], reading: [HCUserBook]) -> [String] {
        let preferredLocal = local.sorted {
            func priority(_ b: LocalBook) -> Int {
                if b.lastOpenedAt != nil { return 3 }
                if b.status == .finished { return 2 }
                if b.status == .wantToRead { return 1 }
                return 0
            }
            let lhs = priority($0), rhs = priority($1)
            return lhs == rhs ? $0.addedAt > $1.addedAt : lhs > rhs
        }
        let names = preferredLocal.flatMap { Names.split($0.author) }
            + reading.flatMap { Names.split($0.book.authors) }
            + store.data.tracked.filter { $0.status == .read || $0.status == .reading }.flatMap { Names.split($0.author) }
        var seen = Set<String>()
        return Array(names.filter { name in
            let key = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return name.count > 2 && seen.insert(key).inserted
        }.prefix(2))
    }

    private var recommendationSubtitle: String {
        let authors = recommendationAuthors.prefix(2).joined(separator: " and ")
        return "More books by \(authors), based on your shelves"
    }

    private var welcomeHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 20) {
                welcomeTitle
                Spacer(minLength: 12)
                homeSearchField
            }
            VStack(alignment: .leading, spacing: 17) {
                welcomeTitle
                homeSearchField
            }
        }
    }

    private var welcomeTitle: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("YOUR READING SPACE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(.secondary)
            Text("Home")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .tracking(-0.8)
            Text(store.books.isEmpty ? "A great story starts here." : "Find your next chapter.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var homeSearchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search books or authors", text: $searchText)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit { onSearch(searchText) }
                .accessibilityIdentifier("home.searchField")
            Button { onSearch(searchText) } label: {
                Image(systemName: "arrow.right")
                    .font(.callout.weight(.semibold))
                    .frame(width: 25, height: 25)
            }
            .buttonStyle(.glass)
            .help("Search library and Hardcover")
            .accessibilityLabel("Search")
        }
        .padding(.leading, 15)
        .padding(.trailing, 7)
        .frame(width: 310, height: 44)
        .background(.background.secondary, in: .capsule)
        .overlay(Capsule().strokeBorder(.separator.opacity(0.6), lineWidth: 0.6))
    }

    private var discoveryCard: some View {
        GlassCard {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: hc.isConnected ? "sparkles.rectangle.stack" : "books.vertical.fill")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.indigo)
                    .frame(width: 48, height: 48)
                    .background(Color.indigo.opacity(0.09), in: .rect(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 6) {
                    Text(hc.isConnected ? "Discover Something New" : "Discover More Books")
                        .font(.headline)
                    Text(hc.isConnected ? "Browse new finds and reading recommendations." : "Connect Hardcover to unlock a world of books and recommendations.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if hc.isConnected {
                        Button { onSearch("") } label: {
                            Label("Explore Books", systemImage: "arrow.up.right")
                                .foregroundStyle(Color(nsColor: .labelColor))
                        }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    } else {
                        SettingsLink {
                            Label("Connect Hardcover", systemImage: "person.crop.circle.badge.plus")
                                .foregroundStyle(Color(nsColor: .labelColor))
                        }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var discoveryLoading: some View {
        HStack(spacing: 11) {
            ProgressView().controlSize(.small)
            Text("Finding books you might enjoy…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private func discoveryRow(_ title: String, subtitle: String, books: [HCBook], symbol: String, showRefresh: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.indigo)
                    .frame(width: 36, height: 36)
                    .background(Color.indigo.opacity(0.08), in: .rect(cornerRadius: 11))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title2.weight(.bold))
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                if showRefresh {
                    Button { Task { await loadRemote() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.glass)
                        .disabled(loadingDiscovery)
                        .help("Refresh recommendations")
                        .accessibilityLabel("Refresh recommendations")
                } else {
                    Button { selection = .browse } label: {
                        Text("Browse All").foregroundStyle(Color(nsColor: .labelColor))
                    }
                        .buttonStyle(.glass)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(books) { book in
                        HCBookCell(book: book) { detail = book }.frame(width: 148)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
    }

    // MARK: Hero (Books' "Continue" card)

    private func hero(_ book: LocalBook) -> some View {
        let isContinuing = book.lastOpenedAt != nil
        return HStack(alignment: .center, spacing: 25) {
            book.cover
                .frame(width: 118)
                .onTapGesture { BookDetailsPresenter.showLocal(book.id) }
            VStack(alignment: .leading, spacing: 10) {
                Label(isContinuing ? "CONTINUE READING" : "READY WHEN YOU ARE", systemImage: isContinuing ? "book.pages" : "sparkle")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
                Text(book.title).font(.system(size: 27, weight: .bold, design: .rounded)).lineLimit(2)
                    .onTapGesture { BookDetailsPresenter.showLocal(book.id) }
                if !book.author.isEmpty { AuthorLinks(line: book.author).font(.title3).foregroundStyle(.secondary) }
                if let s = book.series { SeriesLink(name: s, index: book.seriesIndex).font(.callout).foregroundStyle(.secondary) }
                if isContinuing {
                    HStack(spacing: 10) {
                        ProgressView(value: book.progress).frame(width: 220)
                        Text(book.progressLabel).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .padding(.top, 3)
                } else {
                    Text("A new story, ready to open.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Button { openWindow(id: "reader", value: book.id) } label: {
                        Label(isContinuing ? "Continue Reading" : "Start Reading", systemImage: "book.fill")
                            .padding(.horizontal, 12)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(BookPrimaryActionStyle())
                    .controlSize(.large)
                    Button { BookDetailsPresenter.showLocal(book.id) } label: {
                        Text("Details").foregroundStyle(Color(nsColor: .labelColor))
                    }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    BookActionsMenu(book: book)
                }
                .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .padding(27)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 22))
        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(.separator.opacity(0.45), lineWidth: 0.7) }
    }

    private var emptyLibraryCard: some View {
        GlassCard(padding: 30) {
            HStack(spacing: 26) {
                Image(systemName: "books.vertical")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your library is empty").font(.title2.weight(.bold))
                    Text("Drag EPUB, PDF, text, Markdown or comic (CBZ) files anywhere in this window, or choose them from your Mac. They're read right here, with Books-style themes.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button { NotificationCenter.default.post(name: .folioImport, object: nil) } label: {
                            Label("Add to Library…", systemImage: "plus")
                        }
                        .buttonStyle(.glassProminent)
                        Button { onSearch("") } label: {
                            Label("Explore Books", systemImage: "sparkle.magnifyingglass")
                                .foregroundStyle(Color(nsColor: .labelColor))
                        }
                            .buttonStyle(.glass)
                    }
                    .controlSize(.large)
                    .padding(.top, 6)
                }
            }
        }
    }

    // MARK: Reading goals card (Books' ReadingActivityService)

    private var goalsCard: some View {
        GlassCard {
            HStack(spacing: 22) {
                ZStack {
                    ProgressRing(value: store.todayMinutes / Double(max(1, store.data.goals.dailyMinutes)), lineWidth: 11)
                    VStack(spacing: 0) {
                        Text("\(Int(store.todayMinutes))").font(.title.weight(.bold).monospacedDigit())
                        Text("of \(store.data.goals.dailyMinutes) min").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 104, height: 104)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Today's Reading").font(.headline)
                    Text(store.isDailyGoalCompleted ? "You met your daily goal. Keep going!" : "Read \(max(0, store.data.goals.dailyMinutes - Int(store.todayMinutes))) more minutes to meet your goal.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack(spacing: 18) {
                        Label("\(store.streak) day streak", systemImage: "flame.fill").foregroundStyle(.orange)
                        Label("\(store.finishedThisYear) of \(store.data.goals.booksPerYear) books this year", systemImage: "books.vertical.fill")
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    Button("Reading Goals…") { selection = .goals }
                        .controlSize(.small)
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Rows

    private func shelfRow(_ title: String, subtitle: String?, books: [LocalBook], remote: [HCUserBook] = [], more: SidebarItem? = nil) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: title, subtitle: subtitle, action: more.map { m in { selection = m } })
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 22) {
                    ForEach(books) { b in LocalBookCell(book: b).frame(width: 140) }
                    ForEach(remote) { ub in
                        HCBookCell(book: ub.book, progress: ub.progressFraction) { detail = ub.book }.frame(width: 140)
                    }
                }
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
    }
}

extension HCUserBook {
    var progressFraction: Double? {
        guard let p = progressPages, let total = book.pages, total > 0 else { return nil }
        return min(1, Double(p) / Double(total))
    }
}

// MARK: - Reading Goals screen

struct GoalsView: View {
    @Environment(LibraryStore.self) private var store

    struct Day: Identifiable { var id: Int; var label: String; var minutes: Double }

    private var week: [Day] {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return (0..<7).reversed().map { ago in
            let d = Calendar.current.date(byAdding: .day, value: -ago, to: Date())!
            return Day(id: ago, label: ago == 0 ? "Today" : f.string(from: d), minutes: store.minutes(daysAgo: ago))
        }
    }

    var body: some View {
        @Bindable var store = store
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("Reading Goals").font(.largeTitle.weight(.bold))
                HStack(alignment: .top, spacing: 20) {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Today").font(.headline)
                            HStack(spacing: 24) {
                                ZStack {
                                    ProgressRing(value: store.todayMinutes / Double(max(1, store.data.goals.dailyMinutes)), lineWidth: 14)
                                    VStack(spacing: 0) {
                                        Text(String(format: "%d:%02d", Int(store.todayMinutes), Int(store.todayMinutes * 60) % 60))
                                            .font(.system(size: 28, weight: .bold).monospacedDigit())
                                        Text("of \(store.data.goals.dailyMinutes) minutes").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 150, height: 150)
                                VStack(alignment: .leading, spacing: 10) {
                                    Stepper("Daily goal: \(store.data.goals.dailyMinutes) min", value: $store.data.goals.dailyMinutes, in: 1...240)
                                        .onChange(of: store.data.goals.dailyMinutes) { store.save() }
                                    Label("\(store.streak)-day streak", systemImage: "flame.fill").foregroundStyle(.orange)
                                    Text("Time counts while a book is open and Folio is in front.").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    GlassCard {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Books Read This Year").font(.headline)
                            HStack(spacing: 24) {
                                ZStack {
                                    ProgressRing(value: Double(store.finishedThisYear) / Double(max(1, store.data.goals.booksPerYear)), lineWidth: 14, color: .indigo)
                                    VStack(spacing: 0) {
                                        Text("\(store.finishedThisYear)").font(.system(size: 34, weight: .bold).monospacedDigit())
                                        Text("of \(store.data.goals.booksPerYear) books").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 150, height: 150)
                                Stepper("Yearly goal: \(store.data.goals.booksPerYear)", value: $store.data.goals.booksPerYear, in: 1...365)
                                    .onChange(of: store.data.goals.booksPerYear) { store.save() }
                            }
                        }
                    }
                }
                GlassCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("This Week").font(.headline)
                        Chart(week) { d in
                            BarMark(x: .value("Day", d.label), y: .value("Minutes", d.minutes))
                                .foregroundStyle(d.minutes >= Double(store.data.goals.dailyMinutes) ? Color.orange : Color.secondary.opacity(0.4))
                                .cornerRadius(6)
                            RuleMark(y: .value("Goal", store.data.goals.dailyMinutes))
                                .foregroundStyle(.orange.opacity(0.6))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        }
                        .chartYAxisLabel("minutes")
                        .frame(height: 200)
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
    }
}
