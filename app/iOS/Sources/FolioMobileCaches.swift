import SwiftUI
import UIKit

// MARK: - Images

/// Covers and portraits kept in memory and on disk, downsized once, so rows
/// show their images on the first frame instead of re-downloading each launch.
final class FolioImageCache: @unchecked Sendable {
    static let shared = FolioImageCache()

    private let memory = NSCache<NSURL, UIImage>()
    private let directory: URL
    private let session: URLSession

    private init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 400
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    private func file(for url: URL) -> URL {
        var hash: UInt64 = 1469598103934665603
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return directory.appendingPathComponent(String(hash, radix: 36) + ".jpg")
    }

    /// Memory, then disk. Cheap enough to call while building a view.
    func cached(_ url: URL) -> UIImage? {
        if let image = memory.object(forKey: url as NSURL) { return image }
        guard let image = UIImage(contentsOfFile: file(for: url).path) else { return nil }
        memory.setObject(image, forKey: url as NSURL)
        return image
    }

    func load(_ url: URL) async -> UIImage? {
        if let image = cached(url) { return image }
        guard let (data, _) = try? await session.data(from: url), let full = UIImage(data: data) else { return nil }
        // Covers never draw larger than about 300 points, so keep at most 600 pixels.
        let longest = max(full.size.width, full.size.height)
        let target = min(1, 600 / max(1, longest))
        let size = CGSize(width: full.size.width * target, height: full.size.height * target)
        let image = await full.byPreparingThumbnail(ofSize: size) ?? full
        memory.setObject(image, forKey: url as NSURL)
        if let jpeg = image.jpegData(compressionQuality: 0.85) {
            try? jpeg.write(to: file(for: url), options: .atomic)
        }
        return image
    }
}

/// An image view that shows a cached image immediately, otherwise the
/// placeholder until the download finishes.
struct FolioCachedImage<Placeholder: View>: View {
    let url: URL?
    let placeholder: () -> Placeholder
    @State private var image: UIImage?

    init(url: URL?, @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.placeholder = placeholder
        _image = State(initialValue: url.flatMap { FolioImageCache.shared.cached($0) })
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
            if let hit = FolioImageCache.shared.cached(url) {
                image = hit
                return
            }
            if let loaded = await FolioImageCache.shared.load(url) {
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
    }

    private static var memory: [Int: Snapshot] = [:]

    private static var directory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("folio-books", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func load(_ bookID: Int) -> Snapshot? {
        if let hit = memory[bookID] { return hit }
        let url = directory.appendingPathComponent("\(bookID).json")
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return nil }
        memory[bookID] = snapshot
        return snapshot
    }

    static func save(_ snapshot: Snapshot, for bookID: Int) {
        memory[bookID] = snapshot
        let url = directory.appendingPathComponent("\(bookID).json")
        if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
    }
}
