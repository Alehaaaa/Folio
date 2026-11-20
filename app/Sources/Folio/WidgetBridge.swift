import Foundation
import WidgetKit

/// Publishes lightweight, read-only shelf data for the system's WidgetKit process.
/// Widget extensions have no access to Folio's Hardcover credentials or book files.
@MainActor
enum FolioWidgetBridge {
    private static var hardcoverBooks: [HCStatus: [HCUserBook]] = [:]
    private static var lastReload = Date.distantPast
    private static var refreshing = false
    private static var fetchingArtwork = false
    private static var attemptedArtwork: [String: Date] = [:]

    static func publish() { publish(.shared) }

    static func publish(_ store: LibraryStore) {
        guard let destination = FolioWidgetStorage.snapshotURL else { return }
        let all = store.books
        var remoteArtwork: [String: URL] = [:]
        let localByBook = Dictionary(all.compactMap { item -> (String, LocalBook)? in
            guard item.coverFileName != nil else { return nil }
            return (BookMatch.key(author: item.author, title: item.title), item)
        }, uniquingKeysWith: { first, _ in first })

        func artwork(title: String, author: String, name: String, remote: URL?) -> String? {
            let key = BookMatch.key(author: author, title: title)
            if let localName = localByBook[key]?.coverFileName { return localName }
            guard let remote, remote.scheme?.lowercased() == "https" else { return nil }
            remoteArtwork[name] = remote
            return name
        }

        func book(_ value: LocalBook) -> FolioWidgetBook {
            FolioWidgetBook(
                id: "local-\(value.id.uuidString)", title: value.title, author: value.author,
                progress: value.progress > 0.001 ? min(1, value.progress) : nil,
                coverName: value.coverFileName,
                deepLink: "folio-reader://read/\(value.id.uuidString)"
            )
        }

        func localList(_ id: String, _ name: String, _ symbol: String, _ values: [LocalBook], link: String) -> FolioWidgetList {
            FolioWidgetList(id: id, name: name, symbol: symbol, count: values.count, books: Array(values.prefix(35)).map(book), deepLink: link)
        }

        var lists: [FolioWidgetList] = [
            localList("continue", "Continue Reading", "book", store.continueReading, link: "folio-reader://library/reading"),
            localList("recent", "Recently Added", "clock", store.recentlyAdded, link: "folio-reader://library/all"),
            localList("all", "All Books", "books.vertical", store.books(.all), link: "folio-reader://library/all"),
            localList("epub", "EPUB Books", "book.closed", store.books(.books), link: "folio-reader://library/books"),
            localList("pdf", "PDFs", "doc.richtext", store.books(.pdfs), link: "folio-reader://library/pdfs"),
            localList("documents", "Documents & Comics", "doc.on.doc", store.books(.documents), link: "folio-reader://library/documents")
        ]

        // User-created collections are offered alongside built-in lists by the widget picker.
        for collection in store.data.collections {
            let items = all.filter { $0.collections.contains(collection.id) }
            lists.append(localList("collection-\(collection.id.uuidString)", collection.name, "rectangle.stack", items,
                                   link: "folio-reader://collection/\(collection.id.uuidString)"))
        }

        // My Shelves combines local files, Hardcover and Goodreads under the same
        // status. Local files take precedence so widget taps can open the reader.
        for status in HCStatus.allCases {
            var books: [FolioWidgetBook] = []
            var seenIDs: Set<Int> = []
            var seenKeys: Set<String> = []
            let deepLink = "folio-reader://shelf/\(status.rawValue)"

            func remember(id: Int?, title: String, author: String) -> Bool {
                // WidgetBridge also builds on iOS; keep its matching logic in shared models.
                let key = BookMatch.key(author: author, title: title)
                if let id, seenIDs.contains(id) { return false }
                guard !seenKeys.contains(key) else { return false }
                if let id { seenIDs.insert(id) }
                seenKeys.insert(key)
                return true
            }

            let localBooks: [LocalBook]
            switch status {
            case .wantToRead: localBooks = store.books(.wantToRead)
            case .reading: localBooks = store.books(.reading)
            case .read: localBooks = store.books(.finished)
            case .paused, .dnf: localBooks = []
            }
            for local in localBooks where remember(id: local.hardcoverBookID, title: local.title, author: local.author) {
                books.append(book(local))
            }

            for ub in hardcoverBooks[status] ?? [] {
                guard remember(id: ub.book.id, title: ub.book.title, author: ub.book.authors) else { continue }
                let fraction: Double? = if let pages = ub.book.pages, pages > 0, let progress = ub.progressPages {
                    min(1, Double(progress) / Double(pages))
                } else { nil }
                books.append(FolioWidgetBook(id: "hardcover-\(ub.book.id)", title: ub.book.title, author: ub.book.authors,
                                             progress: fraction,
                                             coverName: artwork(title: ub.book.title, author: ub.book.authors,
                                                                name: "hardcover-\(ub.book.id).png", remote: ub.book.imageURL),
                                             deepLink: deepLink))
            }
            for tracked in store.data.tracked where tracked.status == status {
                guard remember(id: tracked.hardcoverBookID, title: tracked.title, author: tracked.author) else { continue }
                books.append(FolioWidgetBook(id: "goodreads-\(tracked.id.uuidString)", title: tracked.title, author: tracked.author,
                                             progress: nil,
                                             coverName: artwork(title: tracked.title, author: tracked.author,
                                                                name: "goodreads-\(tracked.id.uuidString).png",
                                                                remote: tracked.coverURL.flatMap(URL.init(string:))),
                                             deepLink: deepLink))
            }
            let shelfName = status == .reading ? "Reading Now" : (status == .read ? "Finished" : status.label)
            lists.append(FolioWidgetList(id: "shelf-\(status.rawValue)", name: "My Shelves · \(shelfName)",
                                         symbol: status.symbol, count: books.count, books: Array(books.prefix(35)), deepLink: deepLink))
        }

        let goals = FolioWidgetGoals(todayMinutes: store.todayMinutes,
                                     dailyGoal: store.data.goals.dailyMinutes, streak: store.streak,
                                     finishedThisYear: store.finishedThisYear, yearlyGoal: store.data.goals.booksPerYear)
        let snapshot = FolioWidgetSnapshot(updatedAt: .now, lists: lists, goals: goals)
        let encoder = JSONEncoder()
        guard let bytes = try? encoder.encode(snapshot) else { return }
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: destination, options: .atomic)
            let displayedCovers = Set(lists.flatMap { $0.books.compactMap(\.coverName) })
            publishCovers(from: store, books: all.filter { $0.coverFileName.map(displayedCovers.contains) ?? false },
                          wanted: displayedCovers)
            if !fetchingArtwork, !remoteArtwork.isEmpty {
                fetchingArtwork = true
                // Prioritize artwork actually visible in each shelf widget. The previous
                // alphabetical batch could skip the first displayed books entirely.
                let visible = lists.filter { $0.id.hasPrefix("shelf-") }
                    .flatMap { $0.books.prefix(6).compactMap(\.coverName) }
                Task { await fetchRemoteArtwork(remoteArtwork, preferred: visible) }
            }
            if Date().timeIntervalSince(lastReload) > 30 {
                lastReload = .now
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            // Without a configured App Group, Folio itself remains fully functional.
        }
    }

    private static func publishCovers(from store: LibraryStore, books: [LocalBook], wanted: Set<String>) {
        guard let directory = FolioWidgetStorage.coverDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for item in books {
            guard let name = item.coverFileName,
                  let from = store.coverURL(item),
                  let to = FolioWidgetStorage.coverURL(for: name),
                  !FileManager.default.fileExists(atPath: to.path) else { continue }
            try? FileManager.default.copyItem(at: from, to: to)
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for file in files where !wanted.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    /// Only the host application downloads catalogue artwork; WidgetKit reads local PNG files.
    /// This avoids network work while widgets render and makes remote shelves look as rich as
    /// imported books. Failed URLs can be retried on a later launch, but not in tight loops.
    private static func fetchRemoteArtwork(_ candidates: [String: URL], preferred: [String]) async {
        defer { fetchingArtwork = false }
        guard let directory = FolioWidgetStorage.coverDirectory else { return }
        let now = Date()
        var names: [String] = []
        var seen: Set<String> = []
        for name in preferred + candidates.keys.sorted() where seen.insert(name).inserted {
            if candidates[name] != nil { names.append(name) }
        }
        let pending = names.compactMap { name -> (String, URL)? in
            guard let url = candidates[name] else { return nil }
            return (name, url)
        }.filter { name, _ in
            guard let path = FolioWidgetStorage.coverURL(for: name),
                  !FileManager.default.fileExists(atPath: path.path) else { return false }
            return now.timeIntervalSince(attemptedArtwork[name] ?? .distantPast) > 6 * 3600
        }.prefix(20)

        var added = false
        for (name, url) in pending {
            attemptedArtwork[name] = now
            var request = URLRequest(url: url)
            request.timeoutInterval = 9
            guard let (bytes, response) = try? await URLSession.shared.data(for: request),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  bytes.count > 0, bytes.count < 10_000_000,
                  let image = FolioImageLoader.decode(bytes),
                  let png = CoverMaker.pngData(image, maxHeight: 450),
                  let target = FolioWidgetStorage.coverURL(for: name) else { continue }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try png.write(to: target, options: .atomic)
                added = true
            } catch { continue }
        }
        if added { WidgetCenter.shared.reloadTimelines(ofKind: "app.folio.reader.widgets.lists") }
    }

    /// Refresh only when the Hardcover identity or its revision changes; one API read for all shelves.
    static func refreshHardcover() async {
        guard !refreshing else { return }
        let hc = HardcoverClient.shared
        guard hc.isConnected else {
            hardcoverBooks = [:]
            publish()
            return
        }
        refreshing = true
        defer { refreshing = false }
        do {
            let all = try await hc.allUserBooks()
            hardcoverBooks = Dictionary(grouping: all.compactMap { ub -> (HCStatus, HCUserBook)? in
                guard let status = ub.status else { return nil }
                return (status, ub)
            }, by: { $0.0 }).mapValues { $0.map(\.1) }
            publish()
        } catch {
            // Keep the last successfully published shelves while temporarily offline.
        }
    }
}
