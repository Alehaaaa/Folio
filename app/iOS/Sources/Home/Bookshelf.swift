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
    /// The book in the hand. It is drawn above the bookcase, following the
    /// finger or pointer, while its own place on the shelf stands empty.
    @State private var held: FolioNookHeld?
    /// Where the hand is, in the bookcase's space. Kept apart from `held` so
    /// following the hand never animates while the tilt and lift do.
    /// Held in its own observed object that only the floating book reads,
    /// so following the finger never redraws the shelves.
    @State private var hand = FolioNookHand()
    /// Where the held book would land. While a book is in the hand the shelf
    /// only slides books aside to open a gap there; nothing re-packs or
    /// re-tilts until it's let go, so the books stay calm.
    @State private var dropSpot: FolioNookDropSpot?
    /// Whether a press on a spine is still going, to notice a press the
    /// system took away (a menu opening, a call coming in).
    @GestureState private var pressing = false
    /// A finger has rested on a spine long enough to pick it up: the page
    /// holds still, and moving in any direction lifts the book.
    @GestureState private var pressHeld = false
    /// Where the bookcase sits on screen, to find the remove bin from the
    /// hand. A plain reference, so scrolling never redraws the shelves.
    @State private var place = FolioNookPlace()
    @State private var bounds: CGSize = .zero
    /// A book dragged in from a Home row, shown as a spine in the gap where
    /// it would go.
    @State private var incoming: FolioNookItem?
    /// SwiftUI reports a drag leaving the shelf just before the drop itself,
    /// so the gap closes only a moment after the drag leaves, and a drop
    /// that follows still lands where it was shown.
    @State private var leaving = FolioNookSwayRest()
    @State private var swayRest = FolioNookSwayRest()
    @State private var swipe = FolioNookSwipe()
    /// The bookcase opened out to every book, past the shelf limit, to see
    /// and reorder the ones waiting in the pile.
    @State private var expanded = false
    @Namespace private var shelfSpace
    @ScaledMetric(relativeTo: .body) private var rowHeight: CGFloat = 186

    private let frameInset: CGFloat = 11
    private let spacing: CGFloat = 4
    private let sidePadding: CGFloat = 14

    private var shelfHeight: CGFloat { min(rowHeight, 250) }
    /// Room above the tallest book for its ribbon and a finger.
    private let headroom: CGFloat = 12
    /// The label row between your shelves and the ones past the limit.
    private let dividerHeight: CGFloat = 22
    /// Each shelf is only as tall as the tallest book on the bookcase.
    private var boxHeight: CGFloat {
        let tallest = items.map { FolioSpineMetrics.heightFactor(for: $0) }.max() ?? 0.9
        return shelfHeight * tallest + headroom
    }
    private var innerWidth: CGFloat { max(120, width - frameInset * 2 - sidePadding * 2) }

    var body: some View {
        let widths = Dictionary((items + (incoming.map { [$0] } ?? [])).map { ($0.id, FolioSpineMetrics.width(for: $0)) },
                                uniquingKeysWith: { a, _ in a })
        // The live order from the nook store, so a drop shows in the same
        // frame as the move instead of a frame later, when Home re-renders.
        let ordered = nook.arranged(items)
        // The shelves as they stand: gaps are picked against these, so
        // showing an incoming book can never move the gap.
        let standing = layout(widths: widths, items: ordered)
        let standingLeans = standing.enumerated().map { index, row in
            leans(row, free: innerWidth - used(row, widths), keepBookend: index == standing.count - 1)
        }
        let shelves = withIncoming(standing, widths: widths)
        let onShelves = Set(shelves.flatMap { $0 }.map(\.id))
        let pile = ordered.filter { !onShelves.contains($0.id) && $0.id != incoming?.id }
        let limit = max(1, nook.maxShelves)
        let slides = self.slides(shelves, widths: widths)
        let rowLeans = incoming == nil ? standingLeans : shelves.enumerated().map { index, row in
            leans(row, free: innerWidth - used(row, widths), keepBookend: index == shelves.count - 1)
        }
        VStack(spacing: 0) {
            ForEach(Array(shelves.enumerated()), id: \.offset) { index, row in
                let last = index == shelves.count - 1
                if expanded && index == limit {
                    // The shelves past the limit, set apart with a label of their own.
                    Text("Beyond your shelves")
                        .font(.caption)
                        .foregroundStyle(.black.opacity(0.45))
                        .frame(maxWidth: .infinity)
                        .frame(height: dividerHeight)
                        .transition(.opacity)
                }
                let used = self.used(row, widths)
                let leans = rowLeans[index]
                let leanRoom = leans.values.reduce(CGFloat(0)) { $0 + $1.before + $1.after }
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(measured ? row : []) { item in
                        let lean = leans[item.id] ?? FolioSpineLean()
                        Group {
                            if item.id == incoming?.id {
                                incomingSpine(item)
                            } else {
                                spine(item, lean: lean, shelves: shelves, widths: widths, leans: rowLeans)
                            }
                        }
                            .modifier(FolioSpinePose(
                                id: item.id,
                                x: slides[item.id] ?? 0,
                                y: 0,
                                angle: lean.angle,
                                anchor: lean.anchor
                            ))
                            .matchedGeometryEffect(id: item.id, in: shelfSpace)
                            // A book leaving sinks quickly instead of lingering as a ghost.
                            .transition(.asymmetric(
                                insertion: .opacity.animation(.easeOut(duration: 0.2)),
                                removal: .scale(scale: 0.85, anchor: .bottom)
                                    .combined(with: .opacity)
                                    .animation(.easeIn(duration: 0.14))))
                            .padding(.leading, lean.before)
                            .padding(.trailing, lean.after)
                            .zIndex(abs(lean.angle) > 3 ? 1 : 0)
                    }
                    if last && innerWidth - used - leanRoom >= 30,
                       abs(leans[row.last?.id ?? ""]?.angle ?? 0) < 3 {
                        FolioBookend(height: shelfHeight * 0.36)
                            .padding(.leading, 2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, sidePadding)
                .frame(height: boxHeight, alignment: .bottom)
                // Books stepping aside for a gap slide behind the frame, not over it.
                .clipped()
                .background(shelfBack)
                plank(last: last && pile.isEmpty && !(expanded && shelves.count > limit))
            }
            // The pile and Show less trade places quickly, so neither lingers
            // over the shelves sliding into view.
            if !expanded && !pile.isEmpty {
                pileDrawer(pile, widths: widths)
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
                plank(last: true)
            } else if expanded && shelves.count > limit {
                showLess
                    .transition(.opacity.animation(.easeOut(duration: 0.12)))
                plank(last: true)
            }
        }
        .padding(.horizontal, frameInset)
        .padding(.top, frameInset)
        .coordinateSpace(.named(Self.space))
        // Books dragged in from the rows below.
        .onDrop(of: [.plainText], delegate: FolioNookIncomingDrop(
            hovered: { location in hoverIncoming(location, shelves: standing, widths: widths, leans: standingLeans) },
            left: {
                guard incoming != nil else { return }
                leaving.schedule(after: 0.15) {
                    withAnimation(Self.slide) {
                        incoming = nil
                        dropSpot = nil
                    }
                }
            },
            dropped: { provider in dropIncoming(provider) }
        ))
        .background(
            LinearGradient(colors: [FolioTheme.wood.opacity(0.92), FolioTheme.wood],
                           startPoint: .top, endPoint: .bottom),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        // Everything stays inside the frame, so opening out or folding back
        // reveals shelves as the bookcase itself grows, edges always joined.
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.black.opacity(0.08), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.10), radius: 16, y: 8)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            bounds = size
            guard size.width != width || !measured else { return }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                width = size.width
                measured = true
            }
        }
        .animation(.spring(response: 0.45, dampingFraction: 0.72), value: ordered.map(\.id))
        // The book in the hand, drawn above every shelf so nothing clips it.
        // It sits outside the shelf's own animation: only the hand moves it.
        .overlay(alignment: .topLeading) { heldBook }
        .onGeometryChange(for: CGPoint.self) { $0.frame(in: .global).origin } action: { origin in
            place.origin = origin
        }
        .onChange(of: pressHeld) { _, held in
            if held {
                nook.holding = true
            } else {
                // Let go, or the menu took the press: a book still in the
                // hand goes home, and a press that never moved frees the page.
                DispatchQueue.main.async {
                    if self.held?.phase == .carried { putBack() }
                    if self.held == nil { nook.holding = false }
                }
            }
        }
        .onChange(of: pressing) { _, pressed in
            // The system ended the press without a release (a menu opened):
            // the book goes home. A real release settles it first.
            guard !pressed else { return }
            swipe.reset()
            DispatchQueue.main.async { if held?.phase == .carried { putBack() } }
        }
        #if os(iOS)
        .sensoryFeedback(.impact(weight: .light, intensity: 0.6), trigger: pressHeld) { _, new in new }
        .sensoryFeedback(.impact(weight: .medium, intensity: 0.7), trigger: held?.id) { _, new in new != nil }
        .sensoryFeedback(.selection, trigger: dropSpot, condition: Self.gapMoved)
        .sensoryFeedback(.impact(weight: .heavy, intensity: 0.8), trigger: nook.overBin) { _, new in new }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Bookshelf")
    }

    /// A tick as the gap moves between places on the shelf, but not when
    /// it first opens or when the book heads for the bin.
    private static func gapMoved(_ old: FolioNookDropSpot?, _ new: FolioNookDropSpot?) -> Bool {
        guard let old, let new else { return false }
        return old != FolioNookDropSpot.away && new != FolioNookDropSpot.away
    }

    // MARK: The pile

    /// The books past the shelf limit, as a low pile under the shelves:
    /// small books lying flat in their colors, stacked like a real pile. A
    /// tap opens the bookcase out to every book.
    private func pileDrawer(_ pile: [FolioNookItem], widths: [String: CGFloat]) -> some View {
        let shown = Array(pile.prefix(18))
        let stacks = stride(from: 0, to: shown.count, by: 3).map { Array(shown[$0..<min($0 + 3, shown.count)]) }
        return Button {
            FolioLog.log("open the pile (\(pile.count))", "nook")
            withAnimation(.smooth(duration: 0.42)) { expanded = true }
        } label: {
            // The pile rests on the plank, while the label and arrow sit in
            // the middle of the whole row, headroom included.
            HStack(alignment: .center, spacing: 12) {
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(Array(stacks.enumerated()), id: \.offset) { _, stack in
                        VStack(spacing: 0.5) {
                            ForEach(stack.reversed()) { item in
                                FolioPiledBook(item: item, length: 34 + 22 * (FolioSpineMetrics.heightFactor(for: item) - 0.7),
                                               thickness: max(7, min(13, (widths[item.id] ?? 40) * 0.24)))
                            }
                        }
                    }
                }
                .padding(.top, 6)
                // Never shorter than the label, so a small pile still sits low.
                .frame(minHeight: 32, alignment: .bottom)
                Text("\(pile.count) more")
                    .font(.footnote)
                    .foregroundStyle(FolioTheme.muted)
                Spacer(minLength: 0)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, sidePadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shelfBack)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pile.count == 1 ? "1 more book" : "\(pile.count) more books")
        .accessibilityHint("Shows every book so you can arrange them")
    }

    /// Folds the opened-out bookcase back to its shelves.
    private var showLess: some View {
        Button {
            withAnimation(.smooth(duration: 0.42)) { expanded = false }
        } label: {
            HStack(spacing: 6) {
                Text("Show less")
                    .font(.footnote)
                Image(systemName: "chevron.up")
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(FolioTheme.muted)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(shelfBack)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Layout

    /// Fills shelves left to right in the books' places. When there are more
    /// books than room, books being read keep their spot first, then the
    /// earliest places, so the shelf never shuffles.
    private func layout(widths: [String: CGFloat], items: [FolioNookItem]? = nil) -> [[FolioNookItem]] {
        let items = items ?? nook.arranged(self.items)
        let all = pack(items, widths)
        if all.isEmpty { return [[]] }
        // One rule: the shelves hold the books in their order, and the rest
        // wait in the pile below until the bookcase is opened out.
        if expanded { return all }
        return Array(all.prefix(max(1, nook.maxShelves)))
    }

    /// Notes in the log which books the shelves have no room for.
    private func reportCrowding(_ shown: [[FolioNookItem]], of all: [FolioNookItem]) {
        let ids = Set(shown.flatMap { $0 }.map(\.id))
        let left = all.filter { !ids.contains($0.id) }.map(\.title)
        guard !left.isEmpty else { return }
        FolioLog.log("no room on \(nook.maxShelves) shelf(s) for: \(left.joined(separator: ", "))", "nook")
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

    static let space = "folio.nook"
    @MainActor private static var reportedUnknown = false

    @ViewBuilder
    private func link(_ item: FolioNookItem) -> some View {
        // Only the book in the hand is seen; its place on the shelf stays empty.
        let label = FolioMobileSpine(item: item, shelfHeight: shelfHeight)
            .opacity(held?.id == item.id ? 0 : 1)
        switch item.source {
        case .library(let id):
            NavigationLink(value: id) { label }
        case .remote(let book):
            NavigationLink(value: book) { label }
        }
    }

    private func spine(_ item: FolioNookItem, lean: FolioSpineLean, shelves: [[FolioNookItem]],
                       widths: [String: CGFloat], leans: [[String: FolioSpineLean]]) -> some View {
        link(item)
            .buttonStyle(FolioSpineButtonStyle())
            // A book in the hand never opens when it's let go.
            .disabled(held?.id == item.id)
            .contentShape(Rectangle())
            .folioNookMenu(item)
            .simultaneousGesture(carry(item, lean: lean, shelves: shelves, widths: widths, leans: leans))
            #if os(iOS)
            .simultaneousGesture(pickUp(item, lean: lean, shelves: shelves, widths: widths, leans: leans))
            #endif
            .accessibilityLabel(accessibilityLabel(item))
            .accessibilityHint("Opens book details. Long press for more.")
            .accessibilityAction(named: "Move left") { shift(item, by: -1) }
            .accessibilityAction(named: "Move right") { shift(item, by: 1) }
            .accessibilityAction(named: "Hide from nook") { withAnimation(.snappy) { nook.hide(item) } }
    }

    // MARK: Carrying a book

    /// The book in the hand: the spine alone, a little larger and with a
    /// soft shadow under it, tilting with the motion.
    @ViewBuilder
    private var heldBook: some View {
        if let held {
            FolioMobileSpine(item: held.item, shelfHeight: shelfHeight)
                // Over the bin it shrinks toward it, and drops in on release.
                .scaleEffect(heldScale(held))
                .opacity(held.discarded ? 0.0 : (nook.overBin ? 0.85 : 1.0))
                .shadow(color: .black.opacity(held.lifted ? 0.26 : 0), radius: held.lifted ? 16 : 2,
                        y: held.lifted ? 12 : 1)
                .modifier(FolioNookHandPose(hand: hand, grab: held.grab))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(.identity)
        }
    }

    private func heldScale(_ held: FolioNookHeld) -> CGFloat {
        if held.discarded { return 0.12 }
        if nook.overBin { return 0.55 }
        return held.lifted ? 1.07 : 1
    }

    #if os(iOS)
    /// Touch: a tap opens the book and a hold opens its menu, both at the
    /// system's own timing. Sliding a book sideways picks it up; a vertical
    /// swipe is left to the page.
    private func carry(_ item: FolioNookItem, lean: FolioSpineLean, shelves: [[FolioNookItem]],
                       widths: [String: CGFloat], leans: [[String: FolioSpineLean]]) -> some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .named(Self.space))
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { drag in
                if held == nil {
                    guard swipe.decide(drag.translation) else { return }
                }
                follow(item, lean: lean, drag: drag, shelves: shelves, widths: widths, leans: leans)
            }
            .onEnded { drag in
                swipe.reset()
                release(item.id, at: drag.location)
            }
    }

    /// Touch and hold: after a short rest the book is ready to come out, and
    /// the first move in any direction lifts it, down to the remove bin too.
    /// Holding still a little longer still opens the menu, which takes the
    /// press away before anything is lifted.
    private func pickUp(_ item: FolioNookItem, lean: FolioSpineLean, shelves: [[FolioNookItem]],
                        widths: [String: CGFloat], leans: [[String: FolioSpineLean]]) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space)))
            .updating($pressHeld) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
            .onChanged { value in
                guard case .second(true, let drag?) = value else { return }
                // Only a real move lifts it, so the menu's preview never
                // finds an empty slot.
                if held == nil {
                    let moved = hypot(drag.translation.width, drag.translation.height)
                    guard moved >= 6 else { return }
                }
                follow(item, lean: lean, drag: drag, shelves: shelves, widths: widths, leans: leans)
            }
            .onEnded { value in
                guard case .second(true, let drag?) = value else { return }
                release(item.id, at: drag.location)
            }
    }
    #else
    /// Mouse: click opens the book, right-click its menu, dragging picks it up.
    private func carry(_ item: FolioNookItem, lean: FolioSpineLean, shelves: [[FolioNookItem]],
                       widths: [String: CGFloat], leans: [[String: FolioSpineLean]]) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($pressing) { _, state, _ in state = true }
            .onChanged { drag in
                follow(item, lean: lean, drag: drag, shelves: shelves, widths: widths, leans: leans)
            }
            .onEnded { drag in release(item.id, at: drag.location) }
    }
    #endif

    /// Picks the book up exactly as it stood, lean and all, then lets it lift
    /// out of the shelf toward the hand.
    private func lift(_ item: FolioNookItem, lean: FolioSpineLean, at start: CGPoint,
                      shelves: [[FolioNookItem]], widths: [String: CGFloat]) {
        guard let place = center(of: item.id, in: shelves, widths: widths) else { return }
        let size = CGSize(width: widths[item.id] ?? 40, height: shelfHeight * FolioSpineMetrics.heightFactor(for: item))
        let shift = Self.pivotShift(angle: lean.angle, anchor: lean.anchor, size: size)
        // A pressed spine stands a little raised (see FolioSpineButtonStyle).
        let home = CGPoint(x: place.x + shift.width, y: place.y + shift.height)
        let seen = CGPoint(x: home.x, y: home.y - FolioSpineButtonStyle.raise)
        FolioLog.log("lift \"\(item.title)\" (\(item.id))", "nook")

        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            held = FolioNookHeld(item: item, grab: CGSize(width: start.x - seen.x, height: start.y - seen.y),
                                 home: home, homeAngle: lean.angle)
            hand.point = start
            hand.sway = lean.angle
            // The gap opens where the book was, so nothing moves yet.
            let flat = shelves.flatMap { $0 }
            if let from = flat.firstIndex(where: { $0.id == item.id }),
               let shelf = shelves.firstIndex(where: { $0.contains { $0.id == item.id } }) {
                dropSpot = FolioNookDropSpot(shelf: shelf, position: from + 1)
            }
        }
        nook.holding = true
        withAnimation(.spring(response: 0.3, dampingFraction: 0.66)) {
            held?.lifted = true
            hand.sway = 0
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { nook.carrying = true }
    }

    private func follow(_ item: FolioNookItem, lean: FolioSpineLean, drag: DragGesture.Value,
                        shelves: [[FolioNookItem]], widths: [String: CGFloat], leans: [[String: FolioSpineLean]]) {
        if held == nil { lift(item, lean: lean, at: drag.startLocation, shelves: shelves, widths: widths) }
        guard let current = held, current.id == item.id, current.phase == .carried else { return }
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { hand.point = drag.location }

        // The book swings a little with the motion, like a book held near the top.
        let target = max(-10, min(10, Double(drag.velocity.width) / 110))
        if abs(target - hand.sway) > 0.6 {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.62)) { hand.sway = target }
        }
        swayRest.schedule {
            guard held?.phase == .carried else { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) { hand.sway = 0 }
        }

        let center = CGPoint(x: drag.location.x - current.grab.width, y: drag.location.y - current.grab.height)
        let over = CGRect(origin: .zero, size: bounds).insetBy(dx: -24, dy: -24)
        let onScreen = CGPoint(x: place.origin.x + drag.location.x, y: place.origin.y + drag.location.y)
        let binned = !nook.binFrame.isEmpty && nook.binFrame.insetBy(dx: -28, dy: -36).contains(onScreen)
        if binned != nook.overBin {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.62)) { nook.overBin = binned }
        }
        if binned {
            // Over the bin, the shelf closes up as if the book were gone.
            if dropSpot != .away { withAnimation(Self.slide) { dropSpot = .away } }
        } else if over.contains(drag.location) {
            hover(center, shelves: shelves, widths: widths, leans: leans)
        } else if dropSpot != nil {
            // Off the bookcase the gap closes; the book still waits in the hand.
            withAnimation(Self.slide) { dropSpot = nil }
        }
    }

    /// Letting go: the book moves once, into the gap. It flies from the hand
    /// into its place and takes on its new lean in one spring, while the
    /// shelf settles around it. Off the shelf, it flies back home.
    private func release(_ key: String, at location: CGPoint) {
        guard let current = held, current.id == key, current.phase == .carried else { return }
        swayRest.cancel()
        FolioLog.log("let go \"\(current.item.title)\" spot=\(dropSpot.map { "\($0.shelf)/\($0.position)" } ?? "off the shelf")", "nook")
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) {
            hand.point = location
            held?.phase = .settling
        }
        if nook.overBin { return discard(current) }
        guard let spot = dropSpot, spot != .away else { return settle(at: current.home, angle: current.homeAngle) }

        let widths = Dictionary(items.map { ($0.id, FolioSpineMetrics.width(for: $0)) },
                                uniquingKeysWith: { a, _ in a })
        let list = layout(widths: widths).flatMap { $0 }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            if let from = list.firstIndex(where: { $0.id == key }),
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
        let was = list.firstIndex { $0.id == key } ?? -1
        let now = nook.arranged(items).firstIndex { $0.id == key } ?? -1
        FolioLog.log("moved from \(was) to \(now) (gap \(spot.position))", "nook")
        // Where it will stand, from the new order.
        let after = layout(widths: widths, items: nook.arranged(items))
        guard let place = center(of: key, in: after, widths: widths) else {
            return settle(at: current.home, angle: current.homeAngle)
        }
        let lean = self.lean(of: key, in: after, widths: widths)
        let size = CGSize(width: widths[key] ?? 40, height: shelfHeight * FolioSpineMetrics.heightFactor(for: current.item))
        let shift = Self.pivotShift(angle: lean.angle, anchor: lean.anchor, size: size)
        settle(at: CGPoint(x: place.x + shift.width, y: place.y + shift.height), angle: lean.angle)
    }

    /// Letting go over the bin: the book drops into it, shrinking away, and
    /// the shelf closes the gap it left. Undo brings it back.
    private func discard(_ current: FolioNookHeld) {
        let key = current.id
        FolioLog.log("remove \"\(current.item.title)\" from the shelf", "nook")
        let bin = nook.binFrame
        let target = CGPoint(x: bin.midX - place.origin.x, y: bin.midY - place.origin.y)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            hand.point = CGPoint(x: target.x + current.grab.width, y: target.y + current.grab.height)
            hand.sway = 0
            held?.discarded = true
        } completion: {
            guard held?.id == key else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                held = nil
                dropSpot = nil
            }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
                nook.remove(current.item)
                nook.carrying = false
                nook.overBin = false
            }
            nook.holding = false
        }
    }

    /// Puts the book in the hand back where it came from.
    private func putBack() {
        guard let current = held, current.phase == .carried else { return }
        swayRest.cancel()
        held?.phase = .settling
        settle(at: current.home, angle: current.homeAngle)
    }

    /// Carries the held book to `point` (its center on the shelf) at `angle`,
    /// then hands it back to the shelf without a seam.
    private func settle(at point: CGPoint, angle: Double) {
        guard let current = held else { return }
        let key = current.id
        withAnimation(Self.slide) { dropSpot = nil }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) {
            nook.carrying = false
            nook.overBin = false
        }
        withAnimation(.spring(response: 0.36, dampingFraction: 0.8)) {
            hand.point = CGPoint(x: point.x + current.grab.width, y: point.y + current.grab.height)
            hand.sway = angle
            held?.lifted = false
        } completion: {
            guard held?.id == key else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) {
                held = nil
                hand.sway = 0
            }
            nook.holding = false
        }
    }

    /// How far a book's center moves when it tips by `angle` about `anchor`
    /// instead of about its center: drawing the held book rotated about its
    /// center, this shift puts it exactly where it stood on the shelf.
    static func pivotShift(angle: Double, anchor: UnitPoint, size: CGSize) -> CGSize {
        let radians = angle * .pi / 180
        // From the anchor to the center.
        let dx = size.width * (0.5 - anchor.x), dy = size.height * (0.5 - anchor.y)
        let rx = dx * cos(radians) - dy * sin(radians)
        let ry = dx * sin(radians) + dy * cos(radians)
        return CGSize(width: rx - dx, height: ry - dy)
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
        guard let key = held?.id, let spot = dropSpot else { return [:] }
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
                if shelf == fromShelf, position > from { x -= gap }
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
    private func shelfTop(_ shelf: Int) -> CGFloat {
        let divider = expanded && shelf >= max(1, nook.maxShelves) ? dividerHeight : 0
        return frameInset + CGFloat(shelf) * (boxHeight + plankHeight) + divider
    }

    /// The shelf under a point, allowing for the label row when opened out.
    private func shelfIndex(at y: CGFloat, count: Int) -> Int {
        let pitch = boxHeight + plankHeight
        let limit = CGFloat(max(1, nook.maxShelves))
        var y = y - frameInset
        if expanded && y > limit * pitch { y = max(limit * pitch, y - dividerHeight) }
        return min(count - 1, max(0, Int(y / pitch)))
    }

    /// Picks the gap from where the held book is: the shelf under its
    /// center, and how many of that shelf's other books stand left of it.
    private func hover(_ location: CGPoint, shelves: [[FolioNookItem]], widths: [String: CGFloat],
                       leans: [[String: FolioSpineLean]], excluding: String? = nil) {
        guard let key = excluding ?? held?.id, !shelves.isEmpty else { return }
        let shelf = shelfIndex(at: location.y, count: shelves.count)
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
        } else if position == nil, shelves[shelf].contains(where: { $0.id == key }) {
            // Alone on its shelf: it stays where it is.
            position = (flat.firstIndex { $0.id == key } ?? 0) + 1
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
                    return CGPoint(x: x + lean.before + w / 2, y: shelfTop(shelf) + boxHeight - h / 2)
                }
                x += lean.before + w + lean.after + spacing
            }
        }
        return nil
    }

    // MARK: Books from the rows

    /// The shelves with the incoming book standing in its gap, in place of
    /// its own copy when it's already on the shelf.
    private func withIncoming(_ shelves: [[FolioNookItem]], widths: [String: CGFloat]) -> [[FolioNookItem]] {
        guard let incoming, let spot = dropSpot else { return shelves }
        var list = shelves.flatMap { $0 }
        list.insert(incoming, at: min(spot.position, list.count))
        if let copy = list.indices.first(where: { list[$0].id == incoming.id && $0 != min(spot.position, list.count - 1) }) {
            list.remove(at: copy)
        }
        return layout(widths: widths, items: list)
    }

    /// The incoming book, a little raised, as if about to be slid in.
    private func incomingSpine(_ item: FolioNookItem) -> some View {
        FolioMobileSpine(item: item, shelfHeight: shelfHeight)
            .offset(y: -6)
            .shadow(color: .black.opacity(0.22), radius: 8, y: 5)
            .opacity(0.92)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .bottom)))
    }

    /// The shelf copy standing for a book from a row, if it's already there.
    private func copy(of book: HCBook) -> FolioNookItem? {
        let keys = Set(FolioNookShelf.keys(for: book))
        return items.first { !keys.isDisjoint(with: $0.keys) }
    }

    private func hoverIncoming(_ location: CGPoint, shelves: [[FolioNookItem]], widths: [String: CGFloat],
                               leans: [[String: FolioSpineLean]]) {
        guard held == nil else { return }
        guard let book = nook.incoming else {
            if !Self.reportedUnknown {
                Self.reportedUnknown = true
                FolioLog.log("hover without a known book", "nook")
            }
            return
        }
        leaving.cancel()
        let existing = copy(of: book)
        let bookKeys = FolioNookShelf.keys(for: book)
        if incoming.map({ !Set($0.keys).isDisjoint(with: bookKeys) }) != true {
            var item = existing ?? FolioNookShelf.item(for: book)
            if existing == nil { item.pinned = true }
            FolioLog.log("hover \"\(book.title)\" as \(item.id)\(existing == nil ? "" : " (already on the shelf)")", "nook")
            FolioSpinePalettes.shared.prepare([item])
            withAnimation(Self.slide) { incoming = item }
        }
        // An empty shelf takes it at the start.
        if shelves.allSatisfy(\.isEmpty) {
            setSpot(FolioNookDropSpot(shelf: 0, position: 0))
            return
        }
        hover(location, shelves: shelves, widths: widths, leans: leans, excluding: existing?.id ?? "")
    }

    /// Puts the incoming book on the shelf, in the gap it was shown in.
    /// The gap is taken at once: right after the drop the system reports the
    /// drag leaving the shelf. The book comes from the drag itself when the
    /// shelf didn't see it start.
    private func dropIncoming(_ provider: NSItemProvider?) {
        leaving.cancel()
        let spot = dropSpot
        let known = nook.incoming
        let shown = incoming
        nook.incoming = nil
        FolioLog.log("drop known=\(known?.title ?? "nil") spot=\(spot.map { "\($0.shelf)/\($0.position)" } ?? "nil")", "nook")
        if let known {
            place(known, ghost: shown, spot: spot)
            return
        }
        guard let provider else {
            withAnimation(Self.slide) { incoming = nil; dropSpot = nil }
            return
        }
        _ = provider.loadObject(ofClass: NSString.self) { object, error in
            let text = (object as? NSString).map { $0 as String }
            DispatchQueue.main.async {
                guard let book = FolioNookIncomingDrop.book(from: text) else {
                    FolioLog.log("drop without a Folio book: \(error?.localizedDescription ?? String((text ?? "").prefix(40)))", "nook")
                    withAnimation(Self.slide) { incoming = nil; dropSpot = nil }
                    return
                }
                place(book, ghost: shown, spot: spot)
            }
        }
    }

    private func place(_ book: HCBook, ghost shown: FolioNookItem?, spot: FolioNookDropSpot?) {
        let ghost = shown ?? copy(of: book) ?? FolioNookShelf.item(for: book)
        let widths = Dictionary(items.map { ($0.id, FolioSpineMetrics.width(for: $0)) },
                                uniquingKeysWith: { a, _ in a })
        let list = layout(widths: widths).flatMap { $0 }
        let position = min(spot?.position ?? list.count, list.count)
        let keys = Set(copy(of: book)?.keys ?? FolioNookShelf.keys(for: book))
        let previous = list[..<position].last { keys.isDisjoint(with: $0.keys) }?.id
        FolioLog.log("add \(ghost.id) \"\(book.title)\" after \(previous ?? "start")", "nook")
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            nook.pin(book, keys: [ghost.id] + ghost.aliases, after: previous)
            incoming = nil
            dropSpot = nil
        }
        FolioLog.log("pinned \(nook.pinned.count), order has it: \(nook.order.contains(ghost.id))", "nook")
        let all = nook.arranged(items + (copy(of: book) == nil ? [ghost] : []))
        var widthsAfter = widths
        widthsAfter[ghost.id] = FolioSpineMetrics.width(for: ghost)
        reportCrowding(layout(widths: widthsAfter, items: all), of: all)
    }

    private func lean(of key: String, in shelves: [[FolioNookItem]], widths: [String: CGFloat]) -> FolioSpineLean {
        for (shelf, row) in shelves.enumerated() where row.contains(where: { $0.id == key }) {
            let leans = self.leans(row, free: innerWidth - used(row, widths), keepBookend: shelf == shelves.count - 1)
            return leans[key] ?? FolioSpineLean()
        }
        return FolioSpineLean()
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
