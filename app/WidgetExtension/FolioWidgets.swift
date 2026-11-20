import AppIntents
import AppKit
import SwiftUI
import WidgetKit

// Lists are discovered from the snapshot, including user-defined collections.
// There is no fixed enumeration to maintain when someone creates a new list.
struct FolioListEntity: AppEntity, Identifiable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Folio List")
    static let defaultQuery = FolioListQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

struct FolioListQuery: EntityStringQuery {
    func entities(for identifiers: [FolioListEntity.ID]) async throws -> [FolioListEntity] {
        let values = allLists()
        return identifiers.compactMap { identifier in
            values.first(where: { $0.id == FolioWidgetSnapshot.canonicalListID(identifier) })
        }
    }

    func suggestedEntities() async throws -> [FolioListEntity] { allLists() }

    func entities(matching string: String) async throws -> [FolioListEntity] {
        allLists().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }

    private func allLists() -> [FolioListEntity] {
        let snapshot = FolioWidgetStorage.read() ?? .preview
        return snapshot.lists.map { FolioListEntity(id: $0.id, name: $0.name) }
    }
}

struct FolioListIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Book List"
    static let description = IntentDescription("Choose a library list, a combined reading shelf, or your own collection.")

    @Parameter(title: "List") var list: FolioListEntity?

    init() {
        list = FolioListEntity(id: "continue", name: "Continue Reading")
    }
}

struct FolioShelfEntry: TimelineEntry {
    let date: Date
    let list: FolioWidgetList
}

struct FolioShelfProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FolioShelfEntry {
        FolioShelfEntry(date: .now, list: FolioWidgetSnapshot.preview.lists[0])
    }

    func snapshot(for configuration: FolioListIntent, in context: Context) async -> FolioShelfEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: FolioListIntent, in context: Context) async -> Timeline<FolioShelfEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func entry(for configuration: FolioListIntent) -> FolioShelfEntry {
        let snapshot = FolioWidgetStorage.read() ?? .preview
        return FolioShelfEntry(date: .now, list: snapshot.list(configuration.list?.id))
    }
}

// Artwork-first cards rather than overpacked rows. Colors are used only when macOS
// actually draws the widget in full color; accented/vibrant modes use system ink.
private enum FolioWidgetPalette {
    static let night = Color(red: 0.09, green: 0.10, blue: 0.15)
    static let slate = Color(red: 0.17, green: 0.18, blue: 0.25)
    static let mint = Color(red: 0.43, green: 0.87, blue: 0.76)
    static let lilac = Color(red: 0.57, green: 0.51, blue: 0.86)
}

private extension FolioWidgetBook {
    var artwork: NSImage? {
        guard let name = coverName,
              let url = FolioWidgetStorage.coverURL(for: name) else { return nil }
        return NSImage(contentsOf: url)
    }

    var destination: URL {
        URL(string: deepLink) ?? URL(string: "folio-reader://library/all")!
    }
}

struct FolioCover: View {
    let book: FolioWidgetBook
    var width: CGFloat = 58
    var height: CGFloat = 86

    var body: some View {
        ZStack {
            if let image = book.artwork {
                Image(nsImage: image)
                    .resizable()
                    // Without this, macOS's accented desktop style turns covers into masks.
                    .widgetAccentedRenderingMode(.fullColor)
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [FolioWidgetPalette.lilac, FolioWidgetPalette.night],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                VStack(spacing: 6) {
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: width > 50 ? 17 : 14))
                    Text(String(book.title.prefix(1)).uppercased())
                        .font(.system(size: width > 50 ? 22 : 16, weight: .bold, design: .serif))
                }
                .foregroundStyle(.white)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }
}

private struct FolioProgress: View {
    let amount: Double
    let colored: Bool

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(colored ? .white.opacity(0.24) : .primary.opacity(0.16))
                    Capsule().fill(colored ? FolioWidgetPalette.mint : Color.accentColor)
                        .frame(width: max(2, proxy.size.width * min(1, max(0, amount))))
                }
            }
            .frame(height: 4)
            Text("\(Int((min(1, max(0, amount)) * 100).rounded()))%")
                .font(.system(size: 10, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(colored ? .white.opacity(0.85) : .secondary)
        }
    }
}

// In a medium widget, two comfortable cover+text cards fit without vertical clipping.
private struct FolioBookCard: View {
    let book: FolioWidgetBook
    let colored: Bool

    var body: some View {
        Link(destination: book.destination) {
            HStack(alignment: .center, spacing: 9) {
                FolioCover(book: book, width: 54, height: 80)
                    .shadow(color: .black.opacity(0.24), radius: 5, y: 3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(colored ? .white : .primary)
                        .lineLimit(2)
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(colored ? .white.opacity(0.74) : .secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 1)
                    if let progress = book.progress {
                        FolioProgress(amount: progress, colored: colored)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 100)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(colored ? .white.opacity(0.09) : .primary.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(colored ? .white.opacity(0.13) : .primary.opacity(0.09), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}

// Larger widgets resemble a media gallery, with prominent covers and short captions.
private struct FolioBookPoster: View {
    let book: FolioWidgetBook
    let colored: Bool

    var body: some View {
        Link(destination: book.destination) {
            VStack(alignment: .leading, spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [FolioWidgetPalette.slate, FolioWidgetPalette.night],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    if colored, let image = book.artwork {
                        Image(nsImage: image)
                            .resizable()
                            .widgetAccentedRenderingMode(.fullColor)
                            .scaledToFill()
                            .blur(radius: 20)
                            .overlay(.black.opacity(0.35))
                    }
                    FolioCover(book: book, width: 60, height: 88)
                        .shadow(color: .black.opacity(0.40), radius: 7, y: 4)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 102)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(book.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(colored ? .white : .primary)
                    .lineLimit(1)
                if !book.author.isEmpty {
                    Text(book.author)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(colored ? .white.opacity(0.68) : .secondary)
                        .lineLimit(1)
                }
                if let progress = book.progress {
                    FolioProgress(amount: progress, colored: colored)
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FolioShelfView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FolioShelfEntry

    private var colored: Bool { renderingMode == .fullColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: entry.list.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(colored ? FolioWidgetPalette.mint : .primary)
                Text(entry.list.name)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(colored ? .white : .primary)
                    .lineLimit(1)
                Spacer(minLength: 2)
                Text("\(entry.list.count)")
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(colored ? .white.opacity(0.67) : .secondary)
            }

            if entry.list.books.isEmpty {
                Spacer(minLength: 0)
                Label("No books yet", systemImage: "books.vertical")
                    .font(.subheadline)
                    .foregroundStyle(colored ? .white.opacity(0.75) : .secondary)
                Spacer(minLength: 0)
            } else {
                switch family {
                case .systemSmall:
                    smallFeatured(entry.list.books[0])
                case .systemMedium:
                    HStack(alignment: .top, spacing: 9) {
                        ForEach(entry.list.books.prefix(2)) { book in
                            FolioBookCard(book: book, colored: colored)
                        }
                    }
                default:
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 11), GridItem(.flexible(), spacing: 11)], spacing: 12) {
                        ForEach(entry.list.books.prefix(4)) { book in
                            FolioBookPoster(book: book, colored: colored)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            if colored {
                LinearGradient(colors: [FolioWidgetPalette.slate, FolioWidgetPalette.night],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            } else {
                Color.clear
            }
        }
        .widgetURL(URL(string: entry.list.deepLink))
    }

    private func smallFeatured(_ book: FolioWidgetBook) -> some View {
        Link(destination: book.destination) {
            VStack(spacing: 6) {
                FolioCover(book: book, width: 63, height: 86)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                Text(book.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(colored ? .white : .primary)
                    .lineLimit(1)
                if let progress = book.progress {
                    FolioProgress(amount: progress, colored: colored)
                        .frame(maxWidth: 145)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }
}

struct FolioListsWidget: Widget {
    let kind = "app.folio.reader.widgets.lists"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: FolioListIntent.self, provider: FolioShelfProvider()) { entry in
            FolioShelfView(entry: entry)
        }
        .configurationDisplayName("Folio Lists")
        .description("Your current reads, custom collections, library filters and book shelves.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct FolioGoalsEntry: TimelineEntry {
    let date: Date
    let goals: FolioWidgetGoals
}

struct FolioGoalsProvider: TimelineProvider {
    func placeholder(in context: Context) -> FolioGoalsEntry {
        FolioGoalsEntry(date: .now, goals: FolioWidgetSnapshot.preview.goals)
    }

    func getSnapshot(in context: Context, completion: @escaping (FolioGoalsEntry) -> Void) {
        completion(current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<FolioGoalsEntry>) -> Void) {
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60)
        completion(Timeline(entries: [current()], policy: .after(min(midnight, now.addingTimeInterval(15 * 60)))))
    }

    private func current() -> FolioGoalsEntry {
        FolioGoalsEntry(date: .now, goals: (FolioWidgetStorage.read() ?? .preview).goals)
    }
}

struct FolioGoalsView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FolioGoalsEntry

    private var fraction: Double {
        min(1, entry.goals.todayMinutes / Double(max(1, entry.goals.dailyGoal)))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reading Goals", systemImage: "target")
                .font(.headline).foregroundStyle(.primary)
            HStack(spacing: 18) {
                ZStack {
                    Circle().stroke(.secondary.opacity(0.2), lineWidth: 9)
                    Circle().trim(from: 0, to: fraction)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    VStack(spacing: 1) {
                        Text("\(Int(entry.goals.todayMinutes))").font(.title3.weight(.bold).monospacedDigit())
                        Text("/ \(entry.goals.dailyGoal) min").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: family == .systemSmall ? 74 : 100, height: family == .systemSmall ? 74 : 100)

                if family != .systemSmall {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("\(entry.goals.streak) day streak", systemImage: "flame.fill")
                        Label("\(entry.goals.finishedThisYear) of \(entry.goals.yearlyGoal) books this year", systemImage: "books.vertical.fill")
                    }
                    .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)

            if family == .systemSmall {
                Text("\(entry.goals.streak) day streak · \(entry.goals.finishedThisYear)/\(entry.goals.yearlyGoal) books")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "folio-reader://goals"))
    }
}

struct FolioReadingGoalsWidget: Widget {
    let kind = "app.folio.reader.widgets.goals"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FolioGoalsProvider()) { entry in
            FolioGoalsView(entry: entry)
        }
        .configurationDisplayName("Reading Goals")
        .description("Your daily reading minutes, streak and yearly book goal.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct OpenFolioIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Folio"
    static let description = IntentDescription("Open your book library in Folio.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// A compact native control that also appears in the macOS Control Center gallery.
@available(macOS 15.0, *)
struct FolioControlWidget: ControlWidget {
    let kind = "app.folio.reader.widgets.control"

    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: kind) {
            ControlWidgetButton(action: OpenFolioIntent()) {
                Label("Open Folio", systemImage: "book.closed.fill")
            }
        }
        .displayName("Folio")
        .description("Open your reading library.")
    }
}

@main
struct FolioWidgetBundle: WidgetBundle {
    var body: some Widget {
        FolioListsWidget()
        FolioReadingGoalsWidget()
        FolioControlWidget()
    }
}
