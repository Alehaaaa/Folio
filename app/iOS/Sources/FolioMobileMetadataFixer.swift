import SwiftUI
import UniformTypeIdentifiers

// MARK: - Records from metadata extensions

/// One book record from a metadata source extension, as in Calibre's metadata download.
struct FolioMetadataCandidate: Identifiable, Hashable {
    let id = UUID()
    var source: String
    var title: String? = nil
    var author: String? = nil
    var summary: String? = nil
    var publisher: String? = nil
    var language: String? = nil
    var isbn: String? = nil
    var series: String? = nil
    var seriesIndex: Double? = nil
    var year: Int? = nil
    var pages: Int? = nil
    var coverURL: URL? = nil
    var genres: [String] = []
    var rating: Double? = nil

    /// A record with only what doesn't depend on language (series, author).
    var isNeutral: Bool { title == nil && coverURL == nil && summary == nil }

    init(source: String) { self.source = source }

    init?(_ d: [String: Any], fallbackSource: String) {
        func string(_ key: String) -> String? {
            guard let value = (d[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        func number(_ key: String) -> Double? { (d[key] as? NSNumber)?.doubleValue ?? string(key).flatMap(Double.init) }
        source = string("source") ?? fallbackSource
        title = string("title")
        author = string("authors") ?? string("author")
        summary = string("description")
        publisher = string("publisher")
        language = BookLanguage.code(string("language"))
        isbn = string("isbn")
        series = string("series")
        seriesIndex = number("seriesIndex")
        year = number("year").map { Int($0) }
        pages = number("pages").map { Int($0) }.flatMap { $0 > 0 ? $0 : nil }
        coverURL = string("cover").flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        genres = (d["genres"] as? [String] ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        rating = number("rating")
        if title == nil && coverURL == nil && series == nil { return nil }
    }
}

/// What Edit Details asks the sources about.
struct FolioMetadataQuery {
    var title: String
    var author: String
    var language: String?
    var isbn: String?
    var hardcoverBookID: Int?
    var hardcoverEditionID: Int?
    var series: String?
    var seriesIndex: Double?

    var payload: [String: Any] {
        var out: [String: Any] = ["title": title, "author": author]
        if let language {
            out["language"] = language
            out["languageName"] = BookLanguage.englishName(language) ?? ""
        }
        if let isbn { out["isbn"] = isbn }
        if let hardcoverBookID { out["hardcoverBookID"] = hardcoverBookID }
        if let hardcoverEditionID { out["hardcoverEditionID"] = hardcoverEditionID }
        if let series { out["series"] = series }
        if let seriesIndex { out["seriesIndex"] = seriesIndex }
        return out
    }
}

@MainActor
enum FolioMetadataSources {
    private struct Cached {
        var results: [String: [FolioMetadataCandidate]]
        var saved: Date
    }

    /// Answers from the last half hour, so reopening Edit Details shows them at once.
    private static var cache: [String: Cached] = [:]

    private static func key(_ payload: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Every enabled metadata extension at once, each in its own engine, in the reader's order.
    /// `update` gets the list again each time a source answers, so the fastest show first.
    /// A book in Spanish only gets Spanish records; others only keep their series.
    @discardableResult
    static func all(for query: FolioMetadataQuery, fresh: Bool = false,
                    update: @escaping ([FolioMetadataCandidate]) -> Void = { _ in }) async -> [FolioMetadataCandidate] {
        let store = ExtensionStore.shared
        let sources = store.metadataSources.filter(\.saved.enabled)
        let payload = query.payload
        let cacheKey = key(payload)
        func ordered(_ results: [String: [FolioMetadataCandidate]]) -> [FolioMetadataCandidate] {
            filtered(sources.flatMap { results[$0.id] ?? [] }, language: query.language)
        }
        if !fresh, let hit = cache[cacheKey], Date().timeIntervalSince(hit.saved) < 30 * 60,
           sources.allSatisfy({ hit.results[$0.id] != nil }) {
            let list = ordered(hit.results)
            update(list)
            return list
        }
        var results: [String: [FolioMetadataCandidate]] = [:]
        await withTaskGroup(of: (String, [FolioMetadataCandidate]).self) { group in
            for source in sources {
                group.addTask { @MainActor in
                    do {
                        let raw = try await store.metadata(source, for: payload)
                        return (source.id, raw.compactMap { FolioMetadataCandidate($0, fallbackSource: source.manifest.name) })
                    } catch {
                        FolioLog.log("\(source.manifest.name) failed: \(error.localizedDescription)", "metadata")
                        return (source.id, [])
                    }
                }
            }
            for await (id, found) in group {
                results[id] = found
                let list = ordered(results)
                // Start the covers downloading while the other sources are still answering.
                for url in found.compactMap(\.coverURL).prefix(8) {
                    Task.detached(priority: .utility) { _ = await FolioImageCache.shared.load(url) }
                }
                update(list)
            }
        }
        cache[cacheKey] = Cached(results: results, saved: Date())
        return ordered(results)
    }

    private static func filtered(_ all: [FolioMetadataCandidate], language: String?) -> [FolioMetadataCandidate] {
        guard let language else { return all }
        return all.compactMap { candidate in
            // Catalogs default to English, so English books also keep unlabelled records.
            if candidate.language == language || (language == "en" && candidate.language == nil) { return candidate }
            guard candidate.series != nil else { return nil }
            var neutral = FolioMetadataCandidate(source: candidate.source)
            neutral.series = candidate.series
            neutral.seriesIndex = candidate.seriesIndex
            neutral.author = candidate.author
            return neutral
        }
    }
}

// MARK: - Edit Details

/// The one editor for a book's details, for library files and for books outside the
/// library alike. Every field can be typed, and a list of matching records from the
/// metadata extensions (in the book's language) fills the fields only when one is tapped.
struct FolioMobileEditDetails: View {
    enum Target {
        case library(UUID)
        case remote(HCBook, editionID: Int?)
    }

    let target: Target

    init(bookID: UUID) { target = .library(bookID) }
    init(remote book: HCBook, editionID: Int?) { target = .remote(book, editionID: editionID) }

    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var overrides = FolioBookOverrides.shared
    @State private var extensions = ExtensionStore.shared
    @State private var candidates: [FolioMetadataCandidate] = []
    @State private var loading = true
    @State private var saving = false
    @State private var failure: String?
    @State private var writeFile = true
    @State private var editingSources = false
    @State private var choosingCoverFile = false
    @State private var applied: UUID?

    @State private var title = ""
    @State private var author = ""
    @State private var summary = ""
    @State private var publisher = ""
    @State private var language = ""
    @State private var isbn = ""
    @State private var series = ""
    @State private var seriesIndex = ""
    @State private var year = ""
    @State private var pages = ""
    @State private var genres = ""
    /// nil keeps the current cover.
    @State private var cover: URL?
    @State private var extraCovers: [URL] = []

    private var localBook: LocalBook? {
        if case .library(let id) = target { return library.book(id) }
        return nil
    }

    private var remoteBook: HCBook? {
        if case .remote(let book, _) = target { return book }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                coverSection
                suggestionsSection
                Section("Book") {
                    TextField("Title", text: $title)
                    TextField("Author", text: $author)
                }
                .folioRow()
                Section("Description") {
                    TextField("Description", text: $summary, axis: .vertical).lineLimit(3...12)
                }
                .folioRow()
                Section("Series") {
                    TextField("Series", text: $series)
                    TextField("Number in series", text: $seriesIndex).keyboardType(.decimalPad)
                }
                .folioRow()
                Section("Publication") {
                    TextField("Publisher", text: $publisher)
                    TextField("Year", text: $year).keyboardType(.numberPad)
                    TextField("Pages", text: $pages).keyboardType(.numberPad)
                    TextField("Language", text: $language)
                    TextField("ISBN", text: $isbn).keyboardType(.numberPad)
                }
                .folioRow()
                Section {
                    TextField("Genres", text: $genres, axis: .vertical)
                } header: {
                    Text("Genres")
                } footer: {
                    Text("Separated by commas.")
                }
                .folioRow()
                if localBook?.format == .epub {
                    Section {
                        Toggle("Write into the EPUB file", isOn: $writeFile)
                    } footer: {
                        Text("The original file is kept in EPUB Backups.")
                    }
                    .folioRow()
                }
                if let book = remoteBook, overrides.override(for: book.id) != nil {
                    Section {
                        Button("Restore Hardcover's Details", role: .destructive) {
                            overrides.set(nil, for: book.id)
                            dismiss()
                        }
                    } footer: {
                        Text("Your changes stay on this device and don't change Hardcover.")
                    }
                    .folioRow()
                }
                if let failure {
                    Text(failure).foregroundStyle(FolioTheme.danger).folioRow()
                }
            }
            .folioScreen()
            .navigationTitle("Edit Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save() } }.disabled(title.isEmpty) }
                }
            }
            .sheet(isPresented: $editingSources) {
                FolioMetadataSourcesEditor { Task { await search() } }
            }
            .fileImporter(isPresented: $choosingCoverFile, allowedContentTypes: [.image]) { result in
                if case .success(let url) = result, let copy = Self.keepCover(url) {
                    extraCovers.insert(copy, at: 0)
                    cover = copy
                }
            }
            .task { await start() }
        }
    }

    // MARK: Sections

    private var currentCoverURL: URL? {
        if let localBook { return library.coverURL(localBook) }
        return remoteBook.map { overrides.apply($0).imageURL } ?? nil
    }

    private var coverOptions: [URL] {
        var seen = Set<URL>()
        if let currentCoverURL { seen.insert(currentCoverURL) }
        return (extraCovers + candidates.compactMap(\.coverURL)).filter { seen.insert($0).inserted }
    }

    private var coverSection: some View {
        Section("Cover") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button { cover = nil } label: {
                        Group {
                            if let localBook {
                                FolioMobileCover(book: localBook)
                            } else {
                                FolioMobileRemoteCover(url: currentCoverURL, title: title)
                            }
                        }
                        .frame(width: 78, height: 114)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay { ring(cover == nil) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Keep the current cover")
                    ForEach(coverOptions, id: \.self) { url in
                        Button { cover = url } label: {
                            FolioMobileRemoteCover(url: url, title: title)
                                .frame(width: 78, height: 114)
                                .overlay { ring(cover == url) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(cover == url ? "Chosen cover" : "Use this cover")
                    }
                    if loading { ProgressView().frame(width: 78, height: 114) }
                }
                .padding(.vertical, 4)
            }
            Button("Choose from Files", systemImage: "photo.on.rectangle") { choosingCoverFile = true }
        }
        .folioRow()
    }

    private func ring(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7).strokeBorder(selected ? FolioTheme.olive : .clear, lineWidth: 3)
    }

    /// Whole records from the sources; tapping one fills every field it has.
    private var suggestionsSection: some View {
        Section {
            if loading && candidates.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching \(enabledNames)").font(.footnote).foregroundStyle(.secondary)
                }
            } else if candidates.filter({ !$0.isNeutral }).isEmpty {
                Text(enabledNames.isEmpty ? "No metadata sources are turned on." : "No matches in this book's language.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(candidates.filter { !$0.isNeutral }) { candidate in
                Button { fill(from: candidate) } label: { suggestionRow(candidate) }
                    .buttonStyle(.plain)
            }
            Button("Sources", systemImage: "list.number") { editingSources = true }
                .font(.footnote)
        } header: {
            Text("Suggested Matches")
        } footer: {
            Text("Tap a match to fill the fields with it. Nothing changes until you save.")
        }
        .folioRow()
    }

    private var enabledNames: String {
        extensions.metadataSources.filter(\.saved.enabled).map(\.manifest.name).formatted(.list(type: .and))
    }

    private func suggestionRow(_ c: FolioMetadataCandidate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            FolioMobileRemoteCover(url: c.coverURL, title: c.title ?? title)
                .frame(width: 46, height: 68)
            VStack(alignment: .leading, spacing: 3) {
                Text(c.title ?? "Untitled")
                    .font(.system(.subheadline, design: .serif).weight(.semibold))
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(2)
                if let author = c.author { Text(author).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                let facts = [c.publisher, c.year.map(String.init), c.pages.map { "\($0) pages" },
                             c.language.map(BookLanguage.displayName)].compactMap { $0 }
                if !facts.isEmpty {
                    Text(facts.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Text(c.source).font(.caption2.weight(.semibold)).foregroundStyle(FolioTheme.olive)
            }
            Spacer(minLength: 0)
            if applied == c.id {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(FolioTheme.olive)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Fills the fields with this match")
    }

    private func fill(from c: FolioMetadataCandidate) {
        if let v = c.title { title = v }
        if let v = c.author { author = v }
        if let v = c.summary { summary = v.plainText }
        if let v = c.publisher { publisher = v }
        if let v = c.year { year = String(v) }
        if let v = c.pages { pages = String(v) }
        if let v = c.language { language = v }
        if let v = c.isbn { isbn = v }
        if let v = c.series { series = v }
        if let v = c.seriesIndex { seriesIndex = v.formatted() }
        if !c.genres.isEmpty { genres = c.genres.joined(separator: ", ") }
        if let v = c.coverURL { cover = v }
        withAnimation(.easeInOut(duration: 0.15)) { applied = c.id }
    }

    // MARK: Loading and saving

    @MainActor
    private func start() async {
        if let book = localBook {
            title = book.title
            author = book.author
            summary = book.summary?.plainText ?? ""
            publisher = book.publisher ?? ""
            language = book.language ?? ""
            isbn = book.isbn ?? ""
            series = book.series ?? ""
            seriesIndex = book.seriesIndex.map { $0.formatted() } ?? ""
            year = book.publishedYear.map(String.init) ?? ""
            pages = book.hardcoverPages.map(String.init) ?? ""
            genres = (book.genres ?? []).joined(separator: ", ")
            writeFile = book.format == .epub
        } else if let book = remoteBook {
            let shown = overrides.apply(book)
            let o = overrides.override(for: book.id)
            title = shown.title
            author = shown.authors
            summary = shown.description?.plainText ?? ""
            publisher = o?.publisher ?? ""
            language = o?.language ?? BookLanguage.reading
            isbn = o?.isbn ?? ""
            series = o?.series ?? ""
            seriesIndex = o?.seriesIndex.map { $0.formatted() } ?? ""
            year = (o?.year ?? book.year).map(String.init) ?? ""
            pages = (o?.pages ?? book.pages).map(String.init) ?? ""
            genres = (o?.genres ?? []).joined(separator: ", ")
        }
        await search()
    }

    @MainActor
    private func search() async {
        loading = true
        defer { loading = false }
        let query: FolioMetadataQuery
        switch target {
        case .library(let id):
            guard let book = library.book(id) else { return }
            query = FolioMetadataQuery(
                title: book.title, author: book.author,
                language: library.ensureLanguage(id) ?? BookLanguage.code(book.language),
                isbn: book.isbn, hardcoverBookID: book.hardcoverBookID, hardcoverEditionID: book.hardcoverEditionID,
                series: book.series, seriesIndex: book.seriesIndex)
        case .remote(let book, let editionID):
            query = FolioMetadataQuery(
                title: book.title, author: book.authors, language: BookLanguage.code(language) ?? BookLanguage.reading,
                hardcoverBookID: book.id > 0 ? book.id : nil, hardcoverEditionID: editionID)
        }
        await FolioMetadataSources.all(for: query) { list in
            withAnimation(.easeInOut(duration: 0.15)) { candidates = list }
        }
    }

    private func clean(_ value: String) -> String? {
        let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private var genreList: [String] {
        genres.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    @MainActor
    private func save() async {
        saving = true
        failure = nil
        defer { saving = false }
        let number = clean(seriesIndex).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) }
        switch target {
        case .library(let id):
            let choice = LibraryStore.MetadataChoice(
                title: title, author: author, summary: clean(summary), publisher: clean(publisher),
                language: clean(language).flatMap { BookLanguage.code($0) ?? $0 }, isbn: clean(isbn),
                series: clean(series), seriesIndex: number,
                year: clean(year).flatMap(Int.init), pages: clean(pages).flatMap(Int.init), coverURL: cover,
                genres: genreList)
            do {
                try await library.applyMetadata(id, choice, writeFile: writeFile && localBook?.format == .epub)
                dismiss()
            } catch {
                failure = error.localizedDescription
            }
        case .remote(let book, _):
            func changed(_ value: String, from original: String?) -> String? {
                guard let t = clean(value) else { return nil }
                return t == (original ?? "").trimmingCharacters(in: .whitespacesAndNewlines) ? nil : t
            }
            overrides.set(FolioBookOverride(
                title: changed(title, from: book.title),
                authors: changed(author, from: book.authors),
                summary: changed(summary, from: book.description?.plainText),
                coverURL: cover ?? overrides.override(for: book.id)?.coverURL,
                publisher: clean(publisher),
                year: clean(year).flatMap(Int.init).flatMap { $0 == book.year ? nil : $0 },
                pages: clean(pages).flatMap(Int.init).flatMap { $0 == book.pages ? nil : $0 },
                language: clean(language).flatMap { BookLanguage.code($0) },
                isbn: clean(isbn), series: clean(series), seriesIndex: number,
                genres: genreList.isEmpty ? nil : genreList), for: book.id)
            dismiss()
        }
    }

    /// Copies a picked image into the app, so it stays readable after the picker closes.
    static func keepCover(_ url: URL) -> URL? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-picked-covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString + "." + (url.pathExtension.isEmpty ? "jpg" : url.pathExtension))
        do {
            try FileManager.default.copyItem(at: url, to: dest)
            return dest
        } catch {
            return nil
        }
    }
}

// MARK: - Source preferences

/// Which metadata extensions Edit Details asks, and in what order.
struct FolioMetadataSourcesEditor: View {
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var extensions = ExtensionStore.shared
    @State private var order: [String] = ExtensionStore.shared.metadataSources.map(\.id)

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order, id: \.self) { id in
                        if let source = extensions.ext(id) {
                            Toggle(isOn: Binding(
                                get: { extensions.ext(id)?.saved.enabled ?? false },
                                set: { on in extensions.update(id) { $0.enabled = on } }
                            )) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.manifest.name)
                                    Text(source.manifest.description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Each source is a JavaScript extension. Drag to set the order of suggestions; only matches in the book's own language are shown. Add more in Settings › Sources.")
                }
                .folioRow()
            }
            .environment(\.editMode, .constant(.active))
            .folioScreen()
            .navigationTitle("Metadata Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        extensions.setMetadataOrder(order)
                        onChange()
                        dismiss()
                    }
                }
            }
        }
    }
}
