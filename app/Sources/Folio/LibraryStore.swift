import Foundation
import SwiftUI
import Observation
import PDFKit

@Observable
@MainActor
final class LibraryStore {
    static let shared = LibraryStore()

    var data = LibraryData()
    var importing = 0
    var lastError: String?

    let baseDir: URL
    var filesDir: URL { baseDir.appendingPathComponent("Files") }
    var coversDir: URL { baseDir.appendingPathComponent("Covers") }
    var extractedDir: URL { baseDir.appendingPathComponent("Extracted") }
    private var dataURL: URL { baseDir.appendingPathComponent("library.json") }

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let custom = ProcessInfo.processInfo.environment["FOLIO_DATA_DIR"], !custom.isEmpty {
            baseDir = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            baseDir = support.appendingPathComponent("Folio", isDirectory: true)
        }
        for d in [baseDir, filesDir, coversDir, extractedDir] {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
        if let raw = try? Data(contentsOf: dataURL),
           let decoded = try? JSONDecoder().decode(LibraryData.self, from: raw) {
            data = decoded
        }
        fillInSeries()
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let raw = try? enc.encode(data) { try? raw.write(to: dataURL, options: .atomic) }
        scheduleWidgetPublish()
    }

    /// Widgets are rebuilt at most every couple of seconds: the reader saves on
    /// page turns and every few seconds of reading, and rebuilding every list
    /// each time made page turns stutter.
    @ObservationIgnored private var widgetPublish: Task<Void, Never>?

    private func scheduleWidgetPublish() {
        guard widgetPublish == nil else { return }
        widgetPublish = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.widgetPublish = nil
            FolioWidgetBridge.publish(self)
        }
    }

    /// Publishes a pending widget update now, as the app leaves the screen.
    func flushWidgets() {
        guard let pending = widgetPublish else { return }
        pending.cancel()
        widgetPublish = nil
        FolioWidgetBridge.publish(self)
    }

    // MARK: Lookup

    var books: [LocalBook] { data.books }

    func book(_ id: UUID) -> LocalBook? { data.books.first { $0.id == id } }

    func update(_ id: UUID, _ change: (inout LocalBook) -> Void) {
        guard let i = data.books.firstIndex(where: { $0.id == id }) else { return }
        change(&data.books[i])
        save()
    }

    func books(_ filter: LibraryFilter, search: String = "") -> [LocalBook] {
        data.books.filter { filter.includes($0) && matches($0, search) }
            .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
    }

    func books(in collection: UUID, search: String = "") -> [LocalBook] {
        data.books.filter { $0.collections.contains(collection) && matches($0, search) }
    }

    private func matches(_ b: LocalBook, _ q: String) -> Bool {
        q.isEmpty || b.title.localizedCaseInsensitiveContains(q) || b.author.localizedCaseInsensitiveContains(q)
    }

    /// Whether a book with this author and title is already in the library (demeter-style match).
    func contains(author: String, title: String) -> Bool {
        let k = BookMatch.key(author: author, title: title)
        return data.books.contains { BookMatch.key(author: $0.author, title: $0.title) == k }
    }

    var continueReading: [LocalBook] {
        data.books.filter { $0.lastOpenedAt != nil && $0.status != .finished }
            .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
    }

    var recentlyAdded: [LocalBook] {
        data.books.sorted { $0.addedAt > $1.addedAt }
    }

    func fileURL(_ b: LocalBook) -> URL { filesDir.appendingPathComponent(b.fileName) }
    func extractedURL(_ b: LocalBook) -> URL { extractedDir.appendingPathComponent(b.id.uuidString, isDirectory: true) }
    func coverURL(_ b: LocalBook) -> URL? { b.coverFileName.map { coversDir.appendingPathComponent($0) } }

    // MARK: Import

    func importFiles(_ urls: [URL], author fallbackAuthor: String? = nil) {
        for url in urls {
            guard BookFormat.from(url: url) != nil else {
                lastError = "\(url.lastPathComponent) isn't a format Folio can read."
                continue
            }
            Task {
                do { _ = try await importBook(url, author: fallbackAuthor) }
                catch { lastError = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)" }
            }
        }
    }

    /// Adds one file to the library and returns the new book's id.
    func importBook(_ url: URL, author fallbackAuthor: String? = nil) async throws -> UUID {
        guard let format = BookFormat.from(url: url) else {
            throw NSError(domain: "Folio", code: 6, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) isn't a format Folio can read."])
        }
        importing += 1
        defer { importing -= 1 }
        let id = UUID()
        var isDirectory: ObjCBool = false
        let isPackage = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        let storedExtension: String
        switch (format, isPackage) {
        case (.epub, _): storedExtension = "epub"
        case (.comic, _): storedExtension = "cbz"
        case (.rtf, true): storedExtension = "rtfd"
        case (.markdown, true): storedExtension = "textbundle"
        default: storedExtension = url.pathExtension.lowercased()
        }
        let fileName = id.uuidString + "." + storedExtension
        let dest = filesDir.appendingPathComponent(fileName)
        let extracted = extractedDir.appendingPathComponent(id.uuidString, isDirectory: true)
        let covers = coversDir
        let meta = try await Task.detached(priority: .userInitiated) { () throws -> Meta in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                if isPackage {
                    switch format {
                    case .epub:
                        try Unzip.packageEPUBFolder(url, to: dest)
                    case .comic:
                        try Unzip.packageComicFolder(url, to: dest)
                    case .rtf:
                        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("TXT.rtf").path) else {
                            throw NSError(domain: "Folio", code: 9, userInfo: [NSLocalizedDescriptionKey: "This rich-text package has no TXT.rtf file."])
                        }
                        try FileManager.default.copyItem(at: url, to: dest)
                    case .markdown:
                        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("text.md").path) else {
                            throw NSError(domain: "Folio", code: 9, userInfo: [NSLocalizedDescriptionKey: "This TextBundle has no text.md file."])
                        }
                        try FileManager.default.copyItem(at: url, to: dest)
                    case .html:
                        guard FileManager.default.fileExists(atPath: url.appendingPathComponent("index.html").path) ||
                              FileManager.default.fileExists(atPath: url.appendingPathComponent("index.htm").path) else {
                            throw NSError(domain: "Folio", code: 9, userInfo: [NSLocalizedDescriptionKey: "This web-page folder needs an index.html file."])
                        }
                        try FileManager.default.copyItem(at: url, to: dest)
                    case .pdf, .text:
                        throw NSError(domain: "Folio", code: 9, userInfo: [NSLocalizedDescriptionKey: "PDF and plain-text books must be files, not folders."])
                    }
                } else {
                    try FileManager.default.copyItem(at: url, to: dest)
                }
                return try Self.prepare(format: format, file: dest, extracted: extracted, covers: covers, id: id, fallbackTitle: url.deletingPathExtension().lastPathComponent)
            } catch {
                try? FileManager.default.removeItem(at: dest)
                try? FileManager.default.removeItem(at: extracted)
                throw error
            }
        }.value
        let author = meta.author.isEmpty ? (fallbackAuthor ?? "") : meta.author
        var b = LocalBook(id: id, title: meta.title, author: author, format: format, fileName: fileName)
        b.coverFileName = meta.cover
        b.series = meta.series
        b.seriesIndex = meta.seriesIndex
        b.seriesChecked = true
        b.isbn = meta.isbn
        b.language = meta.language
        b.summary = meta.summary
        b.publisher = meta.publisher
        b.publishedYear = meta.publishedYear
        // A new file for a book already in the library keeps where the reader is.
        if let earlier = localCopy(author: b.author, title: b.title), earlier.progress > 0.001 || earlier.status != .none {
            b.progress = earlier.progress
            b.status = earlier.status
            b.lastOpenedAt = earlier.lastOpenedAt
            if earlier.format == format { b.position = earlier.position }
            b.hardcoverBookID = earlier.hardcoverBookID
            b.hardcoverEditionID = earlier.hardcoverEditionID
            b.hardcoverPages = earlier.hardcoverPages
            b.hardcoverSlug = earlier.hardcoverSlug
        }
        data.books.append(b)
        save()
        if format == .epub { enqueueAutoLink(id) }
        return id
    }

    // MARK: Conservative Hardcover auto-linking

    private var hardcoverAutoLinkQueue: [UUID] = []
    private var hardcoverAutoLinkWorkerRunning = false

    /// Includes EPUBs imported while offline, once a Hardcover account becomes available.
    func enqueueUnlinkedEPUBs() {
        for b in data.books where b.format == .epub && b.hardcoverBookID == nil && b.hardcoverAutoLinkChecked != true {
            enqueueAutoLink(b.id)
        }
    }

    private func enqueueAutoLink(_ id: UUID) {
        guard let b = book(id), b.format == .epub, b.hardcoverBookID == nil,
              b.hardcoverAutoLinkChecked != true, !hardcoverAutoLinkQueue.contains(id) else { return }
        hardcoverAutoLinkQueue.append(id)
        guard !hardcoverAutoLinkWorkerRunning else { return }
        hardcoverAutoLinkWorkerRunning = true
        Task { await processHardcoverAutoLinkQueue() }
    }

    private func processHardcoverAutoLinkQueue() async {
        defer { hardcoverAutoLinkWorkerRunning = false }
        let hc = HardcoverClient.shared
        while !hardcoverAutoLinkQueue.isEmpty {
            // Keep untried books eligible for another attempt on the next connection.
            guard let accountID = hc.user?.id else { hardcoverAutoLinkQueue.removeAll(); return }
            let id = hardcoverAutoLinkQueue.removeFirst()
            guard let b = book(id), b.format == .epub, b.hardcoverBookID == nil,
                  b.hardcoverAutoLinkChecked != true else { continue }
            do {
                let match = try await confidentHardcoverMatch(for: b, client: hc)
                // A file in another language takes that language's edition: its pages,
                // publisher and cover, while the work keeps ratings and series.
                var edition: HCEdition?
                var shelf: HCUserBook?
                if let match { (edition, shelf) = await linkDetails(bookID: match.id, for: id, client: hc) }
                guard hc.user?.id == accountID,
                      let latest = book(id), latest.hardcoverBookID == nil,
                      latest.hardcoverAutoLinkChecked != true else { continue }
                update(id) { stored in
                    stored.hardcoverAutoLinkChecked = true
                    if let match {
                        stored.hardcoverBookID = match.id
                        stored.hardcoverPages = edition?.pages ?? match.pages
                        stored.hardcoverSlug = match.slug
                        stored.hardcoverEditionID = edition?.id
                    }
                }
                if let shelf { adoptHardcoverProgress(id, from: shelf) }
            } catch {
                // A connection or service failure is not a negative match. Retry on reconnect.
            }
            // Search can consume more than one API call; keep bulk linking within rate limits.
            try? await Task.sleep(for: .seconds(2))
        }
    }

    private func confidentHardcoverMatch(for book: LocalBook, client hc: HardcoverClient) async throws -> HCBook? {
        // Older imports do not have a stored ISBN. Their extracted OPF is already local.
        let pkg = try? EPUBPackage.load(root: extractedURL(book))
        let title = (pkg?.title.isEmpty == false ? pkg?.title : nil) ?? book.title
        let author = (pkg?.author.isEmpty == false ? pkg?.author : nil) ?? book.author
        let isbn = book.isbn ?? pkg?.isbn
        if book.isbn == nil, let isbn { update(book.id) { $0.isbn = isbn } }
        // Older imports never recorded the language: read it now.
        var language = book.language
        if language == nil, let pkg {
            language = BookLanguage.detect(declared: pkg.language, chapters: pkg.content.chapters)
            if let language { update(book.id) { $0.language = language } }
        }

        if let isbn {
            let ids = try await hc.bookIDs(isbn: isbn)
            if ids.count == 1, let result = try await hc.book(id: ids[0]),
               BookAutoMatch.sameTitle(title, result.title),
               BookAutoMatch.sameAuthor(author, result.authors) {
                return result
            }
        }

        guard !BookAutoMatch.words(title).isEmpty, BookAutoMatch.words(author).count >= 2 else { return nil }
        let candidates = try await hc.search(title)
        // Search returns a maximum of 30 hits; a full page cannot prove uniqueness.
        if candidates.count < 30,
           let id = BookAutoMatch.uniqueExact(title: title, author: author,
                                              in: candidates.map { .init(id: $0.id, title: $0.title, authors: $0.authors) }),
           let found = candidates.first(where: { $0.id == id }) {
            return found
        }
        // A translation is catalogued under the original title ("Amanecer rojo" is "Red Rising").
        if let language, language != "en" {
            return await hc.translatedBook(title: title, author: author,
                                           series: book.series ?? pkg?.series, seriesIndex: book.seriesIndex ?? pkg?.seriesIndex)
        }
        return nil
    }

    /// The edition a library file stands for: the one on the reader's Hardcover
    /// shelf if they picked one, else the most-read edition in the file's language.
    func preferredEdition(bookID: Int, for id: UUID, client hc: HardcoverClient) async -> HCEdition? {
        await linkDetails(bookID: bookID, for: id, client: hc).edition
    }

    /// The reader's Hardcover shelf entry for a work (with its progress) and the edition
    /// the file stands for, looked up together when a file is linked.
    func linkDetails(bookID: Int, for id: UUID, client hc: HardcoverClient) async -> (edition: HCEdition?, shelf: HCUserBook?) {
        let shelved = try? await hc.userBook(bookID: bookID)
        if let editionID = shelved?.editionID, let edition = try? await hc.edition(id: editionID) {
            return (edition, shelved)
        }
        guard let language = ensureLanguage(id), language != "en", let b = book(id) else { return (nil, shelved) }
        return (try? await hc.edition(bookID: bookID, language: language, title: b.title), shelved)
    }

    /// The file's language, detected and saved the first time it is needed.
    @discardableResult
    func ensureLanguage(_ id: UUID) -> String? {
        guard let b = book(id) else { return nil }
        if let language = BookLanguage.code(b.language) { return language }
        guard b.format == .epub, let pkg = try? EPUBPackage.load(root: extractedURL(b)),
              let language = BookLanguage.detect(declared: pkg.language, chapters: pkg.content.chapters) else { return nil }
        update(id) { $0.language = language }
        return language
    }

    /// A linked file with no progress of its own starts where the reader's Hardcover
    /// shelf says they are, so it opens on that page.
    func adoptHardcoverProgress(_ id: UUID, from shelf: HCUserBook) {
        guard let b = book(id), b.progress < 0.001, b.status != .finished else { return }
        if shelf.status == .read {
            update(id) { $0.status = .finished }
            return
        }
        guard let read = shelf.progressPages, read > 0,
              let total = b.hardcoverPages ?? shelf.book.pages, total > 0 else { return }
        update(id) {
            $0.progress = min(0.995, Double(read) / Double(total))
            if $0.status == .none || $0.status == .wantToRead { $0.status = .reading }
        }
    }

    /// Link a library EPUB now (from its book page), including its language's edition.
    /// Returns whether a link was made.
    @discardableResult
    func linkHardcoverNow(_ id: UUID) async -> Bool {
        let hc = HardcoverClient.shared
        guard hc.isConnected, let b = book(id), b.format == .epub, b.hardcoverBookID == nil,
              b.hardcoverManuallyUnlinked != true,
              let match = try? await confidentHardcoverMatch(for: b, client: hc) else { return false }
        let (edition, shelf) = await linkDetails(bookID: match.id, for: id, client: hc)
        guard book(id)?.hardcoverBookID == nil else { return false }
        update(id) { stored in
            stored.hardcoverAutoLinkChecked = true
            stored.hardcoverBookID = match.id
            stored.hardcoverPages = edition?.pages ?? match.pages
            stored.hardcoverSlug = match.slug
            stored.hardcoverEditionID = edition?.id
        }
        if let shelf { adoptHardcoverProgress(id, from: shelf) }
        return true
    }

    /// A book already in the library with this author and title, if any.
    func localCopy(author: String, title: String) -> LocalBook? {
        let k = BookMatch.key(author: author, title: title)
        return data.books.first { BookMatch.key(author: $0.author, title: $0.title) == k }
    }

    /// Copies verified Hardcover details into the EPUB archive itself, including its embedded
    /// cover image. This is an explicit user action and always leaves a recoverable original.
    func enrichEPUB(_ id: UUID, from selected: HCBook, edition: HCEdition? = nil) async throws {
        guard let originalBook = book(id), originalBook.format == .epub else {
            throw NSError(domain: "Folio", code: 41, userInfo: [NSLocalizedDescriptionKey: "Only imported EPUB books can be updated this way."])
        }

        // Search results can omit descriptions and use lower-resolution covers. Prefer the
        // complete record, but keep search-result fields when Hardcover omits a value.
        var details = try await HardcoverClient.shared.book(id: selected.id) ?? selected
        if details.authors.isEmpty { details.authors = selected.authors }
        if details.description == nil { details.description = selected.description }
        if details.imageURL == nil { details.imageURL = selected.imageURL }
        if details.pages == nil { details.pages = selected.pages }
        if details.slug == nil { details.slug = selected.slug }
        // A translated file takes its own edition's title, cover and length, and keeps
        // its own description rather than the original-language one.
        if let edition {
            if let title = edition.title, !title.isEmpty { details.title = title }
            if let image = edition.imageURL { details.imageURL = image }
            if let pages = edition.pages { details.pages = pages }
            details.description = nil
        }

        var coverPNG: Data?
        if let url = details.imageURL { coverPNG = try await Self.downloadCoverPNG(url) }
        let enrichedDetails = details
        let updated = try await rewriteEPUB(id, expectedFile: originalBook.fileName, details: details,
                                            coverPNG: coverPNG, extras: EPUBMetadataExtras())

        guard book(id) != nil else { return }
        update(id) { book in
            book.title = updated.title
            if !updated.author.isEmpty { book.author = updated.author }
            if let cover = updated.coverFile { book.coverFileName = cover }
            if let isbn = updated.isbn { book.isbn = isbn }
            if let summary = enrichedDetails.description?.plainText, !summary.isEmpty { book.summary = summary }
            if let year = enrichedDetails.year { book.publishedYear = year }
            book.hardcoverBookID = enrichedDetails.id
            book.hardcoverPages = enrichedDetails.pages
            book.hardcoverSlug = enrichedDetails.slug
            book.hardcoverAutoLinkChecked = true
        }
    }

    /// The fields chosen in the metadata editor.
    struct MetadataChoice: Sendable, Hashable {
        var title: String
        var author: String
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

    /// Saves edited metadata to the library and, for EPUBs when asked, into the file
    /// itself (verified, with the original kept in EPUB Backups).
    func applyMetadata(_ id: UUID, _ choice: MetadataChoice, writeFile: Bool) async throws {
        guard let original = book(id) else { return }
        var coverPNG: Data?
        if let url = choice.coverURL { coverPNG = try await Self.downloadCoverPNG(url) }
        var newCover: String?
        if writeFile, original.format == .epub {
            let details = HCBook(id: original.hardcoverBookID ?? 0, title: choice.title, authors: choice.author,
                                 imageURL: nil, year: choice.year, pages: choice.pages, rating: nil,
                                 ratingsCount: nil, description: choice.summary, slug: nil)
            let extras = EPUBMetadataExtras(publisher: choice.publisher, language: choice.language,
                                            series: choice.series, seriesIndex: choice.seriesIndex, replaceYear: true)
            let updated = try await rewriteEPUB(id, expectedFile: original.fileName, details: details,
                                                coverPNG: coverPNG, extras: extras)
            newCover = updated.coverFile
        } else if let coverPNG {
            let name = "\(id.uuidString)-meta-\(UUID().uuidString).png"
            try coverPNG.write(to: coversDir.appendingPathComponent(name), options: .atomic)
            newCover = name
        }
        guard book(id) != nil else { return }
        update(id) { b in
            let title = choice.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { b.title = title }
            let author = choice.author.trimmingCharacters(in: .whitespacesAndNewlines)
            if !author.isEmpty { b.author = author }
            b.summary = choice.summary
            b.publisher = choice.publisher
            b.language = choice.language
            b.isbn = choice.isbn
            b.series = choice.series
            b.seriesIndex = choice.seriesIndex
            b.publishedYear = choice.year
            if let pages = choice.pages, pages > 0 { b.hardcoverPages = pages }
            if let newCover { b.coverFileName = newCover }
        }
    }

    /// Downloads a cover and normalizes it to PNG, or throws without touching anything.
    nonisolated static func downloadCoverPNG(_ coverURL: URL) async throws -> Data {
        guard coverURL.scheme?.lowercased() == "https" else {
            throw NSError(domain: "Folio", code: 42, userInfo: [NSLocalizedDescriptionKey: "The cover address is not secure."])
        }
        var request = URLRequest(url: coverURL)
        request.timeoutInterval = 25
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !bytes.isEmpty, bytes.count <= 15_000_000,
              let image = FolioImageLoader.decode(bytes),
              let png = CoverMaker.pngData(image, maxHeight: 1200) else {
            throw NSError(domain: "Folio", code: 43, userInfo: [NSLocalizedDescriptionKey: "The cover could not be downloaded or decoded. The EPUB has not been changed."])
        }
        return png
    }

    /// Writes metadata (and optionally a cover) into the EPUB file itself, after
    /// verifying the result and keeping the original in EPUB Backups.
    private func rewriteEPUB(_ id: UUID, expectedFile: String, details: HCBook, coverPNG: Data?,
                             extras: EPUBMetadataExtras) async throws -> (title: String, author: String, coverFile: String?, isbn: String?) {
        guard let current = book(id), current.fileName == expectedFile else {
            throw NSError(domain: "Folio", code: 44, userInfo: [NSLocalizedDescriptionKey: "This book is no longer in the library."])
        }
        let file = fileURL(current)
        let activeExtract = extractedURL(current)
        let base = baseDir
        let covers = coversDir
        let enrichedDetails = details
        let enrichedExtras = extras
        return try await Task.detached(priority: .userInitiated) { () throws -> (title: String, author: String, coverFile: String?, isbn: String?) in
            let fm = FileManager.default
            let temporary = base.appendingPathComponent("EPUB-Enrichment-\(UUID().uuidString)", isDirectory: true)
            let expanded = temporary.appendingPathComponent("Expanded", isDirectory: true)
            let check = temporary.appendingPathComponent("Verify", isDirectory: true)
            let replacement = temporary.appendingPathComponent("updated.epub")
            try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: temporary) }

            try Unzip.extract(file, to: expanded)
            try EPUBHardcoverEnricher.apply(in: expanded, book: enrichedDetails, coverData: coverPNG, extras: enrichedExtras)
            try Unzip.packageEPUBFolder(expanded, to: replacement)
            // Verify the zipped EPUB through Folio's actual importer, not just the XML parser.
            try Unzip.extract(replacement, to: check)
            let package = try EPUBPackage.load(root: check)
            guard !package.content.chapters.isEmpty,
                  !package.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (coverPNG == nil || (package.coverURL.map { fm.fileExists(atPath: $0.path) } ?? false)) else {
                throw NSError(domain: "Folio", code: 45, userInfo: [NSLocalizedDescriptionKey: "The updated EPUB failed validation. The original is unchanged."])
            }

            var newCover: String?
            if let cover = package.coverURL, let image = FolioImageLoader.load(cover),
               let data = CoverMaker.pngData(image) {
                let name = "\(id.uuidString)-hc-\(UUID().uuidString).png"
                try data.write(to: covers.appendingPathComponent(name), options: .atomic)
                newCover = name
            }

            let backups = base.appendingPathComponent("EPUB Backups", isDirectory: true)
            try fm.createDirectory(at: backups, withIntermediateDirectories: true)
            let backup = backups.appendingPathComponent("\(id.uuidString)-\(UUID().uuidString).epub")
            do {
                try fm.copyItem(at: file, to: backup)
                _ = try fm.replaceItemAt(file, withItemAt: replacement, backupItemName: nil,
                                         options: [.usingNewMetadataOnly])
            } catch {
                if let newCover { try? fm.removeItem(at: covers.appendingPathComponent(newCover)) }
                throw error
            }

            // Existing reader windows use these paths. Update the extracted metadata and cover
            // in place while leaving chapter files intact until their current session ends.
            if fm.fileExists(atPath: activeExtract.appendingPathComponent("META-INF/container.xml").path) {
                try? EPUBHardcoverEnricher.apply(in: activeExtract, book: enrichedDetails, coverData: coverPNG, extras: enrichedExtras)
            }
            return (package.title, package.author, newCover, package.isbn)
        }.value
    }

    struct Meta: Sendable {
        var title: String; var author: String; var cover: String?; var series: String? = nil; var seriesIndex: Double? = nil; var isbn: String? = nil
        var language: String? = nil; var summary: String? = nil; var publisher: String? = nil; var publishedYear: Int? = nil
    }

    nonisolated static func prepare(format: BookFormat, file: URL, extracted: URL, covers: URL, id: UUID, fallbackTitle: String) throws -> Meta {
        let fm = FileManager.default
        var meta = Meta(title: fallbackTitle, author: "", cover: nil)
        func saveCover(_ data: Data?) {
            guard let data else { return }
            let name = id.uuidString + ".png"
            if (try? data.write(to: covers.appendingPathComponent(name))) != nil { meta.cover = name }
        }
        switch format {
        case .epub:
            try Unzip.extract(file, to: extracted)
            let pkg = try EPUBPackage.load(root: extracted)
            if !pkg.title.isEmpty { meta.title = pkg.title }
            meta.author = pkg.author
            meta.series = pkg.series
            meta.seriesIndex = pkg.seriesIndex
            meta.isbn = pkg.isbn
            meta.language = BookLanguage.detect(declared: pkg.language, chapters: pkg.content.chapters)
            meta.summary = pkg.summary
            meta.publisher = pkg.publisher
            meta.publishedYear = pkg.publishedYear
            if let c = pkg.coverURL, let img = FolioImageLoader.load(c) { saveCover(CoverMaker.pngData(img)) }
        case .pdf:
            guard let doc = PDFDocument(url: file) else { throw NSError(domain: "Folio", code: 3, userInfo: [NSLocalizedDescriptionKey: "This PDF can't be opened."]) }
            if let t = doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String, !t.trimmingCharacters(in: .whitespaces).isEmpty { meta.title = t }
            if let a = doc.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String { meta.author = a }
            saveCover(CoverMaker.pdfCover(doc))
        case .comic:
            try Unzip.extract(file, to: extracted)
            let imgs = Converters.images(in: extracted)
            if imgs.isEmpty { throw NSError(domain: "Folio", code: 4, userInfo: [NSLocalizedDescriptionKey: "No pages found in this comic."]) }
            try Converters.comicHTML(images: imgs, root: extracted).write(to: extracted.appendingPathComponent("folio-index.html"), atomically: true, encoding: .utf8)
            if let img = FolioImageLoader.load(imgs[0]) { saveCover(CoverMaker.pngData(img)) }
        case .text, .markdown, .rtf, .html:
            try? fm.removeItem(at: extracted)
            try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
            var isDirectory: ObjCBool = false
            let isPackage = fm.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue
            if isPackage && (format == .markdown || format == .html) {
                // Keep the package's images and styles beside the generated reading page.
                for item in try fm.contentsOfDirectory(atPath: file.path) {
                    try fm.copyItem(at: file.appendingPathComponent(item), to: extracted.appendingPathComponent(item))
                }
            }
            let html: String
            switch format {
            case .text:
                let s = (try? String(contentsOf: file, encoding: .utf8)) ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? ""
                html = Converters.textToHTML(s, title: meta.title)
            case .markdown:
                let source = isPackage ? file.appendingPathComponent("text.md") : file
                let s = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
                if let first = s.components(separatedBy: "\n").first(where: { $0.hasPrefix("# ") }) {
                    meta.title = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
                html = Converters.markdownToHTML(s, title: meta.title)
            case .rtf:
                let type: NSAttributedString.DocumentType = isPackage ? .rtfd : .rtf
                let attr = try NSAttributedString(url: file, options: [.documentType: type], documentAttributes: nil)
                let d = try attr.data(from: NSRange(location: 0, length: attr.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
                html = String(data: d, encoding: .utf8) ?? ""
            default:
                let source = isPackage ? (fm.fileExists(atPath: file.appendingPathComponent("index.html").path) ? file.appendingPathComponent("index.html") : file.appendingPathComponent("index.htm")) : file
                html = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
                if let r = html.range(of: "<title>(.*?)</title>", options: [.regularExpression, .caseInsensitive]) {
                    let t = html[r].replacingOccurrences(of: "</?title>", with: "", options: [.regularExpression, .caseInsensitive])
                    if !t.isEmpty { meta.title = t }
                }
            }
            try html.write(to: extracted.appendingPathComponent("folio-index.html"), atomically: true, encoding: .utf8)
        }
        return meta
    }

    /// Everything the web reader needs for a non-PDF book.
    func webContent(_ b: LocalBook) throws -> WebContent {
        let root = extractedURL(b)
        switch b.format {
        case .epub:
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent("META-INF/container.xml").path) {
                try Unzip.extract(fileURL(b), to: root)
            }
            return try EPUBPackage.load(root: root).content
        case .pdf:
            throw NSError(domain: "Folio", code: 5)
        default:
            let index = root.appendingPathComponent("folio-index.html")
            if !FileManager.default.fileExists(atPath: index.path) {
                _ = try Self.prepare(format: b.format, file: fileURL(b), extracted: root, covers: coversDir, id: b.id, fallbackTitle: b.title)
            }
            return WebContent(root: root, chapters: [index], chapterSizes: [1], toc: [TOCEntry(title: b.title, level: 0, chapter: 0)], isComic: b.format == .comic, rtl: false)
        }
    }

    /// Books added before series support: read their series from the EPUB once.
    private func fillInSeries() {
        let todo = data.books.filter { $0.format == .epub && $0.seriesChecked != true }.map { ($0.id, extractedURL($0)) }
        guard !todo.isEmpty else { return }
        Task.detached(priority: .utility) {
            var found: [(UUID, String?, Double?)] = []
            for (id, root) in todo {
                let pkg = try? EPUBPackage.load(root: root)
                found.append((id, pkg?.series, pkg?.seriesIndex))
            }
            let results = found
            await MainActor.run {
                for (id, s, i) in results {
                    guard let k = self.data.books.firstIndex(where: { $0.id == id }) else { continue }
                    self.data.books[k].series = self.data.books[k].series ?? s
                    self.data.books[k].seriesIndex = self.data.books[k].seriesIndex ?? i
                    self.data.books[k].seriesChecked = true
                }
                self.save()
            }
        }
    }

    // MARK: Changes

    func remove(_ id: UUID) {
        guard let b = book(id) else { return }
        try? FileManager.default.removeItem(at: fileURL(b))
        try? FileManager.default.removeItem(at: extractedURL(b))
        if let c = coverURL(b) { try? FileManager.default.removeItem(at: c) }
        data.books.removeAll { $0.id == id }
        save()
    }

    func setStatus(_ id: UUID, _ status: ReadingStatus, hardcover: HardcoverClient? = nil) {
        update(id) { b in
            b.status = status
            if status == .finished { b.finishedAt = Date(); b.progress = max(b.progress, 1) }
        }
        if let hc = hardcover, let b = book(id), let hcID = b.hardcoverBookID, let s = status.hardcover {
            Task { await hc.setStatus(bookID: hcID, status: s) }
        }
    }

    func addCollection(_ name: String) -> UUID {
        let c = BookCollection(name: name)
        data.collections.append(c)
        save()
        return c.id
    }

    func renameCollection(_ id: UUID, _ name: String) {
        if let i = data.collections.firstIndex(where: { $0.id == id }) { data.collections[i].name = name; save() }
    }

    func deleteCollection(_ id: UUID) {
        data.collections.removeAll { $0.id == id }
        for i in data.books.indices { data.books[i].collections.remove(id) }
        save()
    }

    func toggle(_ book: UUID, in collection: UUID) {
        update(book) { b in
            if b.collections.contains(collection) { b.collections.remove(collection) } else { b.collections.insert(collection) }
        }
    }

    // MARK: Reading goals (Books' ReadingActivityService: dailyGoal, booksPerYear)

    func addReading(seconds: Double) {
        guard seconds > 0 else { return }
        data.secondsByDay[Date().dayKey, default: 0] += seconds
        save()
    }

    var todayMinutes: Double { (data.secondsByDay[Date().dayKey] ?? 0) / 60 }

    var isDailyGoalCompleted: Bool { todayMinutes >= Double(data.goals.dailyMinutes) }

    /// Consecutive days (ending today, or yesterday if today isn't met yet) that met the daily goal.
    var streak: Int {
        let cal = Calendar.current
        var day = Date()
        var count = 0
        let goal = Double(data.goals.dailyMinutes) * 60
        if (data.secondsByDay[day.dayKey] ?? 0) < goal { day = cal.date(byAdding: .day, value: -1, to: day)! }
        while (data.secondsByDay[day.dayKey] ?? 0) >= goal && count < 3650 {
            count += 1
            day = cal.date(byAdding: .day, value: -1, to: day)!
        }
        return count
    }

    func minutes(daysAgo: Int) -> Double {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        return (data.secondsByDay[d.dayKey] ?? 0) / 60
    }

    var finishedThisYear: Int {
        let year = Calendar.current.component(.year, from: Date())
        let local = data.books.filter { b in
            guard b.status == .finished, let f = b.finishedAt else { return false }
            return Calendar.current.component(.year, from: f) == year
        }.count
        let tracked = data.tracked.filter { $0.shelf == "read" && ($0.dateRead ?? "").hasPrefix(String(year)) }.count
        return local + tracked
    }

    // MARK: Goodreads

    func importGoodreads(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let rows = try GoodreadsCSV.read(url)
            let before = data.tracked.count
            mergeTracked(rows)
            let added = data.tracked.count - before
            lastError = nil
            goodreadsMessage = "Imported \(rows.count) books from Goodreads (\(added) new)."
        } catch {
            lastError = "Couldn't read that Goodreads file: \(error.localizedDescription)"
        }
    }

    var goodreadsMessage: String?

    private static func key(_ t: TrackedBook) -> String {
        if let g = t.goodreadsID, !g.isEmpty { return "gr:" + g }
        return "t:" + t.title.lowercased().trimmingCharacters(in: .whitespaces) + "|" + t.author.lowercased()
    }

    /// Adds or refreshes Goodreads books, keeping what Folio already learned about them.
    func mergeTracked(_ incoming: [TrackedBook]) {
        var index: [String: Int] = [:]
        for (i, t) in data.tracked.enumerated() {
            index[Self.key(t)] = i
            index["t:" + t.title.lowercased().trimmingCharacters(in: .whitespaces) + "|" + t.author.lowercased()] = i
        }
        for var r in incoming {
            if let i = index[Self.key(r)] ?? index["t:" + r.title.lowercased().trimmingCharacters(in: .whitespaces) + "|" + r.author.lowercased()] {
                let old = data.tracked[i]
                r.id = old.id
                r.hardcoverBookID = old.hardcoverBookID
                r.sentToHardcover = old.sentToHardcover && old.shelf == r.shelf && old.rating == r.rating
                r.isbn = r.isbn ?? old.isbn
                r.isbn13 = r.isbn13 ?? old.isbn13
                r.pages = r.pages ?? old.pages
                r.year = r.year ?? old.year
                r.dateRead = r.dateRead ?? old.dateRead
                r.coverURL = r.coverURL ?? old.coverURL
                r.goodreadsID = r.goodreadsID ?? old.goodreadsID
                data.tracked[i] = r
            } else {
                data.tracked.append(r)
                index[Self.key(r)] = data.tracked.count - 1
            }
        }
        save()
    }

    func tracked(_ shelf: GRShelf) -> [TrackedBook] {
        data.tracked.filter { GRShelf.from(csvShelf: $0.shelf) == shelf }
    }

    /// Copies Goodreads books to Hardcover: finds each by ISBN, then by title and author, and sets its status and rating.
    func sendTrackedToHardcover(_ hc: HardcoverClient, shelf: GRShelf? = nil) async -> (sent: Int, missed: Int) {
        var sent = 0, missed = 0
        let ids = data.tracked.filter { !$0.sentToHardcover && (shelf == nil || GRShelf.from(csvShelf: $0.shelf) == shelf) }.map(\.id)
        for id in ids {
            guard let t = data.tracked.first(where: { $0.id == id }), let status = t.status else { continue }
            var bookID = t.hardcoverBookID
            if bookID == nil, let isbn = t.isbn13 ?? t.isbn { bookID = try? await hc.bookID(isbn: isbn) }
            if bookID == nil {
                let results = (try? await hc.search("\(t.title) \(t.author)")) ?? []
                bookID = results.first?.id
            }
            guard let bookID else { missed += 1; continue }
            let ub = await hc.setStatus(bookID: bookID, status: status)
            if let ub, t.rating > 0 { await hc.setRating(userBookID: ub.id, rating: Double(t.rating)) }
            if let i = data.tracked.firstIndex(where: { $0.id == id }) {
                data.tracked[i].hardcoverBookID = bookID
                data.tracked[i].sentToHardcover = ub != nil
            }
            if ub != nil { sent += 1 } else { missed += 1 }
            save()
            try? await Task.sleep(for: .milliseconds(1100)) // Hardcover allows about 60 requests a minute
        }
        return (sent, missed)
    }
}
