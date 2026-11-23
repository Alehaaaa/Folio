import Charts
import SwiftUI

// MARK: - Home strip

/// Today's reading against the daily goal: a small ring and one line, as in
/// Apple Books' reading goals. Opens the reading activity page.
struct FolioMobileReadingGoalStrip: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        let goal = max(1, store.data.goals.dailyMinutes)
        let today = store.todayMinutes
        NavigationLink {
            FolioMobileReadingActivity()
        } label: {
            HStack(spacing: 12) {
                FolioGoalRing(fraction: today / Double(goal), lineWidth: 4)
                    .frame(width: 28, height: 28)
                Text(Self.line(today: today, goal: goal, streak: store.streak))
                    .font(.subheadline)
                    .foregroundStyle(FolioTheme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FolioTheme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
            .folioCard(cornerRadius: 18)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows your reading activity")
    }

    static func line(today: Double, goal: Int, streak: Int) -> String {
        let minutes = Int(today.rounded(.down))
        var text = minutes >= goal ? "Daily goal reached" : "\(minutes) of \(goal) min today"
        if streak > 1 { text += " · \(streak)-day streak" }
        return text
    }
}

/// A thin progress ring in the theme's olive.
struct FolioGoalRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 4

    var body: some View {
        ZStack {
            Circle().stroke(FolioTheme.line, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(FolioTheme.olive, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Reading activity

/// Time read today and this week, streaks, the yearly books goal and the
/// books finished this year. Everything comes from the library on this device.
struct FolioMobileReadingActivity: View {
    @Environment(LibraryStore.self) private var store
    @State private var selectedDay: Date?

    private struct Day: Identifiable {
        let date: Date
        let minutes: Double
        var id: Date { date }
    }

    private static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private var goal: Int { max(1, store.data.goals.dailyMinutes) }

    private var week: [Day] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<7).reversed().compactMap { ago in
            guard let day = cal.date(byAdding: .day, value: -ago, to: today) else { return nil }
            let seconds = store.data.secondsByDay[Self.keyFormat.string(from: day)] ?? 0
            return Day(date: day, minutes: seconds / 60)
        }
    }

    /// The longest run of days that met today's goal.
    private var bestStreak: Int {
        let goalSeconds = Double(goal) * 60
        let days = store.data.secondsByDay
            .filter { $0.value >= goalSeconds }
            .compactMap { Self.keyFormat.date(from: $0.key) }
            .map { Calendar.current.startOfDay(for: $0) }
            .sorted()
        var best = 0
        var run = 0
        var previous: Date?
        for day in days {
            if let previous, Calendar.current.dateComponents([.day], from: previous, to: day).day == 1 {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return max(best, store.streak)
    }

    private var hoursThisYear: Double {
        let year = String(Calendar.current.component(.year, from: Date()))
        return store.data.secondsByDay.filter { $0.key.hasPrefix(year) }.values.reduce(0, +) / 3600
    }

    private var finishedThisYear: [LocalBook] {
        let year = Calendar.current.component(.year, from: Date())
        return store.books
            .filter { $0.status == .finished && $0.finishedAt.map { Calendar.current.component(.year, from: $0) == year } == true }
            .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                today
                thisWeek
                thisYear
                goals
            }
            .padding(20)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
        .folioScreen()
    }

    // MARK: Sections

    private var today: some View {
        let minutes = store.todayMinutes
        return HStack(spacing: 22) {
            ZStack {
                FolioGoalRing(fraction: minutes / Double(goal), lineWidth: 10)
                VStack(spacing: 0) {
                    Text("\(Int(minutes.rounded(.down)))")
                        .font(.system(size: 34, weight: .regular, design: .serif))
                        .foregroundStyle(FolioTheme.ink)
                        .monospacedDigit()
                    Text("of \(goal) min")
                        .font(.caption)
                        .foregroundStyle(FolioTheme.muted)
                }
            }
            .frame(width: 128, height: 128)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Today, \(Int(minutes.rounded(.down))) of \(goal) minutes")

            VStack(alignment: .leading, spacing: 16) {
                figure("\(store.streak)", store.streak == 1 ? "day streak" : "days streak")
                figure("\(bestStreak)", "best streak")
            }
            Spacer(minLength: 0)
        }
    }

    private var thisWeek: some View {
        let days = week
        let top = max(Double(goal) * 1.25, days.map(\.minutes).max() ?? 0)
        let selected = selectedDay.flatMap { date in
            days.first { Calendar.current.isDate($0.date, inSameDayAs: date) }
        }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                heading("This Week")
                Spacer()
                Text(selected.map { "\($0.date.formatted(.dateTime.weekday(.wide))): \(Int($0.minutes.rounded())) min" }
                     ?? "\(Int(days.map(\.minutes).reduce(0, +).rounded())) min")
                    .font(.subheadline)
                    .foregroundStyle(FolioTheme.muted)
                    .monospacedDigit()
            }
            Chart {
                ForEach(days) { day in
                    BarMark(
                        x: .value("Day", day.date, unit: .day),
                        y: .value("Minutes", day.minutes),
                        width: .ratio(0.5)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(FolioTheme.olive.opacity(selected == nil || selected?.id == day.id ? 1 : 0.35))
                }
                RuleMark(y: .value("Goal", goal))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(FolioTheme.muted)
                    .annotation(position: .top, alignment: .leading) {
                        Text("Goal")
                            .font(.caption2)
                            .foregroundStyle(FolioTheme.muted)
                    }
            }
            .chartYScale(domain: 0...top)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                        .foregroundStyle(FolioTheme.muted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(FolioTheme.line)
                    AxisValueLabel().foregroundStyle(FolioTheme.muted)
                }
            }
            .chartXSelection(value: $selectedDay)
            .frame(height: 170)
        }
    }

    private var thisYear: some View {
        let finished = finishedThisYear
        let count = store.finishedThisYear
        let target = max(1, store.data.goals.booksPerYear)
        return VStack(alignment: .leading, spacing: 14) {
            heading(String(Calendar.current.component(.year, from: Date())))
            HStack(spacing: 28) {
                figure("\(count) of \(target)", "books finished")
                figure(hoursThisYear < 10 ? hoursThisYear.formatted(.number.precision(.fractionLength(1)))
                       : "\(Int(hoursThisYear.rounded()))", "hours read")
            }
            ProgressView(value: min(1, Double(count) / Double(target)))
                .tint(FolioTheme.olive)
            if !finished.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(finished) { book in
                            NavigationLink(value: book.id) {
                                FolioMobileCover(book: book)
                                    .frame(width: 70, height: 100)
                                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                    .shadow(color: .black.opacity(0.12), radius: 4, x: 1, y: 3)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(book.title)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .contentMargins(.horizontal, 20)
                .padding(.horizontal, -20)
            }
        }
    }

    private var goals: some View {
        VStack(alignment: .leading, spacing: 10) {
            heading("Goals")
            VStack(spacing: 0) {
                Stepper("Daily: \(store.data.goals.dailyMinutes) min", value: Binding(
                    get: { store.data.goals.dailyMinutes },
                    set: { store.data.goals.dailyMinutes = $0; store.save() }
                ), in: 1...240)
                .padding(.vertical, 10)
                Divider().overlay(FolioTheme.line)
                Stepper("Yearly: \(store.data.goals.booksPerYear) books", value: Binding(
                    get: { store.data.goals.booksPerYear },
                    set: { store.data.goals.booksPerYear = $0; store.save() }
                ), in: 1...365)
                .padding(.vertical, 10)
            }
            .padding(.horizontal, 16)
            .folioCard(cornerRadius: 18)
        }
    }

    // MARK: Pieces

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.folioDisplay(.title2))
            .foregroundStyle(FolioTheme.ink)
            .accessibilityAddTraits(.isHeader)
    }

    private func figure(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title2, design: .serif))
                .foregroundStyle(FolioTheme.ink)
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(FolioTheme.muted)
        }
        .accessibilityElement(children: .combine)
    }
}
