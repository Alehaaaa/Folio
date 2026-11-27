import ImageIO
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Images

/// Covers and portraits kept in memory and on disk, downsized once, so rows
/// show their images on the first frame instead of re-downloading each launch.
final class FolioImageCache: @unchecked Sendable {
    static let shared = FolioImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let localMemory = NSCache<NSString, LocalCover>()

    /// A decoded library cover and the file date it was read at.
    private final class LocalCover {
        let image: UIImage
        let modified: Date?
        init(image: UIImage, modified: Date?) { self.image = image; self.modified = modified }
    }
    private let directory: URL
    private let session: URLSession

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 200
        // Decoded covers are about 1 MB each; keep the cache well under iOS's memory limit.
        memory.totalCostLimit = 48 * 1_048_576
        localMemory.countLimit = 120
        localMemory.totalCostLimit = 32 * 1_048_576
        let config = URLSessionConfiguration.default
        // The downsized copy in `directory` is the cache. URLCache kept every full-size
        // original a second time (a 3000-pixel cover can be over 1 MB).
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        let dir = directory
        Task.detached(priority: .background) { Self.trim(dir) }
    }

    /// Keeps the saved images under `limit`, dropping the least recently used.
    private static func trim(_ dir: URL, limit: Int = 150 * 1_048_576, target: Int = 100 * 1_048_576) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { url -> (url: URL, size: Int, used: Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return (url, values.fileSize ?? 0, values.contentAccessDate ?? values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > limit else { return }
        entries.sort { $0.used < $1.used }
        for entry in entries where total > target {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }

    private func file(for url: URL) -> URL {
        var hash: UInt64 = 1469598103934665603
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return directory.appendingPathComponent(String(hash, radix: 36) + ".jpg")
    }

    /// Memory only: the one lookup cheap enough to make while building a view.
    func memoryHit(_ url: URL) -> UIImage? {
        memory.object(forKey: url as NSURL)
    }

    /// Memory, then disk. The disk copy is decoded here, so call it off the main
    /// thread: a lazily decoded JPEG would otherwise decode on the main thread
    /// in the middle of a scroll.
    func cached(_ url: URL, maxPixels: Int = FolioImageCache.coverPixels) -> UIImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        guard let data = try? Data(contentsOf: file(for: url)),
              let image = Self.thumbnail(data, maxPixels: maxPixels) else { return nil }
        memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
        return image
    }

    /// A library cover already decoded, from memory only. Library covers are
    /// written under a new name whenever they change, so the path is the key.
    func localCoverInMemory(_ file: URL) -> UIImage? {
        localMemory.object(forKey: file.path as NSString)?.image
    }

    /// A cover file from the library, decoded once at screen size. Reads the
    /// disk, so call it off the main thread (see `loadLocalCover`).
    func localCover(_ file: URL) -> UIImage? {
        let key = file.path as NSString
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if let entry = localMemory.object(forKey: key), entry.modified == modified { return entry.image }
        guard let data = try? Data(contentsOf: file), let image = Self.thumbnail(data, maxPixels: Self.coverPixels) else { return nil }
        localMemory.setObject(LocalCover(image: image, modified: modified), forKey: key, cost: Self.cost(of: image))
        return image
    }

    /// `localCover`, read and decoded in the background.
    func loadLocalCover(_ file: URL) async -> UIImage? {
        await Task.detached(priority: .userInitiated) { self.localCover(file) }.value
    }

    private let inflightLock = NSLock()
    private var inflight: [URL: Task<UIImage?, Never>] = [:]

    /// Covers never draw larger than about 300 points, so keep at most 600 pixels.
    static let coverPixels = 600

    /// Memory, disk, then the network. Tiles asking for the same cover at once share one download.
    /// `maxPixels` is the longest side kept; `urgent` puts the download ahead of
    /// the covers loading at the same time (an author's portrait over a row of 15 covers).
    func load(_ url: URL, maxPixels: Int = FolioImageCache.coverPixels, urgent: Bool = false) async -> UIImage? {
        if let image = memoryHit(url) { return image }
        if let image = await Task.detached(priority: .userInitiated, operation: { self.cached(url, maxPixels: maxPixels) }).value {
            return image
        }
        let task: Task<UIImage?, Never> = inflightLock.withLock {
            if let running = inflight[url] { return running }
            let started = Task.detached(priority: urgent ? .high : .userInitiated) {
                await self.download(url, maxPixels: maxPixels, urgent: urgent)
            }
            inflight[url] = started
            return started
        }
        let image = await task.value
        inflightLock.withLock { inflight[url] = nil }
        return image
    }

    /// Downloads covers before their rows scroll into view, a few at a time, so
    /// they are already on disk when shown. Covers saved before are skipped.
    func prefetch(_ urls: [URL]) {
        var seen = Set<URL>()
        let wanted = urls.filter { url in
            seen.insert(url).inserted && memory.object(forKey: url as NSURL) == nil
                && !FileManager.default.fileExists(atPath: file(for: url).path)
        }
        guard !wanted.isEmpty else { return }
        Task.detached(priority: .utility) {
            var index = 0
            while index < wanted.count {
                let batch = wanted[index..<min(index + 6, wanted.count)].map { url in
                    Task.detached(priority: .utility) { _ = await self.load(url) }
                }
                for request in batch { await request.value }
                index += batch.count
            }
        }
    }

    /// Images that couldn't be read (SVG avatars, broken links), not asked for again this session.
    private var failed = Set<URL>()

    private func download(_ url: URL, maxPixels: Int, urgent: Bool) async -> UIImage? {
        // ImageIO can't draw SVG (Hardcover's default avatars): show the placeholder instead.
        if url.pathExtension.lowercased() == "svg" { return nil }
        if inflightLock.withLock({ failed.contains(url) }) { return nil }
        let started = Date()
        var data = Data()
        var status = 0
        // Open Library's covers come from archive.org, which often answers a moment of
        // load with a 5xx or a timeout: try twice before showing the placeholder.
        for attempt in 0..<2 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(1.5))
                if Task.isCancelled { return nil }
            }
            let answer = try? await fetch(url, urgent: urgent)
            data = answer?.0 ?? Data()
            status = answer.map { ($0.1 as? HTTPURLResponse)?.statusCode ?? 200 } ?? 0
            let took = Date().timeIntervalSince(started)
            if took > 2 || !(200..<300).contains(status) {
                FolioLog.log("\(url.host ?? "?") \(url.lastPathComponent): HTTP \(status) in "
                             + took.formatted(.number.precision(.fractionLength(1))) + " s, \(data.count / 1024) KB", "images")
            }
            if status == 0 || status == 429 || status >= 500 { continue }
            break
        }
        // A missing photo (Open Library answers 404 with default=false): the placeholder stays.
        // Busy or unreachable is not remembered, so the next time the cover shows it tries again.
        guard (200..<300).contains(status) else {
            if (400..<500).contains(status), status != 429 { _ = inflightLock.withLock { failed.insert(url) } }
            return nil
        }
        // ImageIO decodes straight to the drawn size: decoding a full 3000-pixel cover
        // first takes tens of MB each, and a screen of them can exceed the memory limit.
        guard let image = Self.thumbnail(data, maxPixels: maxPixels) else {
            FolioLog.log("Unreadable image (\(data.count) bytes) at \(url.lastPathComponent)", "images")
            _ = inflightLock.withLock { failed.insert(url) }
            return nil
        }
        memory.setObject(image, forKey: url as NSURL, cost: Self.cost(of: image))
        if let jpeg = image.jpegData(compressionQuality: 0.8) {
            try? jpeg.write(to: file(for: url), options: .atomic)
        }
        return image
    }

    /// One download; an urgent one is marked high priority so URLSession sends it
    /// before the covers already queued for the same host.
    private func fetch(_ url: URL, urgent: Bool) async throws -> (Data, URLResponse) {
        guard urgent else { return try await session.data(from: url) }
        let box = FolioImageTaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: url) { data, response, error in
                    if let data, let response { continuation.resume(returning: (data, response)) }
                    else { continuation.resume(throwing: error ?? URLError(.badServerResponse)) }
                }
                task.priority = URLSessionTask.highPriority
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }

    private static func thumbnail(_ data: Data, maxPixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    private static func cost(of image: UIImage) -> Int {
        Int(image.size.width * image.scale * image.size.height * image.scale * 4)
    }
}

/// Holds the URLSession task of an urgent download, so cancelling the Swift task cancels it.
private final class FolioImageTaskBox: @unchecked Sendable {
    var task: URLSessionDataTask?
}

/// An image view that shows a cached image immediately, otherwise the
/// placeholder until the download finishes.
struct FolioCachedImage<Placeholder: View>: View {
    let url: URL?
    var maxPixels = FolioImageCache.coverPixels
    var urgent = false
    let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: URL?, maxPixels: Int = FolioImageCache.coverPixels, urgent: Bool = false,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.maxPixels = maxPixels
        self.urgent = urgent
        self.placeholder = placeholder
        // Memory only: this runs every time the parent redraws, so it must never touch the disk.
        _image = State(initialValue: url.flatMap { FolioImageCache.shared.memoryHit($0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = FolioImageCache.shared.memoryHit(url) {
                if image !== hit { image = hit }
                return
            }
            if let loaded = await FolioImageCache.shared.load(url, maxPixels: maxPixels, urgent: urgent) {
                withAnimation(.easeInOut(duration: 0.15)) { image = loaded }
            }
        }
    }
}

// MARK: - Book pages

/// The last Hardcover data shown for each book, so the page opens complete and
/// refreshes quietly.
enum FolioBookPageCache {
    struct Snapshot: Codable {
        var page: HCBookPage
        var seriesBooks: [HCSeriesBook] = []
        var reviews: [HCReview] = []
        var saved = Date()
        var moreByAuthor: [HCBook]?
        var similar: [HCBook]?
    }

    private static var memory: [Int: Snapshot] = [:]
    private static let writer = DispatchQueue(label: "folio.book-pages", qos: .utility)
    /// Books with nothing saved, so views asking on every redraw don't read the disk each time.
    private static var missing: Set<Int> = []

    private static let directory: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func load(_ bookID: Int) -> Snapshot? {
        if let hit = memory[bookID] { return hit }
        if missing.contains(bookID) { return nil }
        let url = directory.appendingPathComponent("\(bookID).json")
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else {
            missing.insert(bookID)
            return nil
        }
        memory[bookID] = snapshot
        return snapshot
    }

    static func save(_ snapshot: Snapshot, for bookID: Int) {
        memory[bookID] = snapshot
        missing.remove(bookID)
        let url = directory.appendingPathComponent("\(bookID).json")
        // Written in the background, in order: a page saves several times while it loads.
        writer.async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }
}
