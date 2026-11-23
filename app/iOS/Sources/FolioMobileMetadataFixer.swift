import SwiftUI

// MARK: - Candidates from metadata sources

/// One source's idea of a book's metadata, as in Calibre's metadata download.
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
}

extension HardcoverClient {
    /// Editions of a book, in a language when given, most-read first.
    func editions(bookID: Int, language code: String?, limit: Int = 12) async throws -> [HCEdition] {
        if let code, let filter = BookLanguage.hardcoverFilter(code) {
            let d = try await query("""
            query EditionsLang($id: Int!, $n: Int!) { editions(where: {book_id: {_eq: $id}, \(filter)}, order_by: {users_count: desc}, limit: $n) { \(Self.editionFields) } }
            """, ["id": bookID, "n": limit])
            let found = d["editions"].array.map(Self.edition(from:))
            if !found.isEmpty { return found }
        }
        let d = try await query("""
        query Editions($id: Int!, $n: Int!) { editions(where: {book_id: {_eq: $id}}, order_by: {users_count: desc}, limit: $n) { \(Self.editionFields) } }
        """, ["id": bookID, "n": limit])
        return d["editions"].array.map(Self.edition(from:))
    }
}

/// The metadata sources, in the reader's order of preference (as Calibre's source list).
enum FolioMetadataSource: String, CaseIterable, Identifiable {
    case hardcover, amazon, googleBooks, openLibrary
    var id: String { rawValue }

    var name: String {
        switch self {
        case .hardcover: "Hardcover"
        case .amazon: "Amazon"
        case .googleBooks: "Google Books"
        case .openLibrary: "Open Library"
        }
    }

    var note: String {
        switch self {
        case .hardcover: "Editions in the book's language, series"
        case .amazon: "The store for the book's language: amazon.es, .fr, .de…"
        case .googleBooks: "Descriptions and covers in the book's language"
        case .openLibrary: "Editions and covers in the book's language"
        }
    }

    private static let orderKey = "folio.metadataSources.order"
    private static let disabledKey = "folio.metadataSources.disabled"

    /// Every source, in the saved order.
    static var ordered: [FolioMetadataSource] {
        let saved = (UserDefaults.standard.string(forKey: orderKey) ?? "").split(separator: ",")
            .compactMap { FolioMetadataSource(rawValue: String($0)) }
        return saved + allCases.filter { !saved.contains($0) }
    }

    static var disabled: Set<FolioMetadataSource> {
        Set((UserDefaults.standard.string(forKey: disabledKey) ?? "").split(separator: ",")
            .compactMap { FolioMetadataSource(rawValue: String($0)) })
    }

    static var enabled: [FolioMetadataSource] { ordered.filter { !disabled.contains($0) } }

    static func save(order: [FolioMetadataSource], disabled: Set<FolioMetadataSource>) {
        UserDefaults.standard.set(order.map(\.rawValue).joined(separator: ","), forKey: orderKey)
        UserDefaults.standard.set(disabled.map(\.rawValue).joined(separator: ","), forKey: disabledKey)
    }
}

@MainActor
enum FolioMetadataSources {
    /// Every enabled source at once, in the reader's order. A book in Spanish only
    /// gets Spanish data: other-language editions are left out, and the original
    /// work only offers its series (which is the same in every language).
    static func all(for input: LocalBook, hardcover: HardcoverClient) async -> [FolioMetadataCandidate] {
        // Know the file's language first, so every source answers with that edition.
        let detected = LibraryStore.shared.ensureLanguage(input.id) ?? input.language
        let book: LocalBook = {
            var b = input
            b.language = detected
            return b
        }()
        let enabled = FolioMetadataSource.enabled
        async let google = enabled.contains(.googleBooks)
            ? googleBooks(title: book.title, author: book.author, language: book.language) : []
        async let openLibrary = enabled.contains(.openLibrary)
            ? openLibrary(title: book.title, author: book.author, language: book.language) : []
        async let amazon = enabled.contains(.amazon)
            ? amazon(title: book.title, author: book.author, language: book.language) : []
        let fromHardcover = enabled.contains(.hardcover) ? await self.hardcover(book, client: hardcover) : []
        let results: [FolioMetadataSource: [FolioMetadataCandidate]] = [
            .hardcover: fromHardcover, .googleBooks: await google, .openLibrary: await openLibrary, .amazon: await amazon
        ]
        let all = enabled.flatMap { results[$0] ?? [] }
        guard let language = book.language else { return all }
        return all.compactMap { candidate in
            // Catalogs default to English, so English books also keep unlabelled results.
            if candidate.language == language || (language == "en" && candidate.language == nil) { return candidate }
            // Unknown or other language: keep only what doesn't depend on language.
            guard candidate.series != nil else { return nil }
            var neutral = FolioMetadataCandidate(source: candidate.source)
            neutral.series = candidate.series
            neutral.seriesIndex = candidate.seriesIndex
            neutral.author = candidate.author
            return neutral
        }
    }

    /// Amazon's store for a language, as Calibre picks one.
    static func amazonHost(_ language: String?) -> String {
        switch language {
        case "es": "www.amazon.es"
        case "fr": "www.amazon.fr"
        case "de": "www.amazon.de"
        case "it": "www.amazon.it"
        case "nl": "www.amazon.nl"
        case "pt": "www.amazon.com.br"
        case "ja": "www.amazon.co.jp"
        case "sv": "www.amazon.se"
        case "pl": "www.amazon.pl"
        case "tr": "www.amazon.com.tr"
        default: "www.amazon.com"
        }
    }

    /// Book search on the Amazon store for the book's language: titles and full-size covers.
    /// Amazon has no public API, so this reads the search page and gives up quietly when blocked.
    static func amazon(title: String, author: String, language: String?) async -> [FolioMetadataCandidate] {
        let host = amazonHost(language)
        var components = URLComponents(string: "https://\(host)/s")!
        let surname = FolioAuthorNames.split(author).first ?? author
        components.queryItems = [URLQueryItem(name: "k", value: "\(FolioHardcoverMatch.plainTitle(title)) \(surname)"),
                                 URLQueryItem(name: "i", value: "stripbooks")]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("\(language ?? "en"),en;q=0.5", forHTTPHeaderField: "Accept-Language")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: data, encoding: .utf8) else {
            FolioLog.log("Amazon (\(host)) gave no results", "metadata")
            return []
        }
        let wanted = Set(BookAutoMatch.words(title))
        let pattern = #"<img[^>]*class="s-image"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [FolioMetadataCandidate] = []
        var seen = Set<String>()
        for match in regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).prefix(16) {
            guard let range = Range(match.range, in: html) else { continue }
            let tag = String(html[range])
            guard let src = attribute("src", in: tag), let alt = attribute("alt", in: tag) else { continue }
            let name = decodeEntities(alt)
            // Only results that are this book: most of its title words must appear.
            let words = Set(BookAutoMatch.words(name))
            guard !wanted.isEmpty, Double(wanted.intersection(words).count) / Double(wanted.count) >= 0.6 else { continue }
            // "…/I/81abc._AC_UY218_.jpg" is a thumbnail; without the size suffix it is the full cover.
            let full = src.replacingOccurrences(of: #"\._[^/]*_\."#, with: ".", options: .regularExpression)
            guard seen.insert(full).inserted, let cover = URL(string: full) else { continue }
            out.append(FolioMetadataCandidate(source: "Amazon \(host.replacingOccurrences(of: "www.amazon", with: ""))",
                                              title: name, language: language, coverURL: cover))
            if out.count >= 5 { break }
        }
        return out
    }

    private static func attribute(_ name: String, in tag: String) -> String? {
        guard let range = tag.range(of: #"\b"# + name + #"="([^"]*)""#, options: .regularExpression) else { return nil }
        let value = tag[range].dropFirst(name.count + 2).dropLast()
        return value.isEmpty ? nil : String(value)
    }

    private static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, value) in ["&amp;": "&", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">"] {
            out = out.replacingOccurrences(of: entity, with: value)
        }
        return out
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
        var editions = (try? await client.editions(bookID: workID, language: book.language)) ?? []
        // The edition this file is linked to (or marked as reading on Hardcover) leads.
        if let linked = book.hardcoverEditionID {
            if let index = editions.firstIndex(where: { $0.id == linked }) {
                editions.insert(editions.remove(at: index), at: 0)
            } else if let edition = try? await client.edition(id: linked) {
                editions.insert(edition, at: 0)
            }
        }
        for edition in editions {
            let languageName = BookLanguage.code(edition.language).map(BookLanguage.displayName)
            let label = [edition.format?.capitalized, languageName].compactMap { $0 }.joined(separator: ", ")
            out.append(FolioMetadataCandidate(
                source: "Hardcover · \(label.isEmpty ? "Edition" : label)",
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

    static func openLibrary(title: String, author: String, language: String?) async -> [FolioMetadataCandidate] {
        var components = URLComponents(string: "https://openlibrary.org/search.json")!
        var items = [
            URLQueryItem(name: "title", value: FolioHardcoverMatch.plainTitle(title)),
            URLQueryItem(name: "author", value: FolioAuthorNames.split(author).first ?? author),
            URLQueryItem(name: "limit", value: "6"),
            URLQueryItem(name: "fields", value: "title,author_name,first_publish_year,publisher,isbn,cover_i,language,number_of_pages_median,editions,editions.title,editions.cover_i,editions.language,editions.publisher,editions.isbn")
        ]
        // With a language, Open Library also returns the best edition in it, with its own cover.
        if let language { items.append(URLQueryItem(name: "lang", value: language)) }
        components.queryItems = items
        guard let url = components.url, let json = await fetchJSON(url),
              let docs = json["docs"] as? [[String: Any]] else { return [] }
        func coverURL(_ id: Any?) -> URL? {
            (id as? Int).flatMap { $0 > 0 ? URL(string: "https://covers.openlibrary.org/b/id/\($0)-L.jpg") : nil }
        }
        var out: [FolioMetadataCandidate] = []
        for doc in docs {
            let authors = (doc["author_name"] as? [String])?.joined(separator: ", ")
            if let language,
               let edition = ((doc["editions"] as? [String: Any])?["docs"] as? [[String: Any]])?.first,
               let editionLanguage = (edition["language"] as? [String])?.compactMap({ BookLanguage.code($0) }).first,
               editionLanguage == language {
                out.append(FolioMetadataCandidate(
                    source: "Open Library · \(BookLanguage.displayName(language))", title: edition["title"] as? String,
                    author: authors, summary: nil, publisher: (edition["publisher"] as? [String])?.first,
                    language: language, isbn: (edition["isbn"] as? [String])?.first { $0.count == 13 },
                    series: nil, seriesIndex: nil, year: nil, pages: nil, coverURL: coverURL(edition["cover_i"])))
            }
            guard let name = doc["title"] as? String else { continue }
            let languages = (doc["language"] as? [String])?.compactMap { BookLanguage.code($0) } ?? []
            out.append(FolioMetadataCandidate(
                source: "Open Library", title: name, author: authors,
                summary: nil, publisher: (doc["publisher"] as? [String])?.first,
                // A work in many languages has no single language of its own.
                language: languages.count == 1 ? languages[0] : nil,
                isbn: (doc["isbn"] as? [String])?.first { $0.count == 13 }, series: nil, seriesIndex: nil,
                year: doc["first_publish_year"] as? Int, pages: doc["number_of_pages_median"] as? Int,
                coverURL: coverURL(doc["cover_i"])))
        }
        return out
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
    @State private var editingSources = false

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
                ToolbarItem(placement: .bottomBar) {
                    Button("Sources", systemImage: "list.number") { editingSources = true }
                }
            }
            .sheet(isPresented: $editingSources) {
                FolioMetadataSourcesEditor {
                    Task { await search() }
                }
            }
            .overlay(alignment: .top) {
                if loading {
                    Label("Searching \(FolioMetadataSource.enabled.map(\.name).formatted(.list(type: .and)))", systemImage: "magnifyingglass")
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
        await search()
    }

    @MainActor
    private func search() async {
        guard let book else { return }
        loading = true
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
    @State private var editingSources = false

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
                    Button("Sources: \(FolioMetadataSource.enabled.map(\.name).joined(separator: ", "))",
                           systemImage: "list.number") { editingSources = true }
                        .disabled(running)
                } footer: {
                    Text("Fills only empty fields and missing covers, from sources in each book's own language. Originals are kept in EPUB Backups.")
                }
                .sheet(isPresented: $editingSources) { FolioMetadataSourcesEditor() }
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

// MARK: - Source preferences

/// Which sources Fix Metadata asks, and in what order: earlier sources win when
/// the library-wide fixer fills gaps, and lead the suggestions on a single book.
struct FolioMetadataSourcesEditor: View {
    var onChange: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var order = FolioMetadataSource.ordered
    @State private var disabled = FolioMetadataSource.disabled

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(order) { source in
                        Toggle(isOn: Binding(
                            get: { !disabled.contains(source) },
                            set: { on in if on { disabled.remove(source) } else { disabled.insert(source) } }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.name)
                                Text(source.note).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                } footer: {
                    Text("Drag to set priority. Only results in the book's own language are suggested.")
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
                        FolioMetadataSource.save(order: order, disabled: disabled)
                        onChange()
                        dismiss()
                    }
                }
            }
        }
    }
}
