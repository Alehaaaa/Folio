import SwiftUI
import Observation

/// Five stars filled to a rating, to the fraction (3.8 fills most of the fourth).
struct FolioStars: View {
    let rating: Double
    var size: CGFloat = 13

    var body: some View {
        HStack(spacing: size * 0.15) {
            ForEach(1...5, id: \.self) { n in
                FolioPartialStar(fill: rating - Double(n - 1), size: size)
            }
        }
        .foregroundStyle(FolioTheme.caution)
        .accessibilityElement()
        .accessibilityLabel("\(rating.formatted(.number.precision(.fractionLength(1)))) out of 5 stars")
    }
}

/// One serif title over a horizontal row, as on Home.
struct FolioMobileRow<Content: View>: View {
    let title: String
    /// When set, the title opens this full list, as Discover's row titles do.
    var seeAll: FolioMobileTopicRoute? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let seeAll {
                NavigationLink(value: seeAll) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.folioDisplay(.title2))
                            .foregroundStyle(FolioTheme.ink)
                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FolioTheme.olive)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHint("Show all")
            } else {
                Text(title)
                    .font(.folioDisplay(.title2))
                    .foregroundStyle(FolioTheme.ink)
                    .accessibilityAddTraits(.isHeader)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) { content() }
                    .padding(.vertical, 4)
            }
            .contentMargins(.horizontal, 20)
            .padding(.horizontal, -20)
        }
    }
}

extension String {
    /// "2014-07-15" as a readable date; other strings pass through.
    var folioReadableDate: String {
        guard let date = Self.folioDayParser.date(from: String(prefix(10))) else { return self }
        return date.formatted(date: .long, time: .omitted)
    }

    /// Made once: building a DateFormatter for every date shown is slow.
    private static let folioDayParser: DateFormatter = {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        return parser
    }()
}
