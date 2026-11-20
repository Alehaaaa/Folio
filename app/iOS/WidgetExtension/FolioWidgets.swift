import AppIntents
import SwiftUI
import UIKit
import WidgetKit

// The widget target compiles Sources/Folio/WidgetShared.swift unchanged.
// FolioWidgetStorage resolves to group.app.folio.reader.ios on this platform,
// matching the main app and the extension's App Group entitlements.

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

struct FolioCover: View {
    let book: FolioWidgetBook

    var body: some View {
        Group {
            if let name = book.coverName,
               let url = FolioWidgetStorage.coverURL(for: name),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4).fill(.tint.opacity(0.16))
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.tint)
                }
            }
        }
        .frame(width: 39, height: 55)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.white.opacity(0.13), lineWidth: 0.5))
    }
}

struct FolioBookRow: View {
    let book: FolioWidgetBook
    var compact: Bool = false

    var body: some View {
        Link(destination: URL(string: book.deepLink) ?? URL(string: "folio-reader://library/all")!) {
            HStack(alignment: .center, spacing: 10) {
                FolioCover(book: book)
                VStack(alignment: .leading, spacing: 4) {
                    Text(book.title)
                        .font(compact ? .callout.weight(.semibold) : .subheadline.weight(.semibold))
                        .lineLimit(compact ? 2 : 1)
                    if !book.author.isEmpty {
                        Text(book.author).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let progress = book.progress {
                        HStack(spacing: 6) {
                            ProgressView(value: progress).tint(.accentColor)
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct FolioShelfView: View {
    @Environment(\.widgetFamily) private var family
    let entry: FolioShelfEntry

    private var shown: Int {
        switch family {
        case .systemSmall: 1
        case .systemMedium: 3
        case .systemLarge: 6
        default: 8
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: entry.list.symbol).foregroundStyle(.tint)
                Text(entry.list.name).font(.headline).lineLimit(1)
                Spacer(minLength: 0)
                Text("\(entry.list.count)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }

            if entry.list.books.isEmpty {
                Spacer()
                HStack(spacing: 8) {
                    Image(systemName: "books.vertical").font(.title3).foregroundStyle(.secondary)
                    Text("No books here yet")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            } else {
                ForEach(entry.list.books.prefix(shown)) { book in
                    FolioBookRow(book: book, compact: family == .systemSmall)
                    if (family == .systemLarge || family == .systemExtraLarge)
                        && book.id != entry.list.books.prefix(shown).last?.id {
                        Divider().opacity(0.45)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(family == .systemSmall ? 14 : 17)
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: entry.list.deepLink))
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
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
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

    @ViewBuilder
    var body: some View {
        if family == .accessoryCircular {
            Gauge(value: fraction) {
                Image(systemName: "book.closed.fill")
            } currentValueLabel: {
                Text("\(Int(entry.goals.todayMinutes))")
                    .font(.system(.headline, design: .rounded).monospacedDigit())
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .widgetLabel("Reading Minutes")
            .widgetURL(URL(string: "folio-reader://goals"))
        } else if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 3) {
                Label("Reading Today", systemImage: "book.closed.fill")
                    .font(.headline)
                    .lineLimit(1)
                Text("\(Int(entry.goals.todayMinutes)) / \(entry.goals.dailyGoal) min · \(entry.goals.streak) day streak")
                    .font(.caption)
                    .lineLimit(1)
                ProgressView(value: fraction)
            }
            .widgetURL(URL(string: "folio-reader://goals"))
        } else {
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
}

struct FolioReadingGoalsWidget: Widget {
    let kind = "app.folio.reader.widgets.goals"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: FolioGoalsProvider()) { entry in
            FolioGoalsView(entry: entry)
        }
        .configurationDisplayName("Reading Goals")
        .description("Your daily reading minutes, streak and yearly book goal.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
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

/// iOS 18+ Control Center control to open Folio's reading library.
@available(iOS 18.0, *)
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
