import SwiftUI

/// A wooden bookcase, the centerpiece of Home. Books keep their places like
/// in a real library: new books go at the end, a long press and drag moves
/// one, and a new shelf opens when one fills up, up to the chosen number.
struct FolioMobileBookshelf: View {
    /// The nook's books, already in their places.
    let items: [FolioNookItem]

    @State private var nook = FolioNookStore.shared
    @State private var width: CGFloat = 340
    @State private var target: String?
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 186

    private let frameInset: CGFloat = 11
    private let spacing: CGFloat = 4
    private let sidePadding: CGFloat = 14

    private var shelfHeight: CGFloat { min(rowHeight, 250) }
    private var innerWidth: CGFloat { max(120, width - frameInset * 2 - sidePadding * 2) }

    var body: some View {
        let widths = Dictionary(items.map { ($0.id, FolioSpineMetrics.width(for: $0)) },
                                uniquingKeysWith: { a, _ in a })
        let shelves = layout(widths: widths)
        VStack(spacing: 0) {
            ForEach(Array(shelves.enumerated()), id: \.offset) { index, row in
                let last = index == shelves.count - 1
                let used = row.reduce(CGFloat(0)) { $0 + (widths[$1.id] ?? 40) + spacing }
                let leans = self.leans(row, free: innerWidth - used, keepBookend: last)
                let leanRoom = leans.values.reduce(CGFloat(0)) { $0 + $1.before + $1.after }
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(row) { item in
                        let lean = leans[item.id] ?? FolioSpineLean()
                        spine(item)
                            .rotationEffect(.degrees(lean.angle), anchor: lean.angle < 0 ? .bottomLeading : .bottomTrailing)
                            .padding(.leading, lean.before)
                            .padding(.trailing, lean.after)
                            .zIndex(lean.angle == 0 ? 0 : 1)
                    }
                    if last && innerWidth - used - leanRoom >= 30,
                       leans[row.last?.id ?? ""] == nil {
                        FolioBookend(height: shelfHeight * 0.36)
                            .padding(.leading, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, sidePadding)
                .padding(.top, 24)
                .frame(height: shelfHeight + 24, alignment: .bottom)
                .background(shelfBack)
                .contentShape(Rectangle())
                .dropDestination(for: String.self) { keys, _ in
                    guard let key = keys.first, let end = row.last, key != end.id else { return false }
                    withAnimation(.snappy) { nook.move(key, after: end.id) }
                    return true
                }
                plank(last: last)
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
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: items.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookshelf")
    }

    // MARK: Layout

    /// Fills shelves left to right in the books' places. When there are more
    /// books than room, books being read keep their spot first, then the
    /// earliest places, so the shelf never shuffles.
    private func layout(widths: [String: CGFloat]) -> [[FolioNookItem]] {
        let maxRows = max(1, nook.maxShelves)
        let all = pack(items, widths)
        if all.count <= maxRows { return all.isEmpty ? [[]] : all }

        var chosen = Set<String>()
        let reading = items.filter(\.reading)
        for item in reading {
            chosen.insert(item.id)
            if pack(items.filter { chosen.contains($0.id) }, widths).count > maxRows { chosen.remove(item.id) }
        }
        for item in items where !item.reading {
            chosen.insert(item.id)
            if pack(items.filter { chosen.contains($0.id) }, widths).count > maxRows {
                chosen.remove(item.id)
                break
            }
        }
        return pack(items.filter { chosen.contains($0.id) }, widths)
    }

    /// Which books lean, and by how much. A book only tips into space the
    /// shelf has free, resting its side on the top corner of its neighbor:
    /// the last book of a shelf leans back on the one before it, a shorter
    /// book now and then leans on a taller neighbor, and the first book may
    /// lean the other way. Everything follows from the order, so moving a
    /// book changes who leans, with an animation.
    private func leans(_ row: [FolioNookItem], free: CGFloat, keepBookend: Bool) -> [String: FolioSpineLean] {
        guard row.count >= 2 else { return [:] }
        var free = free - (keepBookend ? 32 : 0)
        var result: [String: FolioSpineLean] = [:]
        let heights = row.map { shelfHeight * FolioSpineMetrics.heightFactor(for: $0) }

        func gap(_ degrees: Double, leaner: CGFloat, neighbor: CGFloat) -> CGFloat {
            min(neighbor, leaner * CGFloat(cos(degrees * .pi / 180))) * CGFloat(tan(degrees * .pi / 180)) + 1
        }

        func tilt(_ i: Int, toward j: Int, base: Double) -> Bool {
            let leaner = heights[i], neighbor = heights[j]
            // Shorter books tip further before they meet their neighbor.
            let difference = Double((neighbor - leaner) / leaner)
            let degrees = min(16, max(4, base + difference * 28))
            let needed = gap(degrees, leaner: leaner, neighbor: neighbor)
            guard needed <= free else { return false }
            free -= needed
            result[row[i].id] = j < i
                ? FolioSpineLean(angle: -degrees, before: needed)
                : FolioSpineLean(angle: degrees, after: needed)
            return true
        }

        // The last book on a shelf with room to spare.
        let lastIndex = row.count - 1
        if !keepBookend || free > 60 {
            _ = tilt(lastIndex, toward: lastIndex - 1, base: 7 + Double(FolioSpineMetrics.hash(row[lastIndex].id) % 5))
        }
        // A shorter book between taller ones, now and then.
        for i in 1..<lastIndex where result[row[i].id] == nil && result[row[i - 1].id] == nil {
            let shorter = heights[i] < heights[i - 1] * 0.9
            if shorter && FolioSpineMetrics.hash(row[i].id + "lean") % 3 == 0 {
                _ = tilt(i, toward: i - 1, base: 3)
            }
        }
        // The first book leaning to the right on a taller neighbor.
        if result[row[0].id] == nil, result[row[1].id] == nil, heights[0] < heights[1] * 0.92,
           FolioSpineMetrics.hash(row[0].id + "lean") % 2 == 0 {
            _ = tilt(0, toward: 1, base: 4)
        }
        return result
    }

    private func pack(_ list: [FolioNookItem], _ widths: [String: CGFloat]) -> [[FolioNookItem]] {
        var rows: [[FolioNookItem]] = []
        var current: [FolioNookItem] = []
        var used: CGFloat = 0
        for item in list {
            let w = (widths[item.id] ?? 40) + spacing
            if used + w > innerWidth, !current.isEmpty {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(item)
            used += w
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    // MARK: Spines

    @ViewBuilder
    private func link(_ item: FolioNookItem) -> some View {
        switch item.source {
        case .library(let id):
            NavigationLink(value: id) { FolioMobileSpine(item: item, shelfHeight: shelfHeight) }
        case .remote(let book):
            NavigationLink(value: book) { FolioMobileSpine(item: item, shelfHeight: shelfHeight) }
        }
    }

    private func spine(_ item: FolioNookItem) -> some View {
        link(item)
            .buttonStyle(FolioSpineButtonStyle())
            .folioNookMenu(item)
            .draggable(item.id) {
                FolioMobileSpine(item: item, shelfHeight: shelfHeight)
            }
            .dropDestination(for: String.self) { keys, _ in
                guard let key = keys.first, key != item.id else { return false }
                withAnimation(.snappy) { nook.move(key, onto: item.id, visible: items) }
                target = nil
                return true
            } isTargeted: { over in
                withAnimation(.snappy(duration: 0.2)) {
                    if over { target = item.id } else if target == item.id { target = nil }
                }
            }
            // Books lean apart where a dragged book would go.
            .offset(x: target == item.id ? 8 : 0)
            .accessibilityLabel(accessibilityLabel(item))
            .accessibilityHint("Opens book details. Long press for more.")
            .accessibilityAction(named: "Move left") { shift(item, by: -1) }
            .accessibilityAction(named: "Move right") { shift(item, by: 1) }
            .accessibilityAction(named: "Hide from nook") { withAnimation(.snappy) { nook.hide(item) } }
    }

    private func shift(_ item: FolioNookItem, by step: Int) {
        guard let i = items.firstIndex(where: { $0.id == item.id }),
              items.indices.contains(i + step) else { return }
        withAnimation(.snappy) { nook.move(item.id, onto: items[i + step].id, visible: items) }
    }

    private func accessibilityLabel(_ item: FolioNookItem) -> String {
        var text = item.title
        if !item.author.isEmpty { text += ", " + item.author }
        if let progress = item.progressDetail { text += ", " + progress }
        return text
    }

    // MARK: Wood

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

/// One spine, colored from the book's cover. Its width follows the page
/// count, its height and binding vary from book to book, and a ribbon and
/// the last progress mark a book being read.
struct FolioMobileSpine: View {
    let item: FolioNookItem
    let shelfHeight: CGFloat

    private var binding: FolioSpineBinding { FolioSpineMetrics.binding(for: item) }
    private var width: CGFloat { FolioSpineMetrics.width(for: item) }
    private var height: CGFloat { shelfHeight * FolioSpineMetrics.heightFactor(for: item) }

    private static let gilt = Color(hex: "#DCC07A")
    private static let ribbon = Color(hex: "#9E3A2F")

    var body: some View {
        let palette = FolioSpinePalettes.shared.palette(for: item)
        let art = FolioSpinePalettes.shared.strip(for: item)
        let ink = art == nil && binding == .leather ? Self.gilt : palette.textColor
        let shape = UnevenRoundedRectangle(topLeadingRadius: binding == .paperback ? 1.5 : 3, bottomLeadingRadius: 1,
                                           bottomTrailingRadius: 1, topTrailingRadius: binding == .paperback ? 1.5 : 3)
        ZStack {
            palette.baseColor
            if let art {
                // The cover's own left edge wraps onto the spine, toned a little
                // toward its main color so the title stays readable.
                Image(uiImage: art)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
                palette.baseColor.opacity(0.38)
            } else if binding == .leather {
                Color.black.opacity(0.28)
            }
            content(palette: palette, ink: ink, art: art != nil)
            // Light catches the rounded spine on the left and falls off to the right.
            LinearGradient(stops: [
                .init(color: .white.opacity(0.18), location: 0),
                .init(color: .white.opacity(0.05), location: 0.22),
                .init(color: .clear, location: 0.5),
                .init(color: .black.opacity(0.10), location: 0.8),
                .init(color: .black.opacity(0.24), location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            .allowsHitTesting(false)
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay { shape.stroke(.black.opacity(0.16), lineWidth: 0.6) }
        .overlay(alignment: .topTrailing) {
            if item.reading {
                FolioRibbon()
                    .fill(Self.ribbon)
                    .frame(width: 5, height: 15)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, x: 0.5, y: 0.5)
                    .offset(x: -max(5, width * 0.18), y: -10)
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 2, x: 1, y: 1)
        .contentShape(Rectangle())
    }

    // MARK: Parts

    private var top: CGFloat {
        switch binding {
        case .cloth: 18
        case .paperback: max(16, height * 0.13) + 6
        case .leather: 24
        case .jacket: 30
        }
    }

    private var bottom: CGFloat {
        item.progressLabel != nil ? 26 : (binding == .leather ? 26 : 22)
    }

    @ViewBuilder
    private func content(palette: FolioSpinePalette, ink: Color, art: Bool) -> some View {
        VStack(spacing: 0) {
            Group {
                if art {
                    Color.clear
                } else {
                    header(palette: palette, ink: ink)
                }
            }
            .frame(height: top, alignment: .top)
            title(ink: ink)
            Group {
                if art && item.progressLabel == nil {
                    Color.clear
                } else {
                    footer(palette: palette, ink: ink)
                }
            }
            .frame(height: bottom, alignment: .bottom)
        }
        .foregroundStyle(ink)
        .shadow(color: art ? (palette.lightText ? Color.black : Color.white).opacity(0.45) : .clear, radius: 1.2)
    }

    @ViewBuilder
    private func header(palette: FolioSpinePalette, ink: Color) -> some View {
        switch binding {
        case .cloth:
            VStack(spacing: 2) {
                rule(ink)
                rule(ink)
            }
            .padding(.top, 9)
        case .paperback:
            palette.accentColor
                .frame(height: max(16, height * 0.13))
                .overlay(alignment: .bottom) { Rectangle().fill(.black.opacity(0.12)).frame(height: 0.6) }
        case .leather:
            VStack(spacing: 5) {
                band
                band
            }
            .padding(.top, 8)
        case .jacket:
            palette.accentColor
                .frame(height: 9)
                .padding(.top, 14)
        }
    }

    @ViewBuilder
    private func footer(palette: FolioSpinePalette, ink: Color) -> some View {
        VStack(spacing: 4) {
            if let label = item.progressLabel {
                Text(label)
                    .font(.system(size: width < 32 ? 7 : 8, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 2)
            } else {
                switch binding {
                case .cloth:
                    Image(systemName: "leaf")
                        .font(.system(size: 8))
                        .opacity(0.75)
                case .paperback:
                    Circle()
                        .fill(palette.accentColor)
                        .overlay { Circle().stroke(ink.opacity(0.35), lineWidth: 0.6) }
                        .frame(width: 9, height: 9)
                case .leather:
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 5))
                        .opacity(0.8)
                case .jacket:
                    palette.accentColor.frame(height: 5)
                }
            }
            switch binding {
            case .cloth: rule(ink).padding(.bottom, 8)
            case .leather: band.padding(.bottom, 8)
            case .paperback, .jacket: Color.clear.frame(height: 6)
            }
        }
    }

    /// The title and author run up the spine, as on English-language books
    /// shelved in Europe. Thin spines show only the surname.
    private func title(ink: Color) -> some View {
        let length = max(30, height - top - bottom)
        let thickness = max(14, width - 8)
        let size = min(16, max(10, width * 0.34))
        return HStack(spacing: 6) {
            Text(binding == .paperback ? item.title.uppercased() : item.title)
                .font(titleFont(size))
                .tracking(binding == .paperback ? 0.4 : 0)
                .lineLimit(width >= 52 ? 2 : 1)
                .minimumScaleFactor(0.55)
            if width >= 33, !item.author.isEmpty {
                Spacer(minLength: 2)
                Text(byline)
                    .font(authorFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(0.78)
                    .layoutPriority(-1)
            }
        }
        .frame(width: length, height: thickness)
        .rotationEffect(.degrees(-90))
        .frame(width: thickness, height: length)
    }

    private var byline: String {
        let name = item.author.split(separator: ",").first.map(String.init) ?? item.author
        let text = width < 46 ? (name.split(separator: " ").last.map(String.init) ?? name) : name
        return binding == .paperback || binding == .jacket ? text.uppercased() : text
    }

    private func titleFont(_ size: CGFloat) -> Font {
        switch binding {
        case .cloth: .system(size: size, weight: .regular, design: .serif)
        case .paperback: .system(size: size * 0.92, weight: .heavy).width(.condensed)
        case .leather: .system(size: size * 0.95, weight: .semibold, design: .serif).smallCaps()
        case .jacket: .system(size: size, weight: .medium, design: .serif).italic()
        }
    }

    private var authorFont: Font {
        switch binding {
        case .cloth, .leather: .system(size: 8.5, weight: .regular, design: .serif)
        case .paperback: .system(size: 7.5, weight: .semibold).width(.condensed)
        case .jacket: .system(size: 7.5, weight: .medium)
        }
    }

    private func rule(_ ink: Color) -> some View {
        Rectangle().fill(ink.opacity(0.55)).frame(height: 0.8)
    }

    /// A raised band across a leather spine.
    private var band: some View {
        LinearGradient(colors: [.white.opacity(0.22), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            .frame(height: 3)
            .overlay { Self.gilt.opacity(0.35).frame(height: 0.6) }
    }
}

/// A ribbon marker peeking out of the top of a book, notched at the end.
struct FolioRibbon: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY + rect.width * 0.8))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// A small metal bookend holding up the last book on the shelf.
struct FolioBookend: View {
    let height: CGFloat
    private let metal = Color(hex: "#3D463B")

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 0,
                                   bottomTrailingRadius: 0, topTrailingRadius: 6)
                .fill(LinearGradient(colors: [metal.opacity(0.85), metal], startPoint: .leading, endPoint: .trailing))
                .frame(width: 7, height: height)
            RoundedRectangle(cornerRadius: 1)
                .fill(metal)
                .frame(width: 24, height: 3)
        }
        .frame(width: 24, height: height, alignment: .bottomLeading)
        .shadow(color: .black.opacity(0.18), radius: 1.5, x: 1, y: 1)
        .accessibilityHidden(true)
    }
}

/// Spines lift slightly when pressed, like pulling a book off the shelf.
struct FolioSpineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? -8 : 0)
            .animation(.spring(response: 0.28, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// How a book stands: tipped by an angle, with the room it tips into.
struct FolioSpineLean {
    var angle: Double = 0
    var before: CGFloat = 0
    var after: CGFloat = 0
}
