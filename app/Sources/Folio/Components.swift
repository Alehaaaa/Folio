import SwiftUI
import AppKit

// MARK: - Covers

enum ImageCache {
    nonisolated(unsafe) static let cache = NSCache<NSURL, NSImage>()
    static func image(_ url: URL) -> NSImage? {
        if let i = cache.object(forKey: url as NSURL) { return i }
        guard let i = NSImage(contentsOf: url) else { return nil }
        cache.setObject(i, forKey: url as NSURL)
        return i
    }
}

/// A flat, title-seeded cover for books without artwork.
struct GeneratedCover: View {
    var title: String
    var author: String

    private var hue: Double {
        var h: UInt64 = 1469598103934665603
        for b in title.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return Double(h % 360) / 360
    }

    var body: some View {
        Color(hue: hue, saturation: 0.42, brightness: 0.43)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .lineLimit(5)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    if !author.isEmpty {
                        Text(author).font(.system(size: 10, weight: .medium)).lineLimit(2).opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(12)
            }
            .overlay(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.18)).frame(width: 5)
            }
    }
}

struct CoverArt: View {
    var title: String
    var author: String
    var local: URL? = nil
    var remote: URL? = nil
    var cornerRadius: CGFloat = 5

    var body: some View {
        Color.clear
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .overlay {
                if let local, let img = ImageCache.image(local) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                } else if let remote {
                    AsyncImage(url: remote) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            GeneratedCover(title: title, author: author)
                        }
                    }
                } else {
                    GeneratedCover(title: title, author: author)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 4)
    }
}

extension LocalBook {
    @MainActor var cover: CoverArt {
        CoverArt(title: title, author: author, local: LibraryStore.shared.coverURL(self))
    }
}

extension String {
    /// Hardcover descriptions sometimes carry simple HTML or Markdown.
    var plainText: String {
        replacingOccurrences(of: "<br\\s*/?>", with: "\n", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .decodingHTMLEntities
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
