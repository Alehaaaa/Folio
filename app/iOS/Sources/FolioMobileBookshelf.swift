import SwiftUI

/// A wooden bookcase showing books as cloth spines, the centerpiece of Home.
/// Each spine opens the book's details through the parent NavigationStack.
struct FolioMobileBookshelf: View {
    let books: [LocalBook]
    var rows = 2

    @State private var width: CGFloat = 340
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 196

    private let frameInset: CGFloat = 11
    private let spacing: CGFloat = 5

    /// Books that fit on the requested number of shelves at the current width.
    private var shelves: [[LocalBook]] {
        let inner = max(120, width - frameInset * 2 - 28)
        var result: [[LocalBook]] = []
        var current: [LocalBook] = []
        var used: CGFloat = 0
        for book in books {
            let w = FolioMobileSpine.width(for: book) + spacing
            if used + w > inner, !current.isEmpty {
                result.append(current)
                if result.count == rows { return result }
                current = []
                used = 0
            }
            current.append(book)
            used += w
        }
        if !current.isEmpty && result.count < rows { result.append(current) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(shelves.enumerated()), id: \.offset) { index, row in
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(row) { book in
                        NavigationLink(value: book.id) {
                            FolioMobileSpine(book: book, shelfHeight: min(rowHeight, 260))
                        }
                        .buttonStyle(FolioSpineButtonStyle())
                        .accessibilityLabel("\(book.title), \(book.author.isEmpty ? "unknown author" : book.author)")
                        .accessibilityHint("Open book details")
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.top, 22)
                .frame(height: min(rowHeight, 260) + 22, alignment: .bottom)
                .background(shelfBack)
                plank(last: index == shelves.count - 1)
            }
        }
        .padding(.horizontal, frameInset)
        .padding(.top, frameInset)
        .background(
            LinearGradient(colors: [FolioTheme.wood.opacity(0.92), FolioTheme.wood],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookshelf")
    }

    private var shelfBack: some View {
        LinearGradient(colors: [FolioTheme.shelfBack.opacity(0.92), FolioTheme.shelfBack],
                       startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .top) {
                // Soft shadow cast by the shelf above.
                LinearGradient(colors: [.black.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 16)
            }
    }

    private func plank(last: Bool) -> some View {
        LinearGradient(colors: [FolioTheme.wood.opacity(0.85), FolioTheme.wood, FolioTheme.wood.opacity(0.9)],
                       startPoint: .top, endPoint: .bottom)
            .frame(height: last ? 16 : 13)
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.18)).frame(height: 1)
            }
    }
}

/// One cloth-bound spine: vertical serif title, the author beside it, gilt
/// rules and a small mark for finished or in-progress books.
struct FolioMobileSpine: View {
    let book: LocalBook
    let shelfHeight: CGFloat

    static func width(for book: LocalBook) -> CGFloat {
        40 + CGFloat(stableHash(book.title) % 14)
    }

    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 1469598103934665603
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return hash
    }

    private var width: CGFloat { Self.width(for: book) }
    private var height: CGFloat {
        shelfHeight * (0.80 + CGFloat(Self.stableHash(book.author + book.title) % 18) / 100)
    }

    private var mark: String {
        switch book.status {
        case .finished: "checkmark"
        case .reading: "bookmark"
        default: "leaf"
        }
    }

    var body: some View {
        let cloth = FolioTheme.spine(for: book.title)
        ZStack {
            cloth
            LinearGradient(colors: [.white.opacity(0.14), .clear, .black.opacity(0.18)],
                           startPoint: .leading, endPoint: .trailing)
            VStack(spacing: 0) {
                Rectangle().fill(gilt.opacity(0.55)).frame(height: 0.8).padding(.top, 10)
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    Text(book.title)
                        .font(.system(size: 14, weight: .regular, design: .serif))
                        .lineLimit(2)
                        .minimumScaleFactor(0.65)
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.system(size: 8.5, weight: .regular, design: .serif))
                            .lineLimit(1)
                            .opacity(0.75)
                    }
                }
                .frame(width: height - 52, height: width - 8)
                .rotationEffect(.degrees(-90))
                .frame(width: width - 8, height: height - 52)
                Spacer(minLength: 6)
                Image(systemName: mark)
                    .font(.system(size: 10, weight: .regular))
                    .opacity(0.8)
                    .padding(.bottom, 10)
            }
            .foregroundStyle(gilt)
        }
        .frame(width: width, height: height)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 1,
                                          bottomTrailingRadius: 1, topTrailingRadius: 3))
        .overlay {
            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 1,
                                   bottomTrailingRadius: 1, topTrailingRadius: 3)
                .stroke(.black.opacity(0.14), lineWidth: 0.6)
        }
        .shadow(color: .black.opacity(0.16), radius: 2, x: 1, y: 1)
    }

    private var gilt: Color { Color(hex: "#F1E8D2") }
}

/// Spines lift slightly when pressed, like pulling a book off the shelf.
struct FolioSpineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? -8 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
