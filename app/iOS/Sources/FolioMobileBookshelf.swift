import SwiftUI
import UniformTypeIdentifiers
import os

/// Drag diagnostics: `log stream --level debug --predicate 'category == "nookdrag"'`.
let folioDragLog = Logger(subsystem: "app.folio.reader", category: "nookdrag")

/// A wooden bookcase, the centerpiece of Home. Books keep their places like
/// in a real library: new books go at the end, a long press and drag moves
/// one, and a new shelf opens when one fills up, up to the chosen number.
struct FolioMobileBookshelf: View {
    /// The nook's books, already in their places.
    let items: [FolioNookItem]

    @State private var nook = FolioNookStore.shared
    @State private var width: CGFloat = 340
    /// Books are placed only once the bookcase knows its real width. Packing
    /// first into a guessed width put the last book of a shelf on the next
    /// one, and it slid back up every time Home opened.
    @State private var measured = false
    /// The book being dragged. It leaves its place while it is in the hand,
    /// and the shelf makes room for it wherever it hovers.
    @State private var dragging: String?
    /// Where the dragged book would land. While a book is in the hand the
    /// shelf only slides books aside to open a gap there; nothing re-packs or
    /// re-tilts until it's let go, so the books stay calm.
    @State private var dropSpot: FolioNookDropSpot?
    /// The book just let go. It shows up exactly where the drag preview was
    /// released, upright, and springs into its gap and its lean in one motion.
    @State private var landing: FolioNookLanding?
    /// Where the pointer held the book, so the landing starts under it.
    @State private var grip = FolioNookGrip()
    /// The lean the book had when it was lifted: the drag preview keeps it,
    /// so picking a book up doesn't snap it straight.
    @State private var liftAngle: Double = 0
    /// The book whose drag the system is preparing. The system asks for a
    /// drag's data at odd moments (on touch-down, even after a drop), so a
    /// book only counts as lifted once that drag actually reaches the shelf.
    @State private var pending = FolioNookPending()
    @Namespace private var shelfSpace
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 186

    private let frameInset: CGFloat = 11
    private let spacing: CGFloat = 4
    private let sidePadding: CGFloat = 14

    private var shelfHeight: CGFloat { min(rowHeight, 250) }
    private var innerWidth: CGFloat { max(120, width - frameInset * 2 - sidePadding * 2) }

    var body: some View {
        let widths = Dictionary(items.map { ($0.id, FolioSpineMetrics.width(for: $0)) },
                                uniquingKeysWith: { a, _ in a })
        // The live order from the nook store, so a drop shows in the same
        // frame as the move instead of a frame later, when Home re-renders.
        let ordered = nook.arranged(items)
        let shelves = layout(widths: widths, items: ordered)
        let flat = shelves.flatMap { $0 }
        let slides = self.slides(shelves, widths: widths)
        let rowLeans = shelves.enumerated().map { index, row in
            leans(row, free: innerWidth - used(row, widths), keepBookend: index == shelves.count - 1)
        }
        VStack(spacing: 0) {
            ForEach(Array(shelves.enumerated()), id: \.offset) { index, row in
                let last = index == shelves.count - 1
                let used = self.used(row, widths)
                let leans = rowLeans[index]
                let leanRoom = leans.values.reduce(CGFloat(0)) { $0 + $1.before + $1.after }
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(measured ? row : []) { item in
                        let lean = leans[item.id] ?? FolioSpineLean()
                        let landed = landing?.id == item.id ? landing : nil
                        spine(item, lean: lean.angle)
                            .modifier(FolioSpinePose(
                                id: item.id,
                                x: (slides[item.id] ?? 0) + (landed?.offset.width ?? 0),
                                y: landed?.offset.height ?? 0,
                                angle: lean.angle + (landed?.extraAngle ?? 0),
                                anchor: lean.anchor
                            ))
                            .matchedGeometryEffect(id: item.id, in: shelfSpace)
                            .padding(.leading, lean.before)
                            .padding(.trailing, lean.after)
                            .zIndex(landed != nil ? 2 : abs(lean.angle) > 3 ? 1 : 0)
                            .transaction { t in
                                // The landing book is placed under the pointer at once;
                                // only its own spring then carries it home.
                                if landed?.placing == true { t.animation = nil; t.disablesAnimations = true }
                            }
                    }
                    if last && innerWidth - used - leanRoom >= 30,
                       abs(leans[row.last?.id ?? ""]?.angle ?? 0) < 3 {
                        FolioBookend(height: shelfHeight * 0.36)
                            .padding(.leading, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, sidePadding)
                .padding(.top, 24)
                .frame(height: shelfHeight + 24, alignment: .bottom)
                // Books stepping aside for a gap slide behind the frame, not over it.
                .clipped()
                .background(shelfBack)
                plank(last: last)
            }
        }
        .padding(.horizontal, frameInset)
        .padding(.top, frameInset)
        // One drop target for the whole bookcase: the spot comes from where
        // the pointer is over the shelves as they'd stand without the lifted
        // book, so opening the gap can never move the spot.
        .contentShape(Rectangle())
        .onDrop(of: [.plainText], delegate: FolioNookDropDelegate(
            hovered: { location in hover(location, shelves: shelves, widths: widths, leans: rowLeans) },
            dropped: { location in drop(at: location) },
            // Off the bookcase the gap closes; the book still waits in the hand.
            left: { if dropSpot != nil { withAnimation(Self.slide) { dropSpot = nil } } }
        ))
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            guard newWidth != width || !measured else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                width = newWidth
                measured = true
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: ordered.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookshelf")
    }

    // MARK: Layout

    /// Fills shelves left to right in the books' places. When there are more
    /// books than room, books being read keep their spot first, then the
    /// earliest places, so the shelf never shuffles.
    private func layout(widths: [String: CGFloat], items: [FolioNookItem]? = nil) -> [[FolioNookItem]] {
        let items = items ?? nook.arranged(self.items)
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
        var result: [String: FolioSpineLean] = [:]
        // Books something rests on stand straight, so the contact holds.
        var supports = Set<Int>()
        if row.count >= 2 {
            var free = free - (keepBookend ? 32 : 0)
            let heights = row.map { shelfHeight * FolioSpineMetrics.heightFactor(for: $0) }

            /// How far the leaning book's side travels before it meets the
            /// neighbor: the neighbor's top corner when it is the shorter one,
            /// otherwise the leaning book's own top corner.
            func reach(_ degrees: Double, leaner: CGFloat, neighbor: CGFloat) -> CGFloat {
                let radians = degrees * .pi / 180
                return min(neighbor * CGFloat(tan(radians)), leaner * CGFloat(sin(radians)))
            }

            func tilt(_ i: Int, toward j: Int, base: Double) {
                guard result[row[i].id] == nil, !supports.contains(i), result[row[j].id] == nil else { return }
                let leaner = heights[i], neighbor = heights[j]
                // Shorter books tip further before they meet their neighbor.
                let difference = Double((neighbor - leaner) / leaner)
                let degrees = min(16, max(4, base + difference * 28))
                // The stack already spaces books apart; only the rest is extra room.
                let extra = reach(degrees, leaner: leaner, neighbor: neighbor) - spacing
                guard extra <= free else { return }
                free -= max(0, extra)
                supports.insert(j)
                result[row[i].id] = j < i
                    ? FolioSpineLean(angle: -degrees, before: extra, anchor: .bottomLeading)
                    : FolioSpineLean(angle: degrees, after: extra, anchor: .bottomTrailing)
            }

            // The last book on a shelf with room to spare.
            let lastIndex = row.count - 1
            if !keepBookend || free > 60 {
                tilt(lastIndex, toward: lastIndex - 1, base: 7 + Double(FolioSpineMetrics.hash(row[lastIndex].id) % 5))
            }
            // A shorter book leaning on a taller one, now and then.
            for i in stride(from: lastIndex - 1, through: 1, by: -1)
            where heights[i] < heights[i - 1] * 0.95 && FolioSpineMetrics.hash(row[i].id + "lean") % 2 == 0 {
                tilt(i, toward: i - 1, base: 3)
            }
            // The first book leaning to the right on a taller neighbor.
            if heights[0] < heights[1] * 0.92, FolioSpineMetrics.hash(row[0].id + "lean") % 2 == 0 {
                tilt(0, toward: 1, base: 4)
            }
        }
        // Everyone else stands a touch off true, in their own way.
        for (i, item) in row.enumerated() where result[item.id] == nil {
            result[item.id] = FolioSpineLean(angle: supports.contains(i) ? 0 : Self.wobble(item), anchor: .bottom)
        }
        return result
    }

    private var leanReserve: CGFloat { min(34, innerWidth * 0.09) }

    /// A slight, permanent tilt that belongs to the book itself, so it
    /// survives any reorder: most books stand a touch off true.
    static func wobble(_ item: FolioNookItem) -> Double {
        let h = FolioSpineMetrics.hash(item.id + "wobble")
        guard h % 5 != 0 else { return 0 }
        let size = 0.4 + Double(h >> 8 % 9) / 10
        return h & 2 == 0 ? size : -size
    }

    private func pack(_ list: [FolioNookItem], _ widths: [String: CGFloat]) -> [[FolioNookItem]] {
        var rows: [[FolioNookItem]] = []
        var current: [FolioNookItem] = []
        var used: CGFloat = 0
        for item in list {
            let w = (widths[item.id] ?? 40) + spacing
            // Each shelf keeps a little room spare so some books can lean.
            if used + w > innerWidth - leanReserve, !current.isEmpty {
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

    private func spine(_ item: FolioNookItem, lean: Double) -> some View {
        link(item)
            .buttonStyle(FolioSpineButtonStyle())
            .folioNookMenu(item)
            #if os(macOS)
            .onContinuousHover { phase in
                if case .active(let point) = phase { grip.hold(item.id, at: point) }
            }
            #endif
            // Only the book in the hand is seen; the shelf closes up behind it.
            .opacity(dragging == item.id && FolioNookDragEnd.tracked ? 0 : 1)
            .onChange(of: dragging == item.id) { _, hidden in
                folioDragLog.debug("visible \(item.title, privacy: .public) hidden=\(hidden && FolioNookDragEnd.tracked)")
            }
            .onDrag {
                pending.prepare(item.id, lean: lean)
                return NSItemProvider(object: item.id as NSString)
            } preview: {
                // Lifted as it stood, lean and all, with room for the tilt and shadow.
                FolioMobileSpine(item: item, shelfHeight: shelfHeight)
                    .rotationEffect(.degrees(lean), anchor: .center)
                    .shadow(color: .black.opacity(0.28), radius: 14, y: 10)
                    .padding(24)
            }
            .modifier(FolioNookDragEnd {
                // A drop on the shelf may be reported after the drag ends, so
                // only a drag that went nowhere brings the book back.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    if landing?.id != item.id { endDrag() }
                }
            })
            .accessibilityLabel(accessibilityLabel(item))
            .accessibilityHint("Opens book details. Long press for more.")
            .accessibilityAction(named: "Move left") { shift(item, by: -1) }
            .accessibilityAction(named: "Move right") { shift(item, by: 1) }
            .accessibilityAction(named: "Hide from nook") { withAnimation(.snappy) { nook.hide(item) } }
    }

    private func startDrag(_ id: String) {
        folioDragLog.debug("lift \(id, privacy: .public)")
        liftAngle = pending.lean
        dropSpot = nil
        withAnimation(.easeOut(duration: 0.12)) { dragging = id }
    }

    private func setSpot(_ spot: FolioNookDropSpot) {
        guard spot != dropSpot else { return }
        folioDragLog.debug("spot shelf=\(spot.shelf) position=\(spot.position)")
        withAnimation(Self.slide) { dropSpot = spot }
    }

    private static let slide = Animation.spring(response: 0.3, dampingFraction: 0.86)

    /// How far each book slides while one is in the hand: books after the
    /// lifted one on its shelf close up, and books from the spot on, on the
    /// spot's shelf, step aside by the lifted book's width.
    private func slides(_ shelves: [[FolioNookItem]], widths: [String: CGFloat]) -> [String: CGFloat] {
        guard let key = dragging, let spot = dropSpot else { return [:] }
        let flat = shelves.flatMap { $0 }
        guard let from = flat.firstIndex(where: { $0.id == key }) else { return [:] }
        let fromShelf = shelves.firstIndex { $0.contains { $0.id == key } }
        let gap = (widths[key] ?? 40) + spacing
        var result: [String: CGFloat] = [:]
        var position = 0
        for (shelf, row) in shelves.enumerated() {
            for item in row {
                defer { position += 1 }
                guard item.id != key else { continue }
                var x: CGFloat = 0
                if FolioNookDragEnd.tracked, shelf == fromShelf, position > from { x -= gap }
                if shelf == spot.shelf, position >= spot.position { x += gap }
                if x != 0 { result[item.id] = x }
            }
        }
        return result
    }

    private func used(_ row: [FolioNookItem], _ widths: [String: CGFloat]) -> CGFloat {
        row.reduce(CGFloat(0)) { $0 + (widths[$1.id] ?? 40) + spacing }
    }

    private var plankHeight: CGFloat { 13 }
    private func shelfTop(_ shelf: Int) -> CGFloat { frameInset + CGFloat(shelf) * (shelfHeight + 24 + plankHeight) }

    /// Picks the gap from the pointer: the shelf under it, and how many of
    /// that shelf's other books stand left of it.
    private func hover(_ location: CGPoint, shelves: [[FolioNookItem]], widths: [String: CGFloat],
                       leans: [[String: FolioSpineLean]]) {
        // The drag is real once it moves over the shelf: now the book leaves its place.
        if dragging == nil, let id = pending.take() { startDrag(id) }
        guard let key = dragging, !shelves.isEmpty else { return }
        let shelf = min(shelves.count - 1, max(0, Int((location.y - frameInset) / (shelfHeight + 24 + plankHeight))))
        let flat = shelves.flatMap { $0 }
        var x = frameInset + sidePadding
        var position: Int?
        for item in shelves[shelf] where item.id != key {
            let lean = leans[shelf][item.id] ?? FolioSpineLean()
            let w = widths[item.id] ?? 40
            if location.x < x + lean.before + w / 2 {
                position = flat.firstIndex { $0.id == item.id }
                break
            }
            x += lean.before + w + lean.after + spacing
        }
        if position == nil, let end = shelves[shelf].last(where: { $0.id != key }) {
            position = (flat.firstIndex { $0.id == end.id } ?? 0) + 1
        }
        guard let position else { return }
        setSpot(FolioNookDropSpot(shelf: shelf, position: position))
    }

    /// Where a book stands on the shelves: the center of its spine, before its lean.
    private func center(of key: String, in shelves: [[FolioNookItem]], widths: [String: CGFloat]) -> CGPoint? {
        for (shelf, row) in shelves.enumerated() {
            let leans = self.leans(row, free: innerWidth - used(row, widths), keepBookend: shelf == shelves.count - 1)
            var x = frameInset + sidePadding
            for item in row {
                let lean = leans[item.id] ?? FolioSpineLean()
                let w = widths[item.id] ?? 40
                if item.id == key {
                    let h = shelfHeight * FolioSpineMetrics.heightFactor(for: item)
                    return CGPoint(x: x + lean.before + w / 2, y: shelfTop(shelf) + 24 + shelfHeight - h / 2)
                }
                x += lean.before + w + lean.after + spacing
            }
        }
        return nil
    }

    private func lean(of key: String, in shelves: [[FolioNookItem]], widths: [String: CGFloat]) -> Double {
        for (shelf, row) in shelves.enumerated() where row.contains(where: { $0.id == key }) {
            let leans = self.leans(row, free: innerWidth - used(row, widths), keepBookend: shelf == shelves.count - 1)
            return leans[key]?.angle ?? 0
        }
        return 0
    }

    /// Letting go: the book moves once, into the gap. It appears right where
    /// the preview was released, at the tilt it was carried with, and one spring carries it into its
    /// place and its lean while the shelf settles around it.
    private func drop(at location: CGPoint) {
        folioDragLog.debug("drop at=\(location.debugDescription, privacy: .public) dragging=\(dragging ?? "nil", privacy: .public) spot=\(String(describing: dropSpot), privacy: .public)")
        pending.clear()
        guard let key = dragging else { return }
        let widths = Dictionary(items.map { ($0.id, FolioSpineMetrics.width(for: $0)) },
                                uniquingKeysWith: { a, _ in a })
        let list = layout(widths: widths).flatMap { $0 }
        // The shelf settles around the gap with one spring.
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            if let spot = dropSpot, let from = list.firstIndex(where: { $0.id == key }),
               spot.position != from, spot.position != from + 1 {
                if spot.position < list.count, spot.position > 0, list[spot.position - 1].id != key {
                    // Keep it on the spot's shelf: after the book before the gap.
                    nook.move(key, after: list[spot.position - 1].id)
                } else if spot.position < list.count {
                    nook.move(key, before: list[spot.position].id)
                } else if let last = list.last, last.id != key {
                    nook.move(key, after: last.id)
                }
            }
            dropSpot = nil
        }
        // Where it will stand, from the new order.
        let ordered = nook.arranged(items)
        let after = layout(widths: widths, items: ordered)
        guard let home = center(of: key, in: after, widths: widths) else { return endDrag() }
        let held = grip.offset(for: key, width: widths[key] ?? 40,
                               height: shelfHeight * FolioSpineMetrics.heightFactor(for: items.first { $0.id == key } ?? items[0]))
        let released = CGPoint(x: location.x - held.width, y: location.y - held.height)
        // It lands tilted as it was carried, then eases into its new lean.
        let startAngle = liftAngle - lean(of: key, in: after, widths: widths)

        folioDragLog.debug("land home=\(home.debugDescription, privacy: .public) released=\(released.debugDescription, privacy: .public) startAngle=\(startAngle)")
        var placing = Transaction()
        placing.disablesAnimations = true
        withTransaction(placing) {
            landing = FolioNookLanding(id: key,
                                       offset: CGSize(width: released.x - home.x, height: released.y - home.y),
                                       extraAngle: startAngle, placing: true)
            dragging = nil
        }
        DispatchQueue.main.async {
            landing?.placing = false
            withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                landing?.offset = .zero
                landing?.extraAngle = 0
            } completion: {
                if landing?.id == key { landing = nil }
            }
        }
    }

    private func endDrag() {
        pending.clear()
        guard dragging != nil || dropSpot != nil else { return }
        folioDragLog.debug("endDrag dragging=\(dragging ?? "nil", privacy: .public)")
        withAnimation(Self.slide) {
            dragging = nil
            dropSpot = nil
        }
    }

    /// Where a shelf's last book ends, in the shelf's own coordinates.
    private func rowEnd(_ row: [FolioNookItem], widths: [String: CGFloat], leans: [String: FolioSpineLean]) -> CGFloat {
        sidePadding + row.reduce(CGFloat(0)) { sum, item in
            let lean = leans[item.id] ?? FolioSpineLean()
            return sum + (widths[item.id] ?? 40) + spacing + lean.before + lean.after
        }
    }

    private func shift(_ item: FolioNookItem, by step: Int) {
        let items = nook.arranged(self.items)
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
        let thickness = max(8, width - 6)
        let size = min(16, max(7, width * 0.36))
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
    /// Dark pewter on the light shelf, lighter pewter on the dark one so it stays visible.
    private let metal = FolioTheme.dynamic(light: 0x3D463B, dark: 0x9AA391)

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
    /// Leaning books pivot on the bottom corner they tip toward.
    var anchor: UnitPoint = .bottom
}

/// A move within the nook: the system shows no "+" copy badge, and the shelf
/// rearranges as the book passes over it.
struct FolioNookDropDelegate: DropDelegate {
    let hovered: (CGPoint) -> Void
    let dropped: (CGPoint) -> Void
    var left: () -> Void = {}

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.plainText]) }
    func dropEntered(info: DropInfo) { hovered(info.location) }
    func dropExited(info: DropInfo) { left() }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        hovered(info.location)
        return DropProposal(operation: .move)
    }
    func performDrop(info: DropInfo) -> Bool {
        dropped(info.location)
        return true
    }
}

/// The drag the system is getting ready. A plain reference, so the system's
/// repeated requests for drag data never redraw the shelf.
final class FolioNookPending {
    private var id: String?
    private(set) var lean: Double = 0

    func prepare(_ id: String, lean: Double) {
        self.id = id
        self.lean = lean
    }

    func take() -> String? {
        defer { id = nil }
        return id
    }

    func clear() { id = nil }
}

/// A book landing after a drop: how far it still is from its place, and how
/// much of its lean it still has to take on.
struct FolioNookLanding: Equatable {
    let id: String
    var offset: CGSize
    var extraAngle: Double
    var placing: Bool
}

/// Where the pointer last rested on a book, so a landing starts under the
/// pointer. A plain reference: tracking it never redraws the shelf.
final class FolioNookGrip {
    private var id: String?
    private var point: CGPoint = .zero

    func hold(_ id: String, at point: CGPoint) {
        self.id = id
        self.point = point
    }

    /// From the book's center to where it was held; the center when unknown.
    func offset(for id: String, width: CGFloat, height: CGFloat) -> CGSize {
        guard self.id == id else { return .zero }
        return CGSize(width: point.x - width / 2, height: point.y - height / 2)
    }
}

/// The gap a dragged book would fill: before the book at `position` in
/// shelf order (or at the end), shown on `shelf`.
struct FolioNookDropSpot: Equatable {
    let shelf: Int
    let position: Int
}

/// Brings a dragged book back when the drag ends anywhere, even outside the
/// shelf. Before iOS 27 there is no such signal, so the book stays in view
/// while it is dragged.
struct FolioNookDragEnd: ViewModifier {
    let ended: () -> Void

    /// Whether this system tells us when a drag ends, so a lifted book can
    /// safely leave its place.
    static var tracked: Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 26.0, *) { return true }
        #endif
        return false
    }

    func body(content: Content) -> some View {
        #if compiler(>=6.4)
        if #available(iOS 27.0, macOS 26.0, *) {
            content.onDragSessionUpdated { session in
                if case .ended = session.phase { ended() }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

/// A spine's offset and tilt as one animatable effect.
struct FolioSpinePose: GeometryEffect {
    let id: String
    var x: CGFloat
    var y: CGFloat
    var angle: Double
    let anchor: UnitPoint

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, Double> {
        get { AnimatablePair(AnimatablePair(x, y), angle) }
        set { x = newValue.first.first; y = newValue.first.second; angle = newValue.second }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let ax = size.width * anchor.x, ay = size.height * anchor.y
        let radians = angle * .pi / 180
        let t = CGAffineTransform(translationX: x, y: y)
            .translatedBy(x: ax, y: ay)
            .rotated(by: radians)
            .translatedBy(x: -ax, y: -ay)
        return ProjectionTransform(t)
    }
}
