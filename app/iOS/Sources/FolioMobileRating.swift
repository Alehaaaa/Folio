import SwiftUI

/// Your own star ratings, kept to the quarter star on this device. Services
/// get the closest value they accept: Hardcover takes half stars, Goodreads
/// quarters (whole stars on older accounts), and the exact value stays here.
@MainActor
@Observable
final class FolioMyRatings {
    static let shared = FolioMyRatings()
    private static let key = "folio.myRatings"

    private(set) var values: [String: Double]

    private init() {
        values = (UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Double]) ?? [:]
    }

    static func key(for book: HCBook) -> String {
        book.id > 0 ? "hc-\(book.id)" : "t-" + BookMatch.key(author: book.authors, title: book.title)
    }

    private static func keys(for book: HCBook) -> [String] {
        var out = ["t-" + BookMatch.key(author: book.authors, title: book.title)]
        if book.id > 0 { out.insert("hc-\(book.id)", at: 0) }
        return out
    }

    /// The exact rating, unless Hardcover has since moved to a value this one
    /// doesn't round to (rated again on the website, say): then Hardcover's.
    func rating(for book: HCBook, hardcover: Double?) -> Double? {
        let mine = Self.keys(for: book).lazy.compactMap { self.values[$0] }.first
        let theirs = hardcover.flatMap { $0 > 0 ? $0 : nil }
        guard let mine else { return theirs }
        guard let theirs else { return mine }
        return Self.half(mine) == Self.half(theirs) ? mine : theirs
    }

    func set(_ rating: Double?, for book: HCBook) {
        for k in Self.keys(for: book) { values[k] = nil }
        if let rating { values[Self.key(for: book)] = Self.quarter(rating) }
        UserDefaults.standard.set(values, forKey: Self.key)
    }

    nonisolated static func quarter(_ v: Double) -> Double { min(5, max(0.25, (v * 4).rounded() / 4)) }
    /// Hardcover's half stars: 4.25 → 4.5, 4.75 → 5, never below half a star.
    nonisolated static func half(_ v: Double) -> Double { min(5, max(0.5, (v * 2).rounded() / 2)) }
    /// Whole stars for services without fractions; 4.5 rounds up, as Goodreads did.
    nonisolated static func whole(_ v: Double) -> Int { min(5, max(1, Int(v.rounded()))) }

    nonisolated static func label(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(v == v.rounded() ? 0 : v * 2 == (v * 2).rounded() ? 1 : 2)))
    }
}

/// One star, filled to a fraction from the leading edge.
struct FolioPartialStar: View {
    let fill: Double
    var size: CGFloat

    var body: some View {
        Image(systemName: "star")
            .font(.system(size: size))
            .overlay {
                GeometryReader { proxy in
                    Image(systemName: "star.fill")
                        .font(.system(size: size))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: proxy.size.width * min(1, max(0, fill)))
                        }
                }
            }
    }
}

/// Your rating: tap a star for whole stars, or press and slide along the row
/// to fine-tune by quarters, with a tick at each step. Tapping the rating you
/// already have clears it.
struct FolioRatingControl: View {
    let rating: Double?
    var size: CGFloat = 22
    let onChange: (Double?) -> Void

    @State private var draft: Double?
    @State private var dragging = false
    @State private var startValue: Double?
    @State private var width: CGFloat = 1

    private var spacing: CGFloat { size * 0.3 }
    private var shown: Double { draft ?? rating ?? 0 }

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(1...5, id: \.self) { n in
                FolioPartialStar(fill: shown - Double(n - 1), size: size)
            }
        }
        .foregroundStyle(FolioTheme.caution)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = max(1, $0) }
        .overlay(alignment: .top) {
            if dragging, let draft {
                Text(FolioMyRatings.label(draft))
                    .font(.caption.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(FolioTheme.ink)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: -size * 1.1)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.15), value: dragging)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if startValue == nil { startValue = rating ?? 0 }
                    let moved = abs(g.translation.width) > 4 || dragging
                    if moved && !dragging { dragging = true }
                    draft = value(at: g.location.x, fine: moved)
                }
                .onEnded { g in
                    let final = value(at: g.location.x, fine: dragging)
                    // A tap on the rating you already have clears it.
                    let cleared = !dragging && final == startValue && startValue != 0
                    dragging = false
                    draft = nil
                    startValue = nil
                    let next: Double? = cleared ? nil : final
                    if next != rating { onChange(next) }
                }
        )
        .sensoryFeedback(.selection, trigger: draft) { old, new in old != nil && new != nil && old != new }
        .sensoryFeedback(.impact(weight: .light), trigger: dragging) { _, new in new }
        .accessibilityElement()
        .accessibilityLabel("Your rating")
        .accessibilityValue(rating.map { "\(FolioMyRatings.label($0)) of 5 stars" } ?? "Not rated")
        .accessibilityAdjustableAction { direction in
            let now = rating ?? 0
            switch direction {
            case .increment: onChange(min(5, now + 0.25))
            case .decrement: onChange(now <= 0.25 ? nil : now - 0.25)
            @unknown default: break
            }
        }
    }

    /// Whole stars on a tap; quarters while sliding.
    private func value(at x: CGFloat, fine: Bool) -> Double {
        let pitch = (width + spacing) / 5
        let raw = Double(max(0, x) / pitch)
        guard fine else { return Double(min(5, max(1, Int(raw.rounded(.down)) + 1))) }
        return FolioMyRatings.quarter(raw)
    }
}
