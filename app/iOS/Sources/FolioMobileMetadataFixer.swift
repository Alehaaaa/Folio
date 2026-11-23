import SwiftUI

// MARK: - Candidates from metadata sources

/// One source's idea of a book's metadata, as in Calibre's metadata download.
struct FolioMetadataCandidate: Identifiable, Hashable {
    let id = UUID()
    var source: String
    var title: String?
    var author: String?
    var summary: String?
    var publisher: String?
    var language: String?
    var isbn: String?
    var series: String?
    var seriesIndex: Double?
    var year: Int?
    var pages: Int?
    var coverURL: URL?
}

extension HardcoverClient {
    /// Editions of a book, in a language when given, most-read first.
    func editions(bookID: Int, language code: String?, limit: Int = 12) async throws -> [HCEdition] {
        if let code, let name = BookLanguage.englishName(code) {
            let d = try await query("""
            query EditionsLang($id: Int!, $lang: String!, $n: Int!) { editions(where: {book_id: {_eq: $id}, language: {language: {_eq: $lang}}}, order_by: {users_count: desc}, limit: $n) { \(Self.editionFields) } }
            """, ["id": bookID, "lang": name, "n": limit])
            let found = d["editions"].array.map(Self.edition(from:))
            if !found.isEmpty { return found }
        }
        let d = try await query("""
        query Editions($id: Int!, $n: Int!) { editions(where: {book_id: {_eq: $id}}, order_by: {users_count: desc}, limit: $n) { \(Self.editionFields) } }
        """, ["id": bookID, "n": limit])
        return d["editions"].array.map(Self.edition(from:))
    }
}

@MainActor
enum FolioMetadataSources {
    /// Every source at once: Hardcover (the work and its editions in the book's
    /// language), Google Books and Open Library.
    static func all(for book: LocalBook, hardcover: HardcoverClient) async -> [FolioMetadataCandidate] {
        async let google = googleBooks(title: book.title, author: book.author, language: book.language)
        async let openLibrary = openLibrary(title: book.title, author: book.author)
        let fromHardcover = await self.hardcover(book, client: hardcover)
        return fromHardcover + (await google) + (await openLibrary)
    }

    static func hardcover(_ book: LocalBook, client: HardcoverClient) async -> [FolioMetadataCandidate] {
        guard client.isConnected else { return [] }
        var workID = book.hardcoverBookID
        if workID == nil {
            workID = await FolioHardcoverMatch.find(title: book.title, author: book.author, hardcover: client)?.id
        }
        if workID == nil, let language = book.language, language != "en" {
            workID = await client.translatedBook(title: book.title, author: book.author,
                                                 series: book.series, seriesIndex: book.seriesIndex)?.id
        }
        guard let workID, let work = try? await client.book(id: workID) else { return [] }
        let series = (try? await client.series(forBook: workID))?.first
        var out: [FolioMetadataCandidate] = []
        let editions = (try? await client.editions(bookID: workID, language: book.language)) ?? []
        for edition in editions {
            out.append(FolioMetadataCandidate(
                source: "Hardcover · \(edition.format?.capitalized ?? "Edition")",
                title: edition.title, author: work.authors, summary: nil, publisher: edition.publisher,
                language: BookLanguage.code(edition.language), isbn: edition.isbn13 ?? edition.isbn10,
                series: nil, seriesIndex: nil,
                year: edition.releaseDate.flatMap { Int($0.prefix(4)) }, pages: edition.pages,
                coverURL: edition.imageURL))
        }
        // The work itself: original title, description, series and the best-known cover.
        out.insert(FolioMetadataCandidate(
            source: "Hardcover", title: work.title, author: work.authors, summary: work.description,
            publisher: nil, language: nil, isbn: nil, series: series?.name, seriesIndex: series?.position,
            year: work.year, pages: work.pages, coverURL: work.imageURL), at: 0)
        return out
    }

    static func googleBooks(title: String, author: String, language: String?) async -> [FolioMetadataCandidate] {
        let surname = FolioAuthorNames.split(author).first?.split(separator: " ").last.map(String.init) ?? author
        var components = URLComponents(string: "https://www.googleapis.com/books/v1/volumes")!
        var items = [URLQueryItem(name: "q", value: "intitle:\(FolioHardcoverMatch.plainTitle(title)) inauthor:\(surname)"),
                     URLQueryItem(name: "maxResults", value: "8"),
                     URLQueryItem(name: "printType", value: "books")]
        if let language { items.append(URLQueryItem(name: "langRestrict", value: language)) }
        components.queryItems = items
        guard let url = components.url, let json = await fetchJSON(url),
              let volumes = json["items"] as? [[String: Any]] else { return [] }
        return volumes.compactMap { volume in
            guard let info = volume["volumeInfo"] as? [String: Any], let name = info["title"] as? String else { return nil }
            let ids = (info["industryIdentifiers"] as? [[String: Any]]) ?? []
            let isbn = ids.first { ($0["type"] as? String) == "ISBN_13" }?["identifier"] as? String
                ?? ids.first { ($0["type"] as? String) == "ISBN_10" }?["identifier"] as? String
            var cover: URL?
            if let links = info["imageLinks"] as? [String: Any],
               let raw = (links["thumbnail"] ?? links["smallThumbnail"]) as? String {
                let secure = raw.replacingOccurrences(of: "http://", with: "https://")
                    .replacingOccurrences(of: "&edge=curl", with: "")
                cover = URL(string: secure + "&fife=w800-h1200")
            }
            let subtitle = (info["subtitle"] as? String).map { ": \($0)" } ?? ""
            return FolioMetadataCandidate(
                source: "Google Books", title: name + subtitle,
                author: (info["authors"] as? [String])?.joined(separator: ", "),
                summary: info["description"] as? String, publisher: info["publisher"] as? String,
                language: BookLanguage.code(info["language"] as? String), isbn: isbn, series: nil, seriesIndex: nil,
                year: (info["publishedDate"] as? String).flatMap { Int($0.prefix(4)) },
                pages: info["pageCount"] as? Int, coverURL: cover)
        }
    }

    static func openLibrary(title: String, author: String) async -> [FolioMetadataCandidate] {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        components.queryItems = [
            URLQueryItem(name: "title", value: FolioHardcoverMatch.plainTitle(title)),
            URLQueryItem(name: "author", value: FolioAuthorNames.split(author).first ?? author),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "fields", value: "title,author_name,first_publish_year,publisher,isbn,cover_i,language,number_of_pages_median")
        ]
        guard let url = components.url, let json = await fetchJSON(url),
              let docs = json["docs"] as? [[String: Any]] else { return [] }
        return docs.compactMap { doc in
            guard let name = doc["title"] as? String else { return nil }
            let cover = (doc["cover_i"] as? Int).flatMap { URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") }
            return FolioMetadataCandidate(
                source: "Open Library", title: name, author: (doc["author_name"] as? [String])?.joined(separator: ", "),
                summary: nil, publisher: (doc["publisher"] as? [String])?.first,
                language: (doc["language"] as? [String])?.first.flatMap { BookLanguage.code($0) },
                isbn: (doc["isbn"] as? [String])?.first { $0.count == 13 }, series: nil, seriesIndex: nil,
                year: doc["first_publish_year"] as? Int, pages: doc["number_of_pages_median"] as? Int, coverURL: cover)
        }
    }

    private static func fetchJSON(_ url: URL) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Folio/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

// MARK: - Single-book editor

/// Calibre-style metadata editing: every field is editable, each shows what the
/// sources say (tap one to use it), covers are picked from all sources, and the
/// result can be written into the EPUB itself.
struct FolioMobileMetadataFixer: View {
    let bookID: UUID

    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [FolioMetadataCandidate] = []
    @State private var loading = true
    @State private var saving = false
    @State private var failure: String?
    @State private var writeFile = true
    @State private var expandedSummaries = false

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
    /// nil keeps the current cover.
    @State private var cover: URL?

    private var book: LocalBook? { library.book(bookID) }

    var body: some View {
        NavigationStack {
            Form {
                coverSection
                field("Title", text: $title, values: candidates.compactMap { c in c.title.map { (c.source, $0) } })
                field("Author", text: $author, values: candidates.compactMap { c in c.author.map { (c.source, $0) } })
                summarySection
                field("Series", text: $series, values: candidates.compactMap { c in c.series.map { (c.source, $0) } })
                field("Number in series", text: $seriesIndex, keyboard: .decimalPad,
                      values: candidates.compactMap { c in c.seriesIndex.map { (c.source, $0.formatted()) } })
                field("Publisher", text: $publisher, values: candidates.compactMap { c in c.publisher.map { (c.source, $0) } })
                field("Year", text: $year, keyboard: .numberPad,
                      values: candidates.compactMap { c in c.year.map { (c.source, String($0)) } })
                field("Pages", text: $pages, keyboard: .numberPad,
                      values: candidates.compactMap { c in c.pages.map { (c.source, String($0)) } })
                field("Language", text: $language,
                      values: candidates.compactMap { c in c.language.map { (c.source, $0) } })
                field("ISBN", text: $isbn, keyboard: .numberPad,
                      values: candidates.compactMap { c in c.isbn.map { (c.source, $0) } })
                if book?.format == .epub {
                    Section {
                        Toggle("Write into the EPUB file", isOn: $writeFile)
                    } footer: {
                        Text("The original file is kept in EPUB Backups.")
                    }
                    .folioRow()
                }
                if let failure {
                    Text(failure).foregroundStyle(FolioTheme.danger).folioRow()
                }
            }
            .folioScreen()
            .navigationTitle("Fix Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("Save") { Task { await save() } }.disabled(title.isEmpty) }
                }
            }
            .overlay(alignment: .top) {
                if loading {
                    Label("Searching Hardcover, Google Books and Open Library", systemImage: "magnifyingglass")
                        .font(.footnote)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(FolioTheme.cream, in: Capsule())
                        .padding(.top, 6)
                }
            }
            .task { await start() }
        }
    }

    // MARK: Sections

    private var coverOptions: [URL] {
        var seen = Set<URL>()
        return candidates.compactMap(\.coverURL).filter { seen.insert($0).inserted }
    }

    private var coverSection: some View {
        Section("Cover") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    Button { cover = nil } label: {
                        Group {
                            if let book { FolioMobileCover(book: book) } else { Color.clear }
                        }
                        .frame(width: 78, height: 114)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay { coverRing(cover == nil) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Keep the current cover")
                    ForEach(coverOptions, id: \.self) { url in
                        Button { cover = url } label: {
                            FolioMobileRemoteCover(url: url, title: title)
                                .frame(width: 78, height: 114)
                                .overlay { coverRing(cover == url) }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use this cover")
                    }
                    if loading { ProgressView().frame(width: 78, height: 114) }
                }
                .padding(.vertical, 4)
            }
        }
        .folioRow()
    }

    private func coverRing(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 7)
            .strokeBorder(selected ? FolioTheme.olive : .clear, lineWidth: 3)
    }

    /// An editable field with the distinct values the sources suggest, as chips.
    private func field(_ name: String, text: Binding<String>, keyboard: UIKeyboardType = .default,
                       values: [(String, String)]) -> some View {
        Section(name) {
            TextField(name, text: text)
                .keyboardType(keyboard)
            let distinct = uniqueValues(values, current: text.wrappedValue)
            if !distinct.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(distinct, id: \.1) { source, value in
                            Button { text.wrappedValue = value } label: {
                                HStack(spacing: 5) {
                                    Text(value).lineLimit(1)
                                    Text(source).foregroundStyle(.secondary)
                                }
                                .font(.footnote)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(FolioTheme.sage, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .folioRow()
    }

    private var summarySection: some View {
        Section("Description") {
            TextField("Description", text: $summary, axis: .vertical)
                .lineLimit(3...10)
            let options = uniqueValues(candidates.compactMap { c in c.summary.map { (c.source, $0.plainText) } },
                                       current: summary)
            ForEach(options.prefix(expandedSummaries ? 6 : 2), id: \.1) { source, value in
                Button { summary = value } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source).font(.caption.weight(.semibold)).foregroundStyle(FolioTheme.olive)
                        Text(value).font(.footnote).foregroundStyle(.primary).lineLimit(4)
                    }
                }
                .buttonStyle(.plain)
            }
            if options.count > 2 && !expandedSummaries {
                Button("More descriptions") { expandedSummaries = true }.font(.footnote)
            }
        }
        .folioRow()
    }

    private func uniqueValues(_ values: [(String, String)], current: String) -> [(String, String)] {
        var seen: Set<String> = [current.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)]
        return values.filter { _, value in
            let key = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            return !key.isEmpty && seen.insert(key).inserted
        }
    }

    // MARK: Loading and saving

    @MainActor
    private func start() async {
        guard let book else { return }
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
        writeFile = book.format == .epub
        candidates = await FolioMetadataSources.all(for: book, hardcover: hardcover)
        loading = false
    }

    @MainActor
    private func save() async {
        func clean(_ value: String) -> String? {
            let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
        saving = true
        failure = nil
        defer { saving = false }
        let choice = LibraryStore.MetadataChoice(
            title: title, author: author, summary: clean(summary), publisher: clean(publisher),
            language: clean(language).flatMap { BookLanguage.code($0) ?? $0 }, isbn: clean(isbn),
            series: clean(series), seriesIndex: clean(seriesIndex).flatMap { Double($0.replacingOccurrences(of: ",", with: ".")) },
            year: clean(year).flatMap(Int.init), pages: clean(pages).flatMap(Int.init), coverURL: cover)
        do {
            try await library.applyMetadata(bookID, choice, writeFile: writeFile)
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}

// MARK: - Whole library

/// Fills in what's missing across the library, Calibre's bulk metadata download:
/// existing values are kept, gaps are filled from the best source.
struct FolioMobileBulkMetadataFixer: View {
    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(\.dismiss) private var dismiss
    @State private var writeFiles = true
    @State private var running = false
    @State private var done: [UUID: String] = [:]

    private var needing: [LocalBook] {
        library.books.filter { b in
            b.coverFileName == nil || (b.summary ?? "").isEmpty || (b.publisher ?? "").isEmpty
                || b.publishedYear == nil || (b.language ?? "").isEmpty
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle("Write into EPUB files", isOn: $writeFiles).disabled(running)
                } footer: {
                    Text("Fills only empty fields and missing covers. Originals are kept in EPUB Backups.")
                }
                .folioRow()
                Section("\(needing.count) books with gaps") {
                    ForEach(needing) { book in
                        HStack {
                            Text(book.title).lineLimit(1)
                            Spacer()
                            if let status = done[book.id] {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            } else if running {
                                ProgressView().controlSize(.small)
                            }
                        }
                    }
                }
                .folioRow()
            }
            .folioScreen()
            .navigationTitle("Fix Library Metadata")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(running ? "Close" : "Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fill Gaps") { Task { await run() } }.disabled(running || needing.isEmpty)
                }
            }
        }
    }

    @MainActor
    private func run() async {
        running = true
        defer { running = false }
        for book in needing where done[book.id] == nil {
            let found = await FolioMetadataSources.all(for: book, hardcover: hardcover)
            func first<T>(_ path: KeyPath<FolioMetadataCandidate, T?>) -> T? { found.lazy.compactMap { $0[keyPath: path] }.first }
            let summary = (book.summary ?? "").isEmpty ? first(\.summary)?.plainText : book.summary
            let choice = LibraryStore.MetadataChoice(
                title: book.title, author: book.author, summary: summary,
                publisher: (book.publisher ?? "").isEmpty ? first(\.publisher) : book.publisher,
                language: (book.language ?? "").isEmpty ? first(\.language) : book.language,
                isbn: book.isbn ?? first(\.isbn),
                series: book.series ?? first(\.series), seriesIndex: book.seriesIndex ?? first(\.seriesIndex),
                year: book.publishedYear ?? first(\.year), pages: book.hardcoverPages ?? first(\.pages),
                coverURL: book.coverFileName == nil ? first(\.coverURL) : nil)
            do {
                try await library.applyMetadata(book.id, choice, writeFile: writeFiles && book.format == .epub)
                done[book.id] = found.isEmpty ? "No match" : "Updated"
            } catch {
                done[book.id] = "Failed"
            }
            // Stay well within Hardcover's request limits.
            try? await Task.sleep(for: .seconds(1))
        }
    }
}
