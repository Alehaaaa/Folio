import Foundation
import Observation

/// Keeps every linked reading service in step with the library, the way
/// ShelfSync does in KOReader: each book is found on each service (by ISBN,
/// then title and author), then its status and reading progress are sent.
/// Only changes are sent, so reopening a book costs nothing.
@Observable
@MainActor
final class FolioShelfSync {
    static let shared = FolioShelfSync()

    struct Run: Equatable { var done = 0; var total = 0 }

    private(set) var accounts: [ShelfService: ShelfAccount] = [:]
    private(set) var runs: [ShelfService: Run] = [:]
    var errors: [ShelfService: String] = [:]
    private(set) var lastSync: [ShelfService: Date] = [:]
    private(set) var automatic: [ShelfService: Bool] = [:]
    private var links: [String: [String: ShelfLink]] = [:]
    private var providers: [ShelfService: ShelfProvider] = [:]
    private var busy: Set<String> = []

    private static let linksKey = "folio.shelfsync.links"
    private static let lastSyncKey = "folio.shelfsync.lastSync"
    private static func autoKey(_ s: ShelfService) -> String { "folio.shelfsync.auto." + s.rawValue }

    private init() {
        let preview = ProcessInfo.processInfo.environment["FOLIO_PREVIEW_NO_KEYCHAIN"] == "1"
        for s in ShelfService.allCases {
            if !preview, let a = ShelfKeychain.read(s) { accounts[s] = a }
            automatic[s] = UserDefaults.standard.object(forKey: Self.autoKey(s)) as? Bool ?? true
        }
        if let data = UserDefaults.standard.data(forKey: Self.linksKey),
           let saved = try? JSONDecoder().decode([String: [String: ShelfLink]].self, from: data) {
            links = saved
        }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.lastSyncKey) as? [String: Double] {
            for (k, v) in saved { if let s = ShelfService(rawValue: k) { lastSync[s] = Date(timeIntervalSince1970: v) } }
        }
    }

    /// Called at launch: status changes anywhere in the library reach every service.
    static func install() {
        LibraryStore.statusChanged = { id in
            Task { @MainActor in await FolioShelfSync.shared.sync(bookID: id) }
        }
    }

    // MARK: Accounts

    func isConnected(_ s: ShelfService) -> Bool { accounts[s] != nil }
    var anyConnected: Bool { !accounts.isEmpty }

    func setAutomatic(_ s: ShelfService, _ on: Bool) {
        automatic[s] = on
        UserDefaults.standard.set(on, forKey: Self.autoKey(s))
    }

    func connect(_ s: ShelfService, account: ShelfAccount) {
        accounts[s] = account
        providers[s] = nil
        errors[s] = nil
        ShelfKeychain.write(account, for: s)
        if s == .goodreads {
            GoodreadsClient.shared.userID = account.userID ?? ""
        }
    }

    func signIn(_ s: ShelfService, login: String, password: String) async {
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !login.isEmpty, !password.isEmpty else { return }
        errors[s] = nil
        do {
            let account: ShelfAccount
            switch s {
            case .fable: account = try await FableProvider.signIn(email: login, password: password)
            case .pagebound: account = try await PageboundProvider.signIn(email: login, password: password)
            case .librarything: account = try await LibraryThingProvider.signIn(username: login, password: password)
            case .storygraph, .goodreads: return
            }
            connect(s, account: account)
            Task { await syncLibrary(s) }
        } catch {
            errors[s] = error.localizedDescription
        }
    }

    func signOut(_ s: ShelfService) {
        if s == .goodreads { GoodreadsClient.shared.userID = "" }
        accounts[s] = nil
        providers[s] = nil
        errors[s] = nil
        links[s.rawValue] = nil
        saveLinks()
        ShelfKeychain.write(nil, for: s)
    }

    func linkedCount(_ s: ShelfService) -> Int {
        (links[s.rawValue] ?? [:]).values.filter { $0.id != nil }.count
    }

    private func provider(_ s: ShelfService) -> ShelfProvider? {
        if let p = providers[s] { return p }
        guard let account = accounts[s] else { return nil }
        let save: (ShelfAccount) -> Void = { [weak self] updated in
            self?.accounts[s] = updated
            ShelfKeychain.write(updated, for: s)
        }
        let p: ShelfProvider = switch s {
        case .storygraph: StoryGraphProvider(account: account, save: save)
        case .goodreads: GoodreadsShelfProvider(account: account, save: save)
        case .fable: FableProvider(account: account, save: save)
        case .pagebound: PageboundProvider(account: account, save: save)
        case .librarything: LibraryThingProvider(account: account, save: save)
        }
        providers[s] = p
        return p
    }

    // MARK: Syncing

    /// Sends one book's status and progress to every service that syncs automatically.
    func sync(bookID: UUID, library: LibraryStore = .shared) async {
        for s in ShelfService.allCases where isConnected(s) && automatic[s] == true {
            guard let book = library.book(bookID) else { return }
            _ = await sync(book, on: s, retryMissing: false)
        }
    }

    /// A few books whose status or progress never reached a service (offline, say).
    func pushPending(library: LibraryStore = .shared) {
        for s in ShelfService.allCases where isConnected(s) && automatic[s] == true && runs[s] == nil {
            let pending = library.books.filter { needsSync($0, on: s) }
                .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
                .prefix(5)
            guard !pending.isEmpty else { continue }
            Task {
                for book in pending { if await sync(book, on: s, retryMissing: false) == .signedOut { break } }
            }
        }
    }

    /// Every book in the library with a status, shown as "Syncing X of Y".
    func syncLibrary(_ s: ShelfService, library: LibraryStore = .shared) async {
        guard isConnected(s), runs[s] == nil else { return }
        let books = library.books.filter { $0.status.hardcover != nil }
            .sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
        runs[s] = Run(done: 0, total: books.count)
        errors[s] = nil
        defer { runs[s] = nil }
        // Goodreads syncs both ways: the newest change wins, for library
        // books and for books only on your Hardcover shelves.
        var hardcoverOnly: [HCUserBook] = []
        if s == .goodreads {
            await GoodreadsClient.shared.syncAll(into: library)
            pullFromGoodreads(library: library)
            hardcoverOnly = await hardcoverOnlyBooks(library: library)
            runs[s]?.total += hardcoverOnly.count
        }
        for book in books {
            guard let current = library.book(book.id) else { continue }
            let result = await sync(current, on: s, retryMissing: true)
            runs[s]?.done += 1
            if result == .signedOut { return }
            if result == .sent { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        for item in hardcoverOnly {
            let result = await reconcile(item, library: library)
            runs[s]?.done += 1
            if result == .signedOut { return }
            if result == .sent { try? await Task.sleep(nanoseconds: 400_000_000) }
        }
        lastSync[s] = Date()
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: lastSync.map { ($0.key.rawValue, $0.value.timeIntervalSince1970) }),
                                  forKey: Self.lastSyncKey)
    }

    // MARK: Two-way Goodreads sync

    /// Library books whose Goodreads shelf changed after their Folio status take the Goodreads one.
    private func pullFromGoodreads(library: LibraryStore) {
        for book in library.books {
            guard let t = library.trackedMatch(hardcoverBookID: book.hardcoverBookID, author: book.author, title: book.title),
                  let theirs = t.status, [HCStatus.wantToRead, .reading, .read].contains(theirs),
                  book.status.hardcover != theirs,
                  let changed = Self.goodreadsDate(t), changed > Self.folioDate(book) else { continue }
            library.setStatus(book.id, theirs.local, hardcover: HardcoverClient.shared)
        }
    }

    /// Books on your Hardcover shelves with no copy in the library.
    private func hardcoverOnlyBooks(library: LibraryStore) async -> [HCUserBook] {
        let hardcover = HardcoverClient.shared
        guard hardcover.isConnected, let all = try? await hardcover.allUserBooks() else { return [] }
        return all.filter { ub in
            guard ub.status != nil else { return false }
            if library.books.contains(where: { $0.hardcoverBookID == ub.book.id }) { return false }
            return library.localCopy(author: ub.book.authors, title: ub.workTitle ?? ub.book.title) == nil
                && library.localCopy(author: ub.book.authors, title: ub.book.title) == nil
        }
    }

    /// Hardcover and Goodreads agree on a Hardcover-only book: the newer change wins.
    private func reconcile(_ ub: HCUserBook, library: LibraryStore) async -> Outcome {
        guard let status = ub.status else { return .skipped }
        let book = ub.book
        let t = library.trackedMatch(hardcoverBookID: book.id, author: book.authors, title: ub.workTitle ?? book.title)
            ?? library.trackedMatch(hardcoverBookID: nil, author: book.authors, title: book.title)
        if let t, let theirs = t.status, theirs != status,
           let changed = Self.goodreadsDate(t), changed > Self.hardcoverDate(ub) {
            _ = await HardcoverClient.shared.setStatus(bookID: book.id, status: theirs)
            return .sent
        }
        if t?.status == status { return .skipped }
        let key = "hc-\(book.id)"
        return await send(Item(key: key, title: ub.workTitle ?? book.title, author: book.authors,
                               hardcoverBookID: book.id, status: status),
                          on: .goodreads, retryMissing: false)
    }

    private static func folioDate(_ book: LocalBook) -> Date {
        book.statusChangedAt ?? (book.status == .finished ? book.finishedAt : nil) ?? book.addedAt
    }

    private static func goodreadsDate(_ t: TrackedBook) -> Date? {
        t.shelfChangedAt ?? parseDate(t.dateRead) ?? parseDate(t.dateAdded)
    }

    private static func hardcoverDate(_ ub: HCUserBook) -> Date {
        parseDate(ub.updatedAt) ?? parseDate(ub.finishedAt) ?? parseDate(ub.startedAt) ?? parseDate(ub.dateAdded) ?? .distantPast
    }

    /// Hardcover's timestamps and dates, and the date styles Goodreads feeds use.
    static func parseDate(_ text: String?) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: text) { return d }
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: text) { return d }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSSZZZZZ", "yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss",
                       "yyyy-MM-dd", "yyyy/MM/dd", "EEE, dd MMM yyyy HH:mm:ss Z", "EEE MMM dd HH:mm:ss Z yyyy",
                       "MMM dd, yyyy", "MMM d, yyyy"] {
            f.dateFormat = format
            if let d = f.date(from: text) { return d }
        }
        return nil
    }

    private func percent(_ book: LocalBook) -> Int { Int((min(1, max(0, book.progress)) * 100).rounded(.down)) }

    private func needsSync(_ book: LocalBook, on s: ShelfService) -> Bool {
        guard let status = book.status.hardcover, s.supports(status) else { return false }
        guard let link = links[s.rawValue]?[book.id.uuidString] else { return true }
        guard link.id != nil else { return Date().timeIntervalSince(link.checkedAt) > 7 * 24 * 3600 }
        if link.status != status.rawValue { return true }
        return s.sendsProgress && status == .reading && percent(book) > 0 && link.percent != percent(book)
    }

    enum Outcome { case skipped, sent, failed, signedOut }

    /// What a service needs to find a book and shelve it.
    private struct Item {
        var key: String
        var title: String
        var author: String
        var isbn: String?
        var hardcoverBookID: Int?
        var status: HCStatus
        var percent = 0
    }

    private func sync(_ book: LocalBook, on s: ShelfService, retryMissing: Bool) async -> Outcome {
        guard let status = book.status.hardcover else { return .skipped }
        return await send(Item(key: book.id.uuidString, title: book.title, author: book.author, isbn: book.isbn,
                               hardcoverBookID: book.hardcoverBookID, status: status, percent: percent(book)),
                          on: s, retryMissing: retryMissing)
    }

    /// A status set on a book outside the library (a My Shelves entry, a
    /// recommendation) reaches every service that syncs automatically, so
    /// marking it read on Hardcover also takes it off Goodreads' Want to Read.
    func sync(_ status: HCStatus, for book: HCBook) async {
        let key = book.id > 0 ? "hc-\(book.id)" : "t-" + BookMatch.key(author: book.authors, title: book.title)
        let item = Item(key: key, title: book.title, author: book.authors,
                        hardcoverBookID: book.id > 0 ? book.id : nil, status: status)
        for s in ShelfService.allCases where isConnected(s) && automatic[s] == true {
            _ = await send(item, on: s, retryMissing: true)
        }
    }

    private func send(_ item: Item, on s: ShelfService, retryMissing: Bool) async -> Outcome {
        let status = item.status
        guard s.supports(status), let p = provider(s) else { return .skipped }
        let key = s.rawValue + item.key
        guard !busy.contains(key) else { return .skipped }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            var link = links[s.rawValue]?[item.key]
            // The copy already on a Goodreads shelf is the one to move, even when
            // an earlier search linked another edition.
            if s == .goodreads, let gid = trackedGoodreadsID(item), link?.id != gid {
                link = ShelfLink(id: gid, title: item.title)
                store(link!, for: item.key, on: s)
            }
            if link == nil || (link?.id == nil && (retryMissing || Date().timeIntervalSince(link!.checkedAt) > 7 * 24 * 3600)) {
                link = try await find(item, with: p)
                store(link!, for: item.key, on: s)
            }
            guard var link, link.id != nil else { return .skipped }
            var sent = false
            if link.status != status.rawValue {
                try await p.setStatus(status, link: &link)
                link.status = status.rawValue
                sent = true
                store(link, for: item.key, on: s)
            }
            // My Shelves shows the Goodreads copy on its new shelf straight away.
            if s == .goodreads { LibraryStore.shared.moveTracked(goodreadsID: link.id, hardcoverBookID: item.hardcoverBookID,
                                                                  author: item.author, title: item.title, to: status) }
            let pct = item.percent
            if s.sendsProgress, status == .reading, pct > 0, pct < 100, link.percent != pct {
                try await p.setProgress(percent: pct, link: &link)
                link.percent = pct
                sent = true
                store(link, for: item.key, on: s)
            }
            if errors[s] != nil { errors[s] = nil }
            return sent ? .sent : .skipped
        } catch let e as ShelfError {
            errors[s] = e.message
            return e.signedOut ? .signedOut : .failed
        } catch is CancellationError {
            return .failed
        } catch {
            errors[s] = error.localizedDescription
            return .failed
        }
    }

    private func trackedGoodreadsID(_ item: Item) -> String? {
        LibraryStore.shared.trackedMatch(hardcoverBookID: item.hardcoverBookID,
                                         author: item.author, title: item.title)?.goodreadsID
    }

    private func store(_ link: ShelfLink, for key: String, on s: ShelfService) {
        links[s.rawValue, default: [:]][key] = link
        saveLinks()
    }

    private func saveLinks() {
        if let data = try? JSONEncoder().encode(links) { UserDefaults.standard.set(data, forKey: Self.linksKey) }
    }

    // MARK: Finding a book on a service

    private static let minor: Set<String> = ["the", "a", "an", "of", "and", "el", "la", "los", "las", "le", "les", "der", "die", "das"]

    private static func titleWords(_ title: String) -> [String] {
        let main = title.split(separator: ":").first.map(String.init) ?? title
        return BookAutoMatch.words(main).filter { !minor.contains($0) }
    }

    /// The found title starts with the library title's main words (subtitles and series suffixes allowed).
    private static func sameBook(_ book: Item, _ found: ShelfFound) -> Bool {
        let wanted = titleWords(book.title)
        guard !wanted.isEmpty else { return false }
        let got = Set(BookAutoMatch.words(found.title))
        guard wanted.prefix(4).allSatisfy(got.contains) else { return false }
        let surnames = BookAutoMatch.words(book.author).filter { $0.count > 2 }
        let theirs = Set(BookAutoMatch.words(found.author))
        return surnames.isEmpty || theirs.isEmpty || surnames.contains(where: theirs.contains)
    }

    private func find(_ book: Item, with p: ShelfProvider) async throws -> ShelfLink {
        func link(_ f: ShelfFound) -> ShelfLink {
            ShelfLink(id: f.id, extra: p.service == .pagebound ? f.extra : nil, title: f.title, pages: f.pages)
        }

        if let isbn = book.isbn.flatMap(BookAutoMatch.isbn(in:)) {
            let found = try await p.search(isbn, isbn: true)
            if let f = found.first(where: { Self.sameBook(book, $0) }) ?? (found.count == 1 ? found[0] : nil) {
                return link(f)
            }
        }
        let main = book.title.split(separator: ":").first.map(String.init) ?? book.title
        let author = book.author.split(separator: ",").first.map(String.init) ?? book.author
        let found = try await p.search("\(main) \(author)".trimmingCharacters(in: .whitespaces), isbn: false)
        if let f = found.first(where: { Self.sameBook(book, $0) }) { return link(f) }
        if found.isEmpty, !author.isEmpty {
            let byTitle = try await p.search(main, isbn: false)
            if let f = byTitle.first(where: { Self.sameBook(book, $0) }) { return link(f) }
        }
        return ShelfLink(id: nil)
    }
}
