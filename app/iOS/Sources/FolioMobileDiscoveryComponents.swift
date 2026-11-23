import SwiftUI

/// A reusable, cover-first Hardcover tile for Discover and Home.
/// Navigation uses the existing HCBook destination provided by the parent NavigationStack.
struct FolioMobileRemoteBookTile: View {
    let book: HCBook
    var width: CGFloat? = nil

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        NavigationLink(value: book) {
            VStack(alignment: .leading, spacing: 7) {
                GeometryReader { geometry in
                    AsyncImage(url: book.imageURL, transaction: Transaction(animation: .easeInOut(duration: 0.18))) { phase in
                        Group {
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                            case .empty, .failure:
                                ZStack {
                                    Color.secondary.opacity(0.10)
                                    Image(systemName: "book.closed.fill")
                                        .font(.title2)
                                        .foregroundStyle(.secondary)
                                }
                            @unknown default:
                                Color.secondary.opacity(0.1)
                            }
                        }
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                    }
                }
                .aspectRatio(0.69, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(.primary.opacity(0.07), lineWidth: 0.7)
                }

                Text(book.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)

                Text(book.authors.isEmpty ? "Unknown author" : book.authors)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .frame(width: width, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(book.title), \(book.authors.isEmpty ? "unknown author" : book.authors)")
        .accessibilityHint("Open book details")
    }
}

/// Adaptive columns on phones and tablets, with wider tiles for accessibility text sizes.
struct FolioMobileRemoteBookGridSection: View {
    let title: String
    var subtitle: String? = nil
    let books: [HCBook]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        let minWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 215 : 158
        let maxWidth: CGFloat = dynamicTypeSize.isAccessibilitySize ? 350 : 240
        return [GridItem(.adaptive(minimum: minWidth, maximum: maxWidth), spacing: 16, alignment: .top)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.folioDisplay(.title2))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                ForEach(books) { book in
                    FolioMobileRemoteBookTile(book: book)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

struct FolioMobileDiscoverySection: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let books: [HCBook]
}

/// These sections are only classifications of titles actually returned by
/// Hardcover's trending/popularity endpoint, never inferred genres or tastes.
enum FolioMobileDiscoverySections {
    static func unique(_ books: [HCBook]) -> [HCBook] {
        var ids = Set<Int>()
        return books.filter { ids.insert($0.id).inserted }
    }

    static func highlyRated(_ books: [HCBook]) -> [HCBook] {
        unique(books)
            .filter { ($0.rating ?? 0) >= 4 && ($0.ratingsCount ?? 0) >= 5 }
            .sorted {
                if $0.rating != $1.rating { return ($0.rating ?? 0) > ($1.rating ?? 0) }
                return ($0.ratingsCount ?? 0) > ($1.ratingsCount ?? 0)
            }
    }

    static func recent(_ books: [HCBook], year: Int = Calendar.current.component(.year, from: .now)) -> [HCBook] {
        unique(books)
            .filter { ($0.year ?? 0) >= year - 2 && ($0.year ?? 0) <= year }
            .sorted {
                if $0.year != $1.year { return ($0.year ?? 0) > ($1.year ?? 0) }
                return $0.id < $1.id
            }
    }

    static func build(from books: [HCBook]) -> [FolioMobileDiscoverySection] {
        let uniqueBooks = unique(books)
        var assigned = Set<Int>()
        var sections: [FolioMobileDiscoverySection] = []

        func append(_ id: String, _ title: String, _ subtitle: String, _ candidates: [HCBook], limit: Int? = nil) {
            let available = candidates.filter { !assigned.contains($0.id) }
            let chosen = Array(available.prefix(limit ?? available.count))
            guard !chosen.isEmpty else { return }
            chosen.forEach { assigned.insert($0.id) }
            sections.append(FolioMobileDiscoverySection(id: id, title: title, subtitle: subtitle, books: chosen))
        }

        append("popular", "Trending & Popular", "From Hardcover's trending feed, or its popular-books fallback.", uniqueBooks, limit: 8)
        append("rated", "Highly Rated", "Books rated 4.0+ by at least five Hardcover readers.", highlyRated(uniqueBooks), limit: 8)
        append("recent", "Recently Published", "Books with a publication year in the last three calendar years.", recent(uniqueBooks), limit: 8)
        append("more", "More to Explore", "Other books in this Hardcover selection.", uniqueBooks)
        return sections
    }
}
