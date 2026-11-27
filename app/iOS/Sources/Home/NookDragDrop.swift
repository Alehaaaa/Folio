import SwiftUI
import UniformTypeIdentifiers
import os

/// A book dragged in from a Home row: the shelf shows its spine where it
/// would go, and puts it there on the drop.
struct FolioNookIncomingDrop: DropDelegate {
    let hovered: (CGPoint) -> Void
    let left: () -> Void
    let dropped: (NSItemProvider?) -> Void

    /// The book itself travels with the drag, so a drop never depends on
    /// what the shelf remembered while it hovered.
    static func payload(for book: HCBook) -> String {
        let json = (try? JSONEncoder().encode(book)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        return prefix + json
    }

    static let prefix = "folio-book:"

    static func book(from payload: String?) -> HCBook? {
        guard let payload, payload.hasPrefix(prefix) else { return nil }
        return try? JSONDecoder().decode(HCBook.self, from: Data(payload.dropFirst(prefix.count).utf8))
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }
    func dropEntered(info: DropInfo) {
        FolioLog.log("enter shelf at \(Int(info.location.x)),\(Int(info.location.y))", "nook")
        hovered(info.location)
    }
    func dropExited(info: DropInfo) {
        FolioLog.log("leave shelf", "nook")
        left()
    }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        hovered(info.location)
        return DropProposal(operation: .copy)
    }
    func performDrop(info: DropInfo) -> Bool {
        FolioLog.log("perform drop at \(Int(info.location.x)),\(Int(info.location.y))", "nook")
        dropped(info.itemProviders(for: [.plainText]).first)
        return true
    }

}

/// Lets a book in a Home row be dragged onto the shelf.
struct FolioNookDragSource: ViewModifier {
    let book: HCBook
    @Environment(\.folioNookDragSource) private var enabled

    func body(content: Content) -> some View {
        if enabled {
            let cover = FolioBookOverrides.shared.apply(book).imageURL
            content
                .onDrag {
                MainActor.assumeIsolated {
                    if FolioNookStore.shared.incoming?.id != book.id { FolioLog.log("drag \"\(book.title)\"", "nook") }
                    FolioNookStore.shared.incoming = book
                }
                return NSItemProvider(object: FolioNookIncomingDrop.payload(for: book) as NSString)
            } preview: {
                // A small cover, so the spine it becomes on the shelf stays in view.
                FolioCachedImage(url: cover) {
                    FolioClothCover(title: book.title, compact: true)
                }
                .frame(width: 76, height: 110)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        } else {
            content
        }
    }
}

extension EnvironmentValues {
    /// Whether book tiles here can be dragged onto the Home shelf.
    @Entry var folioNookDragSource = false
}

/// Whether a touch sliding over a spine means to pick it up: decided once,
/// by its first movement, sideways for the book and up or down for the page.
final class FolioNookSwipe {
    private var decided: Bool?

    func decide(_ translation: CGSize) -> Bool {
        if let decided { return decided }
        let sideways = abs(translation.width) > abs(translation.height) * 1.2
        decided = sideways
        return sideways
    }

    func reset() { decided = nil }
}

/// Where the hand is and how the book in it tilts.
@Observable
final class FolioNookHand {
    var point: CGPoint = .zero
    var sway: Double = 0
}

/// Places the held book under the hand. Only this reads the hand, so a
/// finger moving redraws the floating book alone.
struct FolioNookHandPose: ViewModifier {
    let hand: FolioNookHand
    let grab: CGSize

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(hand.sway))
            .position(x: hand.point.x - grab.width, y: hand.point.y - grab.height)
    }
}

/// The book in the hand.
struct FolioNookHeld: Equatable {
    enum Phase { case carried, settling }
    let item: FolioNookItem
    /// From the book's center to where the hand holds it.
    let grab: CGSize
    /// Where it stood when lifted (its center, as drawn) and its lean there.
    let home: CGPoint
    let homeAngle: Double
    var lifted = false
    var phase = Phase.carried
    /// Dropped in the remove bin.
    var discarded = false
    var id: String { item.id }

    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.lifted == b.lifted && a.phase == b.phase && a.discarded == b.discarded
    }
}

/// Straightens the held book once the hand rests. A plain reference, so
/// rescheduling it on every move never redraws the shelf.
final class FolioNookSwayRest {
    private var work: DispatchWorkItem?

    func schedule(after delay: TimeInterval = 0.12, _ action: @escaping () -> Void) {
        work?.cancel()
        let item = DispatchWorkItem(block: action)
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func cancel() {
        work?.cancel()
        work = nil
    }
}

/// The gap a dragged book would fill: before the book at `position` in
/// shelf order (or at the end), shown on `shelf`.
struct FolioNookDropSpot: Equatable {
    let shelf: Int
    let position: Int

    /// Over the remove bin: the shelf closes up and opens no gap.
    static let away = FolioNookDropSpot(shelf: -1, position: .max)
}

/// Where the bookcase sits on screen, updated as the page scrolls without
/// redrawing anything.
final class FolioNookPlace {
    var origin: CGPoint = .zero
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

/// A book lying flat in the pile: its cloth color with a band and a lighter
/// page edge, so the pile reads as books at a glance.
struct FolioPiledBook: View {
    let item: FolioNookItem
    let length: CGFloat
    let thickness: CGFloat

    var body: some View {
        let palette = FolioSpinePalettes.shared.palette(for: item)
        // Each book sits a little off true, the way piles do.
        let nudge = CGFloat(Int(FolioSpineMetrics.hash(item.id + "pile") % 7) - 3)
        ZStack(alignment: .leading) {
            palette.baseColor
            palette.accentColor.frame(width: 3).padding(.leading, length * 0.18)
            LinearGradient(colors: [.white.opacity(0.16), .clear, .black.opacity(0.18)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: length, height: thickness)
        .clipShape(RoundedRectangle(cornerRadius: 1.5, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 0.6, y: 0.6)
        .offset(x: nudge)
        .accessibilityHidden(true)
    }
}

/// The remove bin that rises at the bottom of Home while a book is in the
/// hand, and the Undo notice once one has gone in.
struct FolioNookBin: View {
    @State private var nook = FolioNookStore.shared

    var body: some View {
        ZStack {
            if nook.carrying {
                bin
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let removal = nook.removal {
                undo(removal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task(id: removal.id) {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation(.smooth(duration: 0.3)) { nook.forgetRemoval(removal.id) }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: nook.carrying)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: nook.removal?.id)
        .padding(.bottom, 14)
    }

    private var bin: some View {
        let hot = nook.overBin
        return HStack(spacing: 8) {
            Image(systemName: hot ? "trash.fill" : "trash")
                .contentTransition(.symbolEffect(.replace))
            Text("Remove")
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(hot ? Color.white : FolioTheme.danger)
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background { Capsule().fill(FolioTheme.danger).opacity(hot ? 1 : 0) }
        .folioCreamGlass(in: Capsule())
        .scaleEffect(hot ? 1.14 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hot)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { nook.binFrame = $0 }
        .onDisappear { nook.binFrame = .zero }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func undo(_ removal: FolioNookRemoval) -> some View {
        HStack(spacing: 14) {
            Text("Removed from shelf")
                .foregroundStyle(FolioTheme.ink)
            Button("Undo") {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) { nook.undoRemoval() }
            }
            .fontWeight(.semibold)
            .foregroundStyle(FolioTheme.olive)
            .buttonStyle(.plain)
            .accessibilityHint("Puts \(removal.title) back on the shelf")
        }
        .font(.subheadline)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .folioCreamGlass(in: Capsule())
    }
}
