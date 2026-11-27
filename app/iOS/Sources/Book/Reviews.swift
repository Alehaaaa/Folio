import SwiftUI
import Observation

/// Average, count and the five-bar distribution, as on Goodreads.
struct FolioMobileRatingsSummary: View {
    let stats: HCBookStats
    /// The bars are still on their way: grey rows of the same size hold their place.
    var barsLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                Text((stats.rating ?? 0).formatted(.number.precision(.fractionLength(2))))
                    .font(.system(size: 44, weight: .regular, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .monospacedDigit()
                VStack(alignment: .leading, spacing: 5) {
                    FolioStars(rating: stats.rating ?? 0, size: 16)
                    Text(countsLine)
                        .font(.footnote)
                        .foregroundStyle(FolioTheme.muted)
                }
            }
            if stats.distribution.count == 5 || barsLoading {
                let bars = stats.distribution.count == 5 ? stats.distribution : [0, 0, 0, 0, 0]
                let total = max(1, bars.reduce(0, +))
                VStack(spacing: 6) {
                    ForEach(0..<5, id: \.self) { index in
                        let share = Double(bars[index]) / Double(total)
                        HStack(spacing: 10) {
                            Text("\(5 - index)")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(FolioTheme.muted)
                                .frame(width: 12)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(FolioTheme.line.opacity(0.6))
                                    Capsule().fill(FolioTheme.caution)
                                        .frame(width: max(share > 0 ? 4 : 0, geo.size.width * share))
                                }
                            }
                            .frame(height: 8)
                            Text("\(Int((share * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(FolioTheme.muted)
                                .monospacedDigit()
                                .frame(width: 38, alignment: .trailing)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(5 - index) stars, \(Int((share * 100).rounded())) percent")
                    }
                }
                .redacted(reason: stats.distribution.count == 5 ? [] : .placeholder)
            }
        }
    }

    private var countsLine: String {
        var parts: [String] = []
        if let n = stats.ratingsCount { parts.append("\(n.formatted()) ratings") }
        if let n = stats.reviewsCount, n > 0 { parts.append("\(n.formatted()) reviews") }
        return parts.isEmpty ? "No ratings yet" : parts.joined(separator: " · ")
    }
}

/// A review-shaped placeholder: the real row, greyed out, so nothing moves when
/// the reviews arrive.
struct FolioMobileReviewSkeleton: View {
    var lineLimit: Int? = 4

    private static let sample = HCReview(
        id: -1, rating: 4, text: String(repeating: "A placeholder line of review text that wraps across the card. ", count: 6),
        spoilers: false, date: "2024-01-01", likes: 12, username: "reader", userImage: nil)

    var body: some View {
        FolioMobileReviewRow(review: Self.sample, lineLimit: lineLimit)
            .redacted(reason: .placeholder)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension HCBookStats {
    /// Stands in for a book's numbers while they load.
    static let placeholder = HCBookStats(rating: 4, ratingsCount: 1_234, reviewsCount: 2)
}

struct FolioMobileReviewRow: View {
    let review: HCReview
    var lineLimit: Int? = 6
    @State private var revealed = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                FolioAuthorPortrait(name: review.username ?? "Reader", url: review.userImage, size: 28)
                Text(review.username.map { "@\($0)" } ?? "A reader")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(FolioTheme.ink)
                Spacer(minLength: 6)
                if let rating = review.rating, rating > 0 { FolioStars(rating: rating, size: 11) }
            }
            ZStack {
                Text(review.text)
                    .font(.system(.callout, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(expanded ? nil : lineLimit)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .blur(radius: review.spoilers && !revealed ? 6 : 0)
                if review.spoilers && !revealed {
                    Button("Show spoilers") { revealed = true }
                        .font(.subheadline)
                        .folioGlassPill()
                }
            }
            .onTapGesture { if !review.spoilers || revealed { expanded.toggle() } }
            HStack(spacing: 12) {
                if let date = review.date { Text(date.folioReadableDate) }
                if review.likes > 0 { Label("\(review.likes)", systemImage: "heart") }
            }
            .font(.caption)
            .foregroundStyle(FolioTheme.muted)
        }
    }
}

struct FolioMobileRatingsView: View {
    let route: FolioMobileRatingsRoute

    @Environment(HardcoverClient.self) private var hardcover
    @State private var stats: HCBookStats?
    @State private var reviews: [HCReview] = []
    @State private var reviewsFailed = false
    @State private var loading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let stats {
                    FolioMobileRatingsSummary(stats: stats)
                        .padding(18)
                        .folioCard(cornerRadius: FolioTheme.panelRadius)
                    if let readers = stats.readersCount, readers > 0 {
                        HStack(spacing: 0) {
                            stat(readers, "readers")
                            if let read = stats.readCount, read > 0 { stat(read, "finished") }
                            if let n = stats.reviewsCount, n > 0 { stat(n, "reviews") }
                        }
                    }
                } else if loading {
                    FolioMobileRatingsSummary(stats: .placeholder, barsLoading: true)
                        .redacted(reason: .placeholder)
                        .padding(18)
                        .folioCard(cornerRadius: FolioTheme.panelRadius)
                        .accessibilityHidden(true)
                }
                if reviews.isEmpty && loading {
                    Text("Reviews")
                        .font(.folioDisplay(.title2))
                        .foregroundStyle(FolioTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(0..<3, id: \.self) { index in
                            if index > 0 { Divider().padding(.vertical, 14) }
                            FolioMobileReviewSkeleton(lineLimit: 10)
                        }
                    }
                    .padding(18)
                    .folioCard(cornerRadius: FolioTheme.panelRadius)
                } else if !reviews.isEmpty {
                    Text("Reviews")
                        .font(.folioDisplay(.title2))
                        .foregroundStyle(FolioTheme.ink)
                        .accessibilityAddTraits(.isHeader)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(reviews.enumerated()), id: \.element.id) { index, review in
                            if index > 0 { Divider().padding(.vertical, 14) }
                            FolioMobileReviewRow(review: review, lineLimit: 10)
                        }
                    }
                    .padding(18)
                    .folioCard(cornerRadius: FolioTheme.panelRadius)
                } else if reviewsFailed {
                    Text("Reviews could not be loaded from Hardcover.")
                        .font(.subheadline).foregroundStyle(FolioTheme.muted)
                } else if !loading {
                    Text("No written reviews yet.")
                        .font(.subheadline).foregroundStyle(FolioTheme.muted)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(route.title)
        .folioScreen()
        .folioPageHeader(route.title)
        .task(id: route.bookID) {
            await HCPriority.$foreground.withValue(true) { await load() }
        }
    }

    /// Opens with what the book page already showed (average, bars, top reviews), then
    /// asks for the numbers, the bars and the full reviews at the same time.
    @MainActor
    private func load() async {
        let snapshot = FolioBookPageCache.load(route.bookID)
        if stats == nil { stats = snapshot?.page.stats }
        if reviews.isEmpty, let saved = snapshot?.reviews { reviews = saved }
        loading = true
        defer { loading = false }
        // The numbers ride along with the bars (one request, shared with the book page).
        async let summary = hardcover.ratingSummary(bookID: route.bookID)
        async let list = try? hardcover.reviews(bookID: route.bookID, limit: 40)
        if let fresh = await summary {
            var merged = stats ?? HCBookStats()
            merged.adopt(fresh)
            stats = merged
        }
        if let fetched = await list {
            reviews = fetched
        } else if reviews.isEmpty {
            reviewsFailed = true
        }
    }

    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value.formatted(.number.notation(.compactName)))
                .font(.system(.title3, design: .serif))
                .foregroundStyle(FolioTheme.ink)
            Text(label).font(.caption).foregroundStyle(FolioTheme.muted)
        }
        .frame(maxWidth: .infinity)
    }
}
