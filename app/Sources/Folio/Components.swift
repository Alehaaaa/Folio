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

// MARK: - Backgrounds and cards

/// The plain system content background Books uses behind its shelves.
struct Backdrop: View {
    var body: some View {
        Rectangle().fill(.background).ignoresSafeArea()
    }
}

/// A quiet grouped panel, like Books' Reading Goals and info panels.
struct GlassCard<Content: View>: View {
    var padding: CGFloat = 20
    var tint: Color? = nil
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.08)) } ?? AnyShapeStyle(.background.secondary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator.opacity(0.5), lineWidth: 0.5)
            }
    }
}

/// Books-style shelf title: bold, with a chevron when it leads somewhere.
struct SectionHeader: View {
    var title: String
    var subtitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(title).font(.title2.weight(.bold))
                        Image(systemName: "chevron.right").font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                Text(title).font(.title2.weight(.bold))
            }
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StarRating: View {
    var rating: Double
    var size: CGFloat = 11
    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { i in
                let v = rating - Double(i - 1)
                Image(systemName: v >= 0.75 ? "star.fill" : v >= 0.25 ? "star.leadinghalf.filled" : "star")
            }
        }
        .font(.system(size: size))
        .foregroundStyle(.orange)
    }
}

/// Tap-to-rate stars (half stars with a second tap).
struct StarPicker: View {
    var rating: Double?
    var onChange: (Double?) -> Void
    var body: some View {
        HStack(spacing: 4) {
            ForEach(1...5, id: \.self) { i in
                let v = (rating ?? 0) - Double(i - 1)
                Button {
                    let full = Double(i)
                    if rating == full { onChange(full - 0.5) } else if rating == full - 0.5 { onChange(nil) } else { onChange(full) }
                } label: {
                    Image(systemName: v >= 0.75 ? "star.fill" : v >= 0.25 ? "star.leadinghalf.filled" : "star")
                        .font(.title3)
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ProgressRing: View {
    var value: Double
    var lineWidth: CGFloat = 10
    var color: Color = .orange
    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(1, max(0.001, value)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
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
