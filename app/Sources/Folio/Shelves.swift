import SwiftUI
import UniformTypeIdentifiers

// MARK: - One shelf across the library, Hardcover and Goodreads

/// One visible title, merging a local file with its matching synced shelf entries.
struct ShelfItem: Identifiable {
    var id: String
    var title: String
    var author: String
    var cover: URL?
    var local: LocalBook?
    var hc: HCUserBook?
    var gr: TrackedBook?

    var myRating: Double? {
        if let r = hc?.rating, r > 0 { return r }
        if let r = gr?.rating, r > 0 { return Double(r) }
        return nil
    }

    static func key(_ title: String, _ author: String) -> String {
        BookMatch.key(author: Names.split(author).first ?? author, title: title)
    }
}

extension HCStatus {
    var unifiedLabel: String {
        switch self {
        case .reading: "Reading Now"
        case .read: "Finished"
        default: label
        }
    }

    /// Local files only have three reading states; Paused and DNF come from synced accounts.
    var libraryFilter: LibraryFilter? {
        switch self {
        case .wantToRead: .wantToRead
        case .reading: .reading
        case .read: .finished
        case .paused, .dnf: nil
        }
    }

    /// The matching Goodreads shelf (Goodreads has no "Paused").
    var goodreads: GRShelf? {
        switch self {
        case .wantToRead: .wantToRead
        case .reading: .currentlyReading
        case .read: .read
        case .paused: nil
        case .dnf: .dnf
        }
    }
}

struct ShelfView: View {
    let status: HCStatus

    enum Source: String, CaseIterable, Identifiable {
        case all = "All", library = "Library", hardcover = "Hardcover", goodreads = "Goodreads"
        var id: String { rawValue }
    }

    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hc
    @Environment(GoodreadsClient.self) private var gr

    @State private var source: Source = .all
    @State private var hcItems: [HCUserBook] = []
    @State private var loading = false
    @State private var error: String?
    @State private var search = ""
    @State private var message: String?
    @State private var sending = false
    @State private var showImport = false
    @State private var exportDoc: CSVDocument?
    @State private var userIDField = ""
    @State private var detail: HCBook?

    private var localBooks: [LocalBook] { status.libraryFilter.map { store.books($0) } ?? [] }
    private var grBooks: [TrackedBook] { status.goodreads.map { store.tracked($0) } ?? [] }
    private var sources: [Source] {
        var available: [Source] = [.all]
        if status.libraryFilter != nil { available.append(.library) }
        if hc.isConnected { available.append(.hardcover) }
        if hasGoodreads && status.goodreads != nil { available.append(.goodreads) }
        return available
    }

    /// Start with imported books so they stay readable even when an account goes offline.
    /// Hardcover IDs beat fuzzy name matching when present; title+author is the fallback.
    private var merged: [ShelfItem] {
        var out: [ShelfItem] = []
        var index: [String: Int] = [:]
        var byHCID: [Int: Int] = [:]
        for book in localBooks {
            let key = ShelfItem.key(book.title, book.author)
            if let i = book.hardcoverBookID.flatMap({ byHCID[$0] }) ?? index[key] {
                if out[i].local == nil { out[i].local = book }
                continue
            }
            let i = out.count
            index[key] = i
            if let id = book.hardcoverBookID { byHCID[id] = i }
            out.append(ShelfItem(id: "local\(book.id.uuidString)", title: book.title,
                                 author: book.author, cover: store.coverURL(book), local: book))
        }
        for ub in hcItems {
            let key = ShelfItem.key(ub.book.title, ub.book.authors)
            if let i = byHCID[ub.book.id] ?? index[key] {
                out[i].hc = ub
                if out[i].cover == nil { out[i].cover = ub.book.imageURL }
                byHCID[ub.book.id] = i
            } else {
                let i = out.count
                index[key] = i
                byHCID[ub.book.id] = i
                out.append(ShelfItem(id: "hc\(ub.id)", title: ub.book.title,
                                     author: ub.book.authors, cover: ub.book.imageURL, hc: ub))
            }
        }
        for t in grBooks {
            if let i = t.hardcoverBookID.flatMap({ byHCID[$0] }) ?? index[ShelfItem.key(t.title, t.author)] {
                out[i].gr = t
                if out[i].cover == nil { out[i].cover = t.coverURL.flatMap(URL.init(string:)) }
            } else {
                index[ShelfItem.key(t.title, t.author)] = out.count
                out.append(ShelfItem(id: "gr\(t.id)", title: t.title, author: t.author, cover: t.coverURL.flatMap(URL.init(string:)), gr: t))
            }
        }
        return out
    }

    private var shown: [ShelfItem] {
        merged.filter { item in
            switch source {
            case .all: true
            case .library: item.local != nil
            case .hardcover: item.hc != nil
            case .goodreads: item.gr != nil
            }
        }
        .filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || $0.author.localizedCaseInsensitiveContains(search) }
    }

    private var goodreadsOnly: Int { merged.filter { $0.hc == nil && $0.gr != nil && !($0.gr?.sentToHardcover ?? false) }.count }
    private var hasGoodreads: Bool { gr.isLinked || !store.data.tracked.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if sources.count > 2 {
                    Picker("Show", selection: $source) {
                        ForEach(sources) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 480)
                }
                statusLine
                if loading && shown.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else if shown.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("No books on this shelf yet", systemImage: status.symbol)
                                .font(.headline)
                            Text("Books marked \(status.label) in your library or linked accounts will appear here.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                coverGrid {
                    ForEach(shown) { item in ShelfTile(item: item, status: status) { open(item) } }
                }
                if !hc.isConnected || (!hasGoodreads && status.goodreads != nil) {
                    Divider().padding(.vertical, 8)
                    HStack(alignment: .top, spacing: 20) {
                        if !hc.isConnected {
                            ConnectPrompt(message: "Connect Hardcover to see your online books on this shelf alongside your library.")
                        }
                        if !hasGoodreads && status.goodreads != nil { linkGoodreadsCard }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .searchable(text: $search, placement: .toolbar, prompt: "Filter Shelf")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Task { await refresh(pullGoodreads: true) } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh from Hardcover and Goodreads")
                    .disabled(loading || !gr.loading.isEmpty)
                if hc.isConnected && goodreadsOnly > 0 {
                    Button { Task { await sendToHardcover() } } label: { Label("Copy Goodreads Books to Hardcover", systemImage: "arrow.up.forward.app") }
                        .help("Add the \(goodreadsOnly) Goodreads-only books on this shelf to Hardcover")
                        .disabled(sending)
                }
                Menu {
                    Button("Import Goodreads Export (CSV)…") { showImport = true }
                    Button("Export Library for Goodreads (CSV)…") { Task { exportDoc = CSVDocument(text: await goodreadsExportCSV(store: store, hc: hc)) } }
                } label: { Label("Import & Export", systemImage: "square.and.arrow.up.on.square") }
                .help("Import & Export")
            }
        }
        .fileImporter(isPresented: $showImport, allowedContentTypes: [.commaSeparatedText, .plainText]) { r in
            if case .success(let url) = r { store.importGoodreads(url); message = store.goodreadsMessage }
        }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .commaSeparatedText, defaultFilename: "folio_goodreads_import.csv") { r in
            if case .success = r { message = "Saved. On Goodreads, open My Books → Import and export → Import, and choose this file." }
        }
        .task(id: "\(status.rawValue)-\(hc.revision)") { await refresh(pullGoodreads: false) }
        .onChange(of: status) { _, _ in source = .all; search = ""; hcItems = [] }
        .onChange(of: hc.isConnected) { _, _ in source = .all }
        .onChange(of: hasGoodreads) { _, _ in source = .all }
        .bookPopup(item: $detail) { HCBookDetail(book: $0) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(status.unifiedLabel).font(.largeTitle.weight(.bold))
            let parts = [
                "\(merged.count) unique book\(merged.count == 1 ? "" : "s")",
                status.libraryFilter != nil ? "\(localBooks.count) in Library" : nil,
                hc.isConnected ? "\(hcItems.count) on Hardcover" : nil,
                hasGoodreads && status.goodreads != nil ? "\(grBooks.count) on Goodreads" : nil,
            ].compactMap { $0 }
            Text(parts.joined(separator: " · ")).font(.callout).foregroundStyle(.secondary)
        }
    }

    private var statusLine: some View {
        HStack(spacing: 8) {
            if !gr.loading.isEmpty || sending { ProgressView().controlSize(.small) }
            if let message { Text(message) }
            else if let error { Label(error, systemImage: "exclamationmark.triangle") }
            else if let e = gr.lastError { Label(e, systemImage: "exclamationmark.triangle") }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
    }

    private var linkGoodreadsCard: some View {
        GlassCard(padding: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Add your Goodreads shelves").font(.headline)
                Text("Paste your Goodreads profile link or user number. Its public shelves join these ones, matched with Hardcover where they're the same book.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("goodreads.com/user/show/…", text: $userIDField)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(linkGoodreads)
                    Button("Link", action: linkGoodreads).buttonStyle(.glassProminent)
                }
                Button("Or import a Goodreads export file…") { showImport = true }
                    .buttonStyle(.plain).font(.callout).foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: 520)
    }

    private func linkGoodreads() {
        let id = GoodreadsClient.normalize(userIDField)
        guard !id.isEmpty else { return }
        gr.userID = id
        Task { await gr.syncAll(into: store) }
    }

    private func refresh(pullGoodreads: Bool) async {
        loading = true
        if hc.isConnected {
            do { hcItems = try await hc.shelf(status); error = nil } catch { self.error = error.localizedDescription }
        } else {
            hcItems = []
        }
        if gr.isLinked && (pullGoodreads || gr.lastSync == nil) {
            // Its own task, so leaving or reloading this page doesn't cancel the Goodreads download.
            let gr = gr, store = store
            Task { await gr.syncAll(into: store) }
        }
        loading = false
    }

    private func sendToHardcover() async {
        guard let shelf = status.goodreads else { return }
        sending = true
        message = "Copying Goodreads books to Hardcover…"
        let r = await store.sendTrackedToHardcover(hc, shelf: shelf)
        message = "Added \(r.sent) book\(r.sent == 1 ? "" : "s") to Hardcover" + (r.missed > 0 ? "; \(r.missed) couldn't be matched." : ".")
        sending = false
        await refresh(pullGoodreads: false)
    }

    /// Imported books open their editable details; remote-only books use their linked service.
    private func open(_ item: ShelfItem) {
        if let book = item.local { BookDetailsPresenter.showLocal(book.id); return }
        if let ub = item.hc { detail = ub.book; return }
        guard let t = item.gr else { return }
        Task {
            if hc.isConnected, let b = await resolveOnHardcover(t) { detail = b; return }
            PopupCenter.shared.show(AnyView(GoodreadsBookDetail(book: t))) {}
        }
    }

    private func resolveOnHardcover(_ t: TrackedBook) async -> HCBook? {
        var id = t.hardcoverBookID
        if id == nil, let isbn = t.isbn13 ?? t.isbn { id = try? await hc.bookID(isbn: isbn) }
        if id == nil {
            let cleanTitle = t.title.replacingOccurrences(of: "\\s*\\(.*\\)\\s*$", with: "", options: .regularExpression)
            let results = (try? await hc.search("\(cleanTitle) \(t.author)")) ?? []
            id = results.first { ShelfItem.key($0.title, $0.authors) == ShelfItem.key(cleanTitle, t.author) }?.id ?? results.first?.id
        }
        guard let id else { return nil }
        if let i = store.data.tracked.firstIndex(where: { $0.id == t.id }) {
            store.data.tracked[i].hardcoverBookID = id
            store.save()
        }
        return try? await hc.book(id: id)
    }
}

// MARK: - Tile

struct ShelfTile: View {
    let item: ShelfItem
    let status: HCStatus
    let open: () -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(HardcoverClient.self) private var hc
    @Environment(LibraryStore.self) private var store
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            artwork
                .overlay(alignment: .bottomTrailing) { badges.padding(6) }
                .scaleEffect(hovering ? 1.03 : 1)
                .animation(.spring(duration: 0.25), value: hovering)
                .onHover { hovering = $0 }
                .onTapGesture(perform: open)
            Text(item.title).font(.callout.weight(.semibold)).lineLimit(2).onTapGesture(perform: open)
            AuthorLinks(line: item.author).font(.caption).foregroundStyle(.secondary)
            if status == .reading, let p = item.local.map(\.progress).flatMap({ $0 > 0.001 ? $0 : nil }) ?? item.hc?.progressFraction {
                HStack(spacing: 6) {
                    ProgressView(value: min(1, p)).controlSize(.mini).frame(maxWidth: 70)
                    Text("\(Int(p * 100))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            } else if let r = item.myRating {
                StarRating(rating: r, size: 9)
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Read") {
                if let local = item.local {
                    openWindow(id: "reader", value: local.id)
                } else {
                    readBook(title: item.title, author: item.author, hardcoverBookID: item.hc?.book.id ?? item.gr?.hardcoverBookID,
                             hardcoverPages: item.hc?.book.pages ?? item.gr?.pages, cover: item.cover, openWindow: openWindow)
                }
            }
            Button("Show Details", action: open)
            Divider()
            if let local = item.local {
                Menu("Move in Library") {
                    ForEach(ReadingStatus.allCases) { state in
                        Button {
                            store.setStatus(local.id, state, hardcover: hc)
                        } label: {
                            if local.status == state { Label(state == .none ? "Clear Status" : state.label, systemImage: "checkmark") }
                            else { Text(state == .none ? "Clear Status" : state.label) }
                        }
                    }
                }
                Menu("Add to Collection") {
                    ForEach(store.data.collections) { collection in
                        Button { store.toggle(local.id, in: collection.id) } label: {
                            if local.collections.contains(collection.id) { Label(collection.name, systemImage: "checkmark") }
                            else { Text(collection.name) }
                        }
                    }
                    if store.data.collections.isEmpty { Text("Create a collection in the sidebar first") }
                }
            }
            if let ub = item.hc {
                Menu("Move on Hardcover") {
                    ForEach(HCStatus.allCases) { s in
                        Button { Task { await hc.setStatus(bookID: ub.book.id, status: s) } } label: { Label(s.label, systemImage: s.symbol) }
                    }
                }
                Button("Remove from Hardcover", role: .destructive) { Task { await hc.remove(userBookID: ub.id) } }
            }
            if let local = item.local {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.fileURL(local)]) }
            }
            ForEach(Names.split(item.author).prefix(4), id: \.self) { n in
                Button("Go to \(n)") { Router.shared.open(.author(n)) }
            }
            Divider()
            if let url = item.hc?.book.webURL { Button("Open on Hardcover") { NSWorkspace.shared.open(url) } }
            if let link = item.gr?.link, let url = URL(string: link) { Button("Open on Goodreads") { NSWorkspace.shared.open(url) } }
            Button("Copy Title") { copy(item.title) }
            if let local = item.local {
                Divider()
                Button("Remove from Library", role: .destructive) { store.remove(local.id) }
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let local = item.local, local.coverFileName != nil {
            local.cover
        } else {
            CoverArt(title: item.title, author: item.author, remote: item.cover)
        }
    }

    /// Which services have this book: a small mark for each.
    private var badges: some View {
        HStack(spacing: 3) {
            if item.local != nil { mark("L", "In Library") }
            if item.hc != nil { mark("H", "On Hardcover") }
            if item.gr != nil { mark("g", "On Goodreads") }
        }
    }

    private func mark(_ letter: String, _ help: String) -> some View {
        Text(letter)
            .font(.system(size: 10, weight: .heavy, design: letter == "g" ? .serif : .rounded))
            .frame(width: 18, height: 18)
            .glassEffect(.regular, in: .circle)
            .help(help)
    }
}

// MARK: - Goodreads-only details (when Hardcover can't supply them)

struct GoodreadsBookDetail: View {
    let book: TrackedBook
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var findingSource = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 22) {
                CoverArt(title: book.title, author: book.author, remote: book.coverURL.flatMap(URL.init(string:)), cornerRadius: 8)
                    .frame(width: 140)
                VStack(alignment: .leading, spacing: 8) {
                    Text(book.title).font(.title.weight(.bold)).padding(.trailing, 40)
                    AuthorLinks(line: book.author).font(.title3).foregroundStyle(.secondary)
                    if let avg = book.averageRating, avg > 0 {
                        HStack(spacing: 4) { StarRating(rating: avg); Text(String(format: "%.2f on Goodreads", avg)) }
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if book.rating > 0 {
                        HStack(spacing: 6) { Text("Your rating").foregroundStyle(.secondary); StarRating(rating: Double(book.rating), size: 13) }
                    }
                    Label(GRShelf.from(csvShelf: book.shelf)?.label ?? book.shelf, systemImage: GRShelf.from(csvShelf: book.shelf)?.symbol ?? "bookmark")
                        .font(.callout).foregroundStyle(.secondary)
                    if let link = book.link, let url = URL(string: link) {
                        Link(destination: url) { Label("Open on Goodreads", systemImage: "safari") }.buttonStyle(.glass)
                    }
                }
            }
            if let local = store.localCopy(author: book.author, title: book.title) {
                Button {
                    openWindow(id: "reader", value: local.id)
                    PopupCenter.shared.close()
                } label: {
                    Label("Read", systemImage: "book.fill")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 28).padding(.vertical, 9)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
            } else {
                Button { findingSource.toggle() } label: {
                    Label("Find Source", systemImage: "magnifyingglass")
                        .font(.title3.weight(.semibold))
                        .padding(.horizontal, 28).padding(.vertical, 9)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                if findingSource {
                    FindCopyView(title: book.title, author: book.author, hardcoverBookID: book.hardcoverBookID,
                                 hardcoverPages: book.pages, cover: book.coverURL.flatMap(URL.init(string:)))
                }
            }
        }
        .padding(28)
        .frame(width: 620)
    }
}

// MARK: - Goodreads export

/// Builds a Goodreads-format CSV from Hardcover shelves, the local library and Goodreads books.
@MainActor
func goodreadsExportCSV(store: LibraryStore, hc: HardcoverClient) async -> String {
    var rows: [GoodreadsCSV.ExportRow] = []
    var seen = Set<String>()
    if hc.isConnected, let all = try? await hc.allUserBooks() {
        for ub in all {
            guard let s = ub.status else { continue }
            seen.insert(ShelfItem.key(ub.book.title, ub.book.authors))
            rows.append(.init(title: ub.book.title, author: Names.split(ub.book.authors).first ?? ub.book.authors, isbn13: nil,
                              rating: Int((ub.rating ?? 0).rounded()), pages: ub.book.pages, year: ub.book.year,
                              dateRead: ub.finishedAt, dateAdded: ub.dateAdded, shelf: GoodreadsCSV.shelf(for: s)))
        }
    }
    for b in store.books where b.status != .none && !seen.contains(ShelfItem.key(b.title, b.author)) {
        seen.insert(ShelfItem.key(b.title, b.author))
        rows.append(.init(title: b.title, author: b.author, isbn13: nil, rating: 0, pages: b.hardcoverPages, year: nil,
                          dateRead: b.finishedAt?.isoDay, dateAdded: b.addedAt.isoDay,
                          shelf: GoodreadsCSV.shelf(for: b.status.hardcover ?? .wantToRead)))
    }
    for t in store.data.tracked where !seen.contains(ShelfItem.key(t.title, t.author)) {
        rows.append(.init(title: t.title, author: t.author, isbn13: t.isbn13, rating: t.rating, pages: t.pages, year: t.year,
                          dateRead: t.dateRead, dateAdded: t.dateAdded, shelf: t.shelf))
    }
    return GoodreadsCSV.write(rows)
}
