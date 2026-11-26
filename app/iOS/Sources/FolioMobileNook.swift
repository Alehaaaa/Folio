import CoreImage
import ImageIO
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Items

/// One book standing in the Home nook: a library file, or a book from the
/// Hardcover or Goodreads Currently Reading shelves.
struct FolioNookItem: Identifiable {
    enum Source {
        case library(UUID)
        case remote(HCBook)
    }

    /// The key that keeps the book's place on the shelf.
    var id: String
    /// Older keys for the same book (before it was linked to Hardcover, say),
    /// so a book keeps its place when its key changes.
    var aliases: [String] = []
    var title: String
    var author: String
    var pages: Int?
    var format: BookFormat?
    var source: Source
    var localCover: URL?
    var remoteCover: URL?
    var reading = false
    var progress: Double?
    var pagesRead: Int?
    var lastActivity: Date?
    var addedAt: Date = .distantPast
    var hardcoverBookID: Int?
    var entry: FolioMobileShelfEntry?
    /// Put on the shelf by hand (dragged in from a Home row), not because
    /// it's being read.
    var pinned = false

    var keys: [String] { [id] + aliases }

    /// Identifies the cover image the spine colors are taken from.
    var coverKey: String? {
        if let localCover { return "file:" + localCover.lastPathComponent }
        return remoteCover?.absoluteString
    }

    var localID: UUID? {
        if case .library(let id) = source { return id }
        return nil
    }

    var remoteBook: HCBook? {
        if case .remote(let book) = source { return book }
        return nil
    }

    var fraction: Double? {
        if let progress, progress > 0.004 { return min(1, progress) }
        if let pagesRead, let pages, pages > 0, pagesRead > 0 { return min(1, Double(pagesRead) / Double(pages)) }
        return nil
    }

    /// Short label for the foot of the spine: "42%" or "p. 120".
    var progressLabel: String? {
        guard reading else { return nil }
        if let fraction { return "\(Int((fraction * 100).rounded()))%" }
        if let pagesRead, pagesRead > 0 { return "p. \(pagesRead)" }
        return nil
    }

    /// The last progress, written out for the long-press menu.
    var progressDetail: String? {
        guard reading else { return nil }
        var parts: [String] = []
        if let pagesRead, pagesRead > 0, let pages, pages > 0 {
            parts.append("Page \(pagesRead) of \(pages)")
        } else if let pagesRead, pagesRead > 0 {
            parts.append("Page \(pagesRead)")
        }
        if let fraction { parts.append("\(Int((fraction * 100).rounded()))%") }
        if let lastActivity {
            parts.append("read " + lastActivity.formatted(.relative(presentation: .named)))
        }
        return parts.isEmpty ? "Currently reading" : parts.joined(separator: " · ")
    }
}

@MainActor
enum FolioNookShelf {
    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func date(_ text: String?) -> Date? {
        guard let text, text.count >= 10 else { return nil }
        return day.date(from: String(text.prefix(10)))
    }

    /// The progress the book page shows: the page you just set there (kept
    /// until Hardcover catches up), else your shelf, against the page count
    /// the book page uses (your edit, then the book, then its edition).
    private static func hardcoverProgress(id: Int?, shelf: HCUserBook?, pages: Int?) -> (read: Int?, total: Int?) {
        guard let id, id > 0 else { return (shelf?.progressPages, pages) }
        let cached = FolioBookPageCache.load(id)?.page
        let total = FolioBookOverrides.shared.override(for: id)?.pages
            ?? cached?.book?.pages ?? cached?.edition?.pages ?? pages
        let read = FolioPendingProgress.value(for: id) ?? shelf?.progressPages ?? cached?.userBook?.progressPages
        return (read, total)
    }

    /// Books being read: library books opened or marked as reading, and the
    /// Currently Reading shelves, one item per book.
    static func items(library: LibraryStore, reading: [HCUserBook]) -> [FolioNookItem] {
        let read = FolioReadBooks.shared
        var items: [FolioNookItem] = []
        var byHardcover: [Int: Int] = [:]
        var byKey: [String: Int] = [:]

        for book in library.books where !read.isRead(book) {
            let match = BookMatch.key(author: book.author, title: book.title)
            let local = "book-\(book.id.uuidString)"
            var item = FolioNookItem(
                id: book.hardcoverBookID.map { "hc-\($0)" } ?? local,
                aliases: [local, "key-\(match)"],
                title: book.title, author: book.author,
                pages: book.hardcoverPages, format: book.format,
                source: .library(book.id),
                localCover: library.coverURL(book),
                reading: book.status == .reading || (book.lastOpenedAt != nil && book.progress > 0.004),
                progress: book.progress,
                lastActivity: book.lastOpenedAt,
                addedAt: book.addedAt,
                hardcoverBookID: book.hardcoverBookID
            )
            if let pages = book.hardcoverPages, book.progress > 0 {
                item.pagesRead = Int((min(1, book.progress) * Double(pages)).rounded())
            }
            if let id = book.hardcoverBookID { byHardcover[id] = items.count }
            byKey[match] = items.count
            items.append(item)
        }

        let entries = FolioMobileShelfEntry.merge(hardcover: reading, goodreads: library.tracked(.currentlyReading))
        for entry in entries {
            let hcID = entry.hardcover?.book.id ?? entry.goodreads?.hardcoverBookID
            guard !read.isRead(id: hcID, title: entry.title, author: entry.author) else { continue }
            let match = BookMatch.key(author: entry.author, title: entry.title)
            // Pages read and the page count exactly as the book page shows them.
            let synced = hardcoverProgress(id: hcID, shelf: entry.hardcover,
                                           pages: entry.hardcover?.book.pages ?? entry.goodreads?.pages)
            let hcPages = synced.read
            let started = date(entry.hardcover?.startedAt) ?? date(entry.goodreads?.dateAdded)

            if let i = hcID.flatMap({ byHardcover[$0] }) ?? byKey[match] {
                // The library copy stands for the book; the shelf adds its progress.
                items[i].reading = true
                items[i].entry = entry
                if items[i].localCover == nil { items[i].remoteCover = entry.cover }
                if (items[i].progress ?? 0) <= 0.004, let hcPages, hcPages > 0 {
                    items[i].pagesRead = hcPages
                    if items[i].pages == nil { items[i].pages = synced.total }
                }
                if items[i].lastActivity == nil { items[i].lastActivity = started }
                continue
            }

            let book = entry.hardcover?.book ?? entry.goodreads?.folioBook
            guard let book else { continue }
            // The same title, cover and pages the book page shows, with the reader's edits.
            let shown = FolioBookOverrides.shared.apply(book)
            var aliases = ["key-\(match)"]
            if let hcID, hcID > 0 { aliases.append("hc-\(hcID)") }
            let id = hcID.map { "hc-\($0)" } ?? "key-\(match)"
            aliases.removeAll { $0 == id }
            let item = FolioNookItem(
                id: id, aliases: aliases,
                title: shown.title, author: shown.authors.isEmpty ? entry.author : shown.authors,
                pages: synced.total ?? shown.pages,
                source: .remote(book),
                // The same cover as the book page: your edit, then the edition it shows.
                remoteCover: shown.imageURL ?? entry.cover,
                reading: true,
                pagesRead: hcPages,
                lastActivity: started,
                addedAt: date(entry.hardcover?.dateAdded) ?? started ?? .distantPast,
                hardcoverBookID: hcID,
                entry: entry
            )
            if let hcID { byHardcover[hcID] = items.count }
            byKey[match] = items.count
            items.append(item)
        }
        // Books put on the shelf by hand: the copy already listed stands for
        // the book, otherwise the Hardcover record does.
        for book in FolioNookStore.shared.pinned {
            let match = BookMatch.key(author: book.authors, title: book.title)
            if let i = (book.id > 0 ? byHardcover[book.id] : nil) ?? byKey[match] {
                items[i].pinned = true
                continue
            }
            var item = Self.item(for: book)
            item.pinned = true
            if book.id > 0 { byHardcover[book.id] = items.count }
            byKey[match] = items.count
            items.append(item)
        }
        // Library books join once they're being read, here or on a shelf, or
        // when they're put on it by hand.
        return items.filter { $0.reading || $0.pinned }
    }

    /// The keys a Hardcover book can stand under on the shelf.
    static func keys(for book: HCBook) -> [String] {
        let match = "key-" + BookMatch.key(author: book.authors, title: book.title)
        return book.id > 0 ? ["hc-\(book.id)", match] : [match]
    }

    /// A Hardcover book as a spine, with the reader's own edits.
    static func item(for book: HCBook) -> FolioNookItem {
        let shown = FolioBookOverrides.shared.apply(book)
        let keys = keys(for: book)
        return FolioNookItem(
            id: keys[0], aliases: Array(keys.dropFirst()),
            title: shown.title, author: shown.authors,
            pages: shown.pages,
            source: .remote(book),
            remoteCover: (book.id > 0 ? FolioBookOverrides.shared.override(for: book.id)?.coverURL : nil) ?? shown.imageURL,
            hardcoverBookID: book.id > 0 ? book.id : nil
        )
    }
}

// MARK: - Order, hidden books and shelf count

/// Where each book stands in the nook. Positions are kept like a real
/// library: new books go at the end, and only the reader moves them.
@Observable
@MainActor
final class FolioNookStore {
    static let shared = FolioNookStore()

    private enum Key {
        static let order = "folio.nook.order"
        static let hidden = "folio.nook.hidden"
        static let shelves = "folio.nook.maxShelves"
        static let pinned = "folio.nook.pinned"
    }

    private(set) var order: [String]
    /// Hidden keys, with the title they were hidden under for Settings.
    private(set) var hidden: [String: String]
    var maxShelves: Int {
        didSet { UserDefaults.standard.set(maxShelves, forKey: Key.shelves) }
    }

    static let shelfRange = 1...8

    /// A book is in the hand on the Home shelf: the page holds still under it.
    var holding = false

    /// Books put on the shelf by hand, dragged in from a Home row.
    private(set) var pinned: [HCBook]

    /// The book being dragged out of a Home row, so the shelf can show its
    /// spine while it hovers. Drags carry only text the shelf can't read
    /// until the drop, so the book itself waits here.
    @ObservationIgnored var incoming: HCBook?

    private init() {
        let defaults = UserDefaults.standard
        order = defaults.stringArray(forKey: Key.order) ?? []
        hidden = (defaults.dictionary(forKey: Key.hidden) as? [String: String]) ?? [:]
        let stored = defaults.integer(forKey: Key.shelves)
        maxShelves = Self.shelfRange.contains(stored) ? stored : 2
        pinned = defaults.data(forKey: Key.pinned).flatMap { try? JSONDecoder().decode([HCBook].self, from: $0) } ?? []
    }

    private func save() {
        UserDefaults.standard.set(order, forKey: Key.order)
        UserDefaults.standard.set(hidden, forKey: Key.hidden)
        UserDefaults.standard.set(try? JSONEncoder().encode(pinned), forKey: Key.pinned)
    }

    /// Puts a book on the shelf by hand, right after `previous` (at the very
    /// start when nil). A book already there just moves.
    func pin(_ book: HCBook, keys: [String], after previous: String?) {
        if !pinned.contains(where: { $0.id == book.id && $0.title == book.title }) { pinned.append(book) }
        for key in keys { hidden[key] = nil }
        var list = order
        list.removeAll { keys.contains($0) }
        let at = previous.flatMap { list.firstIndex(of: $0).map { $0 + 1 } } ?? (previous == nil ? 0 : list.count)
        list.insert(contentsOf: keys, at: at)
        order = list
        save()
    }

    func isHidden(_ item: FolioNookItem) -> Bool {
        item.keys.contains { hidden[$0] != nil }
    }

    /// Position in the stored order, by the item's key or one of its aliases.
    private func position(_ item: FolioNookItem, _ index: [String: Int]) -> Int? {
        item.keys.compactMap { index[$0] }.min()
    }

    /// Visible books in their places. Books not placed yet follow, oldest first.
    func arranged(_ items: [FolioNookItem]) -> [FolioNookItem] {
        let index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let visible = items.filter { !isHidden($0) }
        let placed = visible.compactMap { item in position(item, index).map { (item, $0) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
        let placedIDs = Set(placed.map(\.id))
        let fresh = visible.filter { !placedIDs.contains($0.id) }
        return placed + (order.isEmpty ? Self.firstArrangement(fresh) : fresh.sorted { $0.addedAt < $1.addedAt })
    }

    /// The very first shelf: books in progress first, most recent first,
    /// then the rest newest first, much as the shelf looked before.
    private static func firstArrangement(_ items: [FolioNookItem]) -> [FolioNookItem] {
        let reading = items.filter(\.reading)
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        let rest = items.filter { !$0.reading }.sorted { $0.addedAt > $1.addedAt }
        return reading + rest
    }

    /// Gives every new book a place at the end and moves renamed keys over.
    func register(_ items: [FolioNookItem]) {
        var changed = false
        var index = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        for item in arranged(items) {
            if index[item.id] != nil { continue }
            if let alias = item.aliases.first(where: { index[$0] != nil }), let i = index[alias] {
                order[i] = item.id
                index[item.id] = i
            } else {
                index[item.id] = order.count
                order.append(item.id)
            }
            changed = true
        }
        for item in items where !item.aliases.isEmpty {
            for alias in item.aliases where hidden[alias] != nil && hidden[item.id] == nil {
                hidden[item.id] = hidden[alias]
                hidden[alias] = nil
                changed = true
            }
        }
        // Keep the list from growing without end; drop the oldest unknown keys.
        if order.count > 600 {
            let live = Set(items.flatMap(\.keys))
            var kept = order
            var excess = kept.count - 400
            kept.removeAll { key in
                guard excess > 0, !live.contains(key) else { return false }
                excess -= 1
                return true
            }
            order = kept
            changed = true
        }
        if changed { save() }
    }

    /// Moves a book next to another, on the side it came from, like sliding
    /// it along the shelf.
    func move(_ key: String, onto target: String, visible: [FolioNookItem]) {
        guard key != target else { return }
        let ids = visible.map(\.id)
        guard let from = ids.firstIndex(of: key), let to = ids.firstIndex(of: target) else { return }
        var list = order
        if !list.contains(key) { list.append(key) }
        list.removeAll { $0 == key }
        guard let t = list.firstIndex(of: target) else { return }
        list.insert(key, at: from < to ? t + 1 : t)
        order = list
        save()
    }

    func move(_ key: String, after target: String) {
        guard key != target else { return }
        var list = order
        list.removeAll { $0 == key }
        guard let t = list.firstIndex(of: target) else { return }
        list.insert(key, at: t + 1)
        order = list
        save()
    }

    func move(_ key: String, before target: String) {
        guard key != target else { return }
        var list = order
        list.removeAll { $0 == key }
        guard let t = list.firstIndex(of: target) else { return }
        list.insert(key, at: t)
        order = list
        save()
    }

    func moveToStart(_ key: String) {
        order.removeAll { $0 == key }
        order.insert(key, at: 0)
        save()
    }

    func moveToEnd(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
        save()
    }

    func hide(_ item: FolioNookItem) {
        // A book put on the shelf by hand just comes off it again.
        if item.pinned && !item.reading {
            pinned.removeAll { book in FolioNookShelf.keys(for: book).contains { item.keys.contains($0) } }
            save()
            return
        }
        let byline = item.author.isEmpty ? item.title : "\(item.title) · \(item.author)"
        hidden[item.id] = byline
        save()
    }

    func unhide(_ key: String) {
        hidden[key] = nil
        save()
    }

    func resetOrder() {
        order = []
        save()
    }
}

// MARK: - Spine colors from covers

/// The colors of a spine, read from the book's cover: the dominant color for
/// the cloth, a second distinct color for bands and labels.
struct FolioSpinePalette: Codable, Hashable {
    var base: UInt32
    var accent: UInt32
    var lightText: Bool

    var baseColor: Color { Self.color(base) }
    var accentColor: Color { Self.color(accent) }
    var textColor: Color { lightText ? Color(hex: "#F3EBD8") : Color(hex: "#2A2622") }

    static func color(_ rgb: UInt32) -> Color {
        Color(red: Double((rgb >> 16) & 0xFF) / 255,
              green: Double((rgb >> 8) & 0xFF) / 255,
              blue: Double(rgb & 0xFF) / 255)
    }

    /// A muted cloth palette for books without a cover.
    static func fallback(for key: String) -> FolioSpinePalette {
        let cloths: [(UInt32, UInt32)] = [
            (0x40563F, 0xA98F5B), (0x8A7A66, 0x3E3A33), (0x4C6676, 0xD9C9A3),
            (0x8C5F5D, 0xE3D2B4), (0xA97B47, 0x3B2E22), (0x5F7558, 0xE8DDC2),
            (0x6E8091, 0x2E3742), (0x34483A, 0xC8A962), (0x7A3B33, 0xD8B86A),
            (0x2F3B4C, 0xB89A5E)
        ]
        let pick = cloths[Int(FolioSpineMetrics.hash(key) % UInt64(cloths.count))]
        return FolioSpinePalette(base: pick.0, accent: pick.1, lightText: luminance(pick.0) < 0.6)
    }

    static func luminance(_ rgb: UInt32) -> Double {
        let r = Double((rgb >> 16) & 0xFF) / 255, g = Double((rgb >> 8) & 0xFF) / 255, b = Double(rgb & 0xFF) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    /// Reads the dominant colors of a cover. Pixels near the left edge count
    /// more, since that is where the cover wraps around onto the spine.
    static func extract(from image: CGImage) -> FolioSpinePalette? {
        let w = 24, h = 36
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }

        struct Bucket { var r = 0.0, g = 0.0, b = 0.0, weight = 0.0, count = 0.0 }
        var buckets: [Int: Bucket] = [:]
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let key = (Int(r * 7.99) << 6) | (Int(g * 7.99) << 3) | Int(b * 7.99)
                let weight = x < w / 4 ? 1.7 : 1.0
                var bucket = buckets[key, default: Bucket()]
                bucket.r += r * weight; bucket.g += g * weight; bucket.b += b * weight
                bucket.weight += weight; bucket.count += 1
                buckets[key] = bucket
            }
        }

        typealias Candidate = (r: Double, g: Double, b: Double, score: Double)
        let candidates: [Candidate] = buckets.values.map { bucket -> Candidate in
            let r = bucket.r / bucket.weight, g = bucket.g / bucket.weight, b = bucket.b / bucket.weight
            let maxC = max(r, g, b), minC = min(r, g, b)
            let saturation = maxC == 0 ? 0 : (maxC - minC) / maxC
            let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
            // Paper-white and near-black areas are usually margins or text.
            let extremes = lum > 0.92 || lum < 0.05 ? 0.4 : 1.0
            return (r, g, b, bucket.weight * (0.45 + saturation) * extremes)
        }.sorted { $0.score > $1.score }
        guard let base = candidates.first else { return nil }

        func distance(_ a: Candidate, _ b: Candidate) -> Double {
            let dr = a.r - b.r, dg = a.g - b.g, db = a.b - b.b
            return (dr * dr + dg * dg + db * db).squareRoot()
        }
        func pack(_ r: Double, _ g: Double, _ b: Double) -> UInt32 {
            let c = { (v: Double) in UInt32(max(0, min(255, (v * 255).rounded()))) }
            return (c(r) << 16) | (c(g) << 8) | c(b)
        }

        // Soften very bright covers a touch so they read as cloth, not paper.
        var br = base.r, bg = base.g, bb = base.b
        let baseLum = 0.2126 * br + 0.7152 * bg + 0.0722 * bb
        if baseLum > 0.86 { let k = 0.86 / baseLum; br *= k; bg *= k; bb *= k }
        let basePacked = pack(br, bg, bb)

        let accentPacked: UInt32
        if let accent = candidates.dropFirst().first(where: { distance($0, base) > 0.30 && $0.score > base.score * 0.04 }) {
            accentPacked = pack(accent.r, accent.g, accent.b)
        } else {
            let shift = baseLum > 0.5 ? 0.55 : 1.6
            accentPacked = pack(min(1, br * shift), min(1, bg * shift), min(1, bb * shift))
        }
        return FolioSpinePalette(base: basePacked, accent: accentPacked, lightText: luminance(basePacked) < 0.58)
    }
}

/// Cover colors, read once per cover and kept on disk.
@Observable
@MainActor
final class FolioSpinePalettes {
    static let shared = FolioSpinePalettes()

    private(set) var palettes: [String: FolioSpinePalette] = [:]
    @ObservationIgnored private var pending: Set<String> = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-spine-colors-v1.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file),
           let stored = try? JSONDecoder().decode([String: FolioSpinePalette].self, from: data) {
            palettes = stored
        }
    }

    func palette(for item: FolioNookItem) -> FolioSpinePalette {
        item.coverKey.flatMap { palettes[$0] } ?? .fallback(for: item.id)
    }

    /// The left edge of each cover, where it wraps onto the spine, kept small
    /// in memory and on disk so spines show their art on the first frame.
    private(set) var strips: [String: UIImage] = [:]
    @ObservationIgnored private var stripsPending: Set<String> = []

    private static var stripDirectory: URL {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-spine-strips-v3", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func stripFile(_ key: String) -> URL {
        stripDirectory.appendingPathComponent(String(FolioSpineMetrics.hash(key), radix: 36) + ".jpg")
    }

    func strip(for item: FolioNookItem) -> UIImage? {
        item.coverKey.flatMap { strips[$0] }
    }

    /// Reads the colors and spine strip of any cover not seen before.
    func prepare(_ items: [FolioNookItem]) {
        for item in items {
            guard let key = item.coverKey else { continue }
            let needsPalette = palettes[key] == nil && !pending.contains(key)
            let needsStrip = strips[key] == nil && !stripsPending.contains(key)
            guard needsPalette || needsStrip else { continue }
            if needsPalette { pending.insert(key) }
            if needsStrip { stripsPending.insert(key) }
            let local = item.localCover
            let remote = item.remoteCover
            let file = Self.stripFile(key)
            Task {
                if needsStrip, !needsPalette {
                    let saved = await Task.detached(priority: .userInitiated) {
                        // Decoded here, not lazily on the main thread when the spine first draws.
                        UIImage(contentsOfFile: file.path)?.preparingForDisplay()
                    }.value
                    if let saved {
                        strips[key] = saved
                        return
                    }
                }
                var image: CGImage?
                if let local {
                    image = await Task.detached(priority: .userInitiated) { Self.thumbnail(at: local) }.value
                } else if let remote {
                    image = await FolioImageCache.shared.load(remote)?.cgImage
                }
                guard let image else {
                    pending.remove(key)
                    stripsPending.remove(key)
                    return
                }
                let palette = await Task.detached(priority: .userInitiated) { FolioSpinePalette.extract(from: image) }.value
                let strip = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                    guard let strip = Self.spineStrip(from: image) else { return nil }
                    if let data = strip.jpegData(compressionQuality: 0.85) {
                        try? data.write(to: file, options: .atomic)
                    }
                    return strip
                }.value
                if needsStrip, let strip { strips[key] = strip }
                if needsPalette, let palette {
                    palettes[key] = palette
                    scheduleSave()
                }
            }
        }
    }

    /// The leftmost fifth of a cover, which is roughly what wraps onto a real
    /// spine. It is softened once, here, before it is cached: a light blur
    /// diffuses the cover's lettering, and a cloth weave and paper grain make
    /// it read as a material rather than a cropped picture.
    private nonisolated static func spineStrip(from image: CGImage) -> UIImage? {
        let width = max(1, Int(Double(image.width) * 0.2))
        guard let cropped = image.cropping(to: CGRect(x: 0, y: 0, width: width, height: image.height)) else { return nil }
        let size = CGSize(width: cropped.width, height: cropped.height)

        // Blur, keeping the edges from fading to transparent.
        var softened = cropped
        let input = CIImage(cgImage: cropped)
        let radius = max(1.0, Double(cropped.height) * 0.006)
        if let blur = CIFilter(name: "CIGaussianBlur") {
            blur.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
            blur.setValue(radius, forKey: kCIInputRadiusKey)
            if let output = blur.outputImage?.cropped(to: input.extent),
               let rendered = spineContext.createCGImage(output, from: input.extent) {
                softened = rendered
            }
        }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            // UIKit's context is flipped relative to Core Graphics images.
            cg.saveGState()
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: 1, y: -1)
            cg.draw(softened, in: CGRect(origin: .zero, size: size))
            cg.restoreGState()

            // Cloth weave: fine threads in both directions.
            cg.setLineWidth(0.5)
            var y: CGFloat = 0
            while y < size.height {
                cg.setStrokeColor(UIColor(white: 1, alpha: 0.11).cgColor)
                cg.move(to: CGPoint(x: 0, y: y)); cg.addLine(to: CGPoint(x: size.width, y: y))
                cg.strokePath()
                cg.setStrokeColor(UIColor(white: 0, alpha: 0.10).cgColor)
                cg.move(to: CGPoint(x: 0, y: y + 1)); cg.addLine(to: CGPoint(x: size.width, y: y + 1))
                cg.strokePath()
                y += 2
            }
            var x: CGFloat = 0
            while x < size.width {
                cg.setStrokeColor(UIColor(white: 0, alpha: 0.08).cgColor)
                cg.move(to: CGPoint(x: x, y: 0)); cg.addLine(to: CGPoint(x: x, y: size.height))
                cg.strokePath()
                x += 3
            }

            // Paper grain: a sprinkle of light and dark specks, the same for every
            // cover so nothing needs a random generator.
            var seed: UInt64 = 0x9E3779B97F4A7C15
            let specks = Int(size.width * size.height / 8)
            for _ in 0..<specks {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let px = CGFloat(seed >> 40 & 0xFFFF) / 65535 * size.width
                let py = CGFloat(seed >> 24 & 0xFFFF) / 65535 * size.height
                let light = seed & 1 == 0
                cg.setFillColor(UIColor(white: light ? 1 : 0, alpha: light ? 0.12 : 0.13).cgColor)
                cg.fill(CGRect(x: px, y: py, width: 1, height: 1))
            }
        }
    }

    nonisolated(unsafe) private static let spineContext = CIContext(options: [.useSoftwareRenderer: false])

    private nonisolated static func thumbnail(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 360
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            if let data = try? JSONEncoder().encode(palettes) {
                try? data.write(to: Self.file, options: .atomic)
            }
        }
    }
}

// MARK: - Spine shape

/// How a book is bound, which sets the spine's look and type.
enum FolioSpineBinding {
    /// Cloth with gilt rules and a serif title.
    case cloth
    /// A paperback: condensed capitals and a colored cap.
    case paperback
    /// Leather with raised bands and a gilt title.
    case leather
    /// A dust jacket with a colored band and an italic title.
    case jacket
}

/// The last width each spine had, kept between launches.
enum FolioSpineWidths {
    private static let key = "folio.nook.spineWidths"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Double] =
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double]) ?? [:]

    static func known(_ id: String) -> CGFloat? {
        lock.withLock { cache[id].map { CGFloat($0) } }
    }

    static func remember(_ id: String, _ width: CGFloat) {
        let snapshot: [String: Double]? = lock.withLock {
            guard cache[id] != Double(width) else { return nil }
            cache[id] = Double(width)
            return cache
        }
        if let snapshot { UserDefaults.standard.set(snapshot, forKey: key) }
    }
}

enum FolioSpineMetrics {
    static func hash(_ text: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return hash
    }

    /// Thicker books get wider spines, on a gentle curve so a 1,000 page book
    /// isn't ten times a novella.
    static func width(for item: FolioNookItem) -> CGFloat {
        let jitter = CGFloat(hash(item.id + "w") % 5) - 2
        guard let pages = item.pages, pages > 0 else {
            if item.format == .comic { return 12 + jitter }
            // Page counts arrive a moment after Home opens. Until then a book
            // keeps the width it had last time, so the shelves don't reflow.
            if let known = FolioSpineWidths.known(item.id) { return known }
            // Unknown length: anything from a slim novella to a doorstop.
            return 14 + CGFloat(hash(item.id) % 54)
        }
        // Straight proportion to the page count, so a 600 page book is
        // about two and a half times as thick as a 250 page one,
        // and a novella is a sliver beside a doorstop.
        let width = min(98, max(10, 4 + CGFloat(pages) * 0.1 + jitter))
        FolioSpineWidths.remember(item.id, width)
        return width
    }

    /// Height as a share of the shelf: most books vary a little, big books and
    /// PDFs stand taller, comics are tall and thin.
    static func heightFactor(for item: FolioNookItem) -> CGFloat {
        var factor = 0.75 + CGFloat(hash(item.id + "h") % 17) / 100
        if let pages = item.pages {
            if pages > 600 { factor += 0.05 } else if pages < 180 { factor -= 0.04 }
        }
        switch item.format {
        case .pdf: factor = max(factor, 0.94)
        case .comic: factor = 0.97
        default: break
        }
        return min(0.98, max(0.68, factor))
    }

    static func binding(for item: FolioNookItem) -> FolioSpineBinding {
        let h = hash(item.id + "b")
        if item.format == .comic || item.format == .pdf { return .paperback }
        if let pages = item.pages {
            if pages >= 550 { return h % 3 == 0 ? .cloth : .leather }
            if pages < 220 { return h % 2 == 0 ? .paperback : .jacket }
        }
        let mix: [FolioSpineBinding] = [.cloth, .paperback, .jacket, .leather, .cloth]
        return mix[Int(h % 5)]
    }
}
