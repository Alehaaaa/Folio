import Charts
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Goal rings

/// The three reading goals and how far along each is, shared by Home's rings and
/// the Reading page.
@MainActor
struct FolioReadingGoals {
    let todayMinutes: Double
    let dailyGoal: Int
    let daysThisWeek: Int
    let booksThisYear: Int
    let yearlyGoal: Int

    init(_ store: LibraryStore) {
        todayMinutes = store.todayMinutes
        dailyGoal = max(1, store.data.goals.dailyMinutes)
        let goalSeconds = Double(dailyGoal) * 60
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weekStart = cal.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        var days = 0
        var day = weekStart
        while day <= today {
            if (store.data.secondsByDay[day.dayKey] ?? 0) >= goalSeconds { days += 1 }
            guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        daysThisWeek = days
        booksThisYear = store.finishedThisYear
        yearlyGoal = max(1, store.data.goals.booksPerYear)
    }

    var minutesFraction: Double { todayMinutes / Double(dailyGoal) }
    var weekFraction: Double { Double(daysThisWeek) / 7 }
    var yearFraction: Double { Double(booksThisYear) / Double(yearlyGoal) }
}

/// Ring colors are tones of the app's own ink: cream (dark ink on light paper) for
/// minutes, olive for the week and wood for the year, so the rings sit in the header
/// like the type does. Each ring is also labeled on the Reading page.
enum FolioRingColors {
    static let minutes = tone(light: 0x29352B, dark: 0xE9E6D9)
    static let week = tone(light: 0x6F8059, dark: 0xB4C39C)
    static let year = tone(light: 0xA9825C, dark: 0xC9A27A)
    /// The empty part of every ring: the hairline color, a little stronger.
    static let track = tone(light: 0xE2E1D6, dark: 0x2C332B)

    private static func tone(light: UInt32, dark: UInt32) -> Color {
        Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// One radial progress bar: a faint track and a rounded arc from the top.
/// Past a full turn the arc keeps going, as Apple Watch rings do.
struct FolioRadialBar: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat

    @State private var shown = 0.0

    var body: some View {
        let value = max(0, shown)
        ZStack {
            Circle().stroke(FolioRingColors.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(1, value))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if value > 1 {
                Circle()
                    .trim(from: 0, to: min(1, value - 1))
                    .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: .black.opacity(0.25), radius: lineWidth / 4)
            }
        }
        .padding(lineWidth / 2)
        .accessibilityHidden(true)
        // Rings fill from empty when they appear, and glide to new values.
        .onAppear { withAnimation(.spring(duration: 0.9, bounce: 0.15).delay(0.1)) { shown = fraction } }
        .onChange(of: fraction) { _, new in withAnimation(.spring(duration: 0.6)) { shown = new } }
    }
}

/// Daily minutes outside, days this week in the middle, books this year inside.
struct FolioGoalRings: View {
    let goals: FolioReadingGoals
    var lineWidth: CGFloat
    var gap: CGFloat

    var body: some View {
        ZStack {
            FolioRadialBar(fraction: goals.minutesFraction, color: FolioRingColors.minutes, lineWidth: lineWidth)
            FolioRadialBar(fraction: goals.weekFraction, color: FolioRingColors.week, lineWidth: lineWidth)
                .padding(lineWidth + gap)
            FolioRadialBar(fraction: goals.yearFraction, color: FolioRingColors.year, lineWidth: lineWidth)
                .padding((lineWidth + gap) * 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Home's top-bar button: the rings, opening the Reading page.
struct FolioMobileGoalRingsButton: View {
    @Environment(LibraryStore.self) private var store
    let action: () -> Void

    var body: some View {
        let goals = FolioReadingGoals(store)
        Button(action: action) {
            FolioGoalRings(goals: goals, lineWidth: 3.5, gap: 1.5)
                .frame(width: 30, height: 30)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Reading goals")
        .accessibilityValue("\(Int(goals.todayMinutes)) of \(goals.dailyGoal) minutes today, "
                            + "\(goals.daysThisWeek) of 7 days this week, "
                            + "\(goals.booksThisYear) of \(goals.yearlyGoal) books this year")
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
                highlightsLink
                goals
            }
            .padding(20)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Activity")
        .navigationBarTitleDisplayMode(.inline)
        .folioScreen()
    }

    // MARK: Sections

    private var today: some View {
        let goals = FolioReadingGoals(store)
        return VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 24) {
                FolioGoalRings(goals: goals, lineWidth: 14, gap: 3)
                    .frame(width: 150, height: 150)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 14) {
                    ringFigure(FolioRingColors.minutes, "\(Int(goals.todayMinutes.rounded(.down)))/\(goals.dailyGoal) min", "Today")
                    ringFigure(FolioRingColors.week, "\(goals.daysThisWeek)/7 days", "This week")
                    ringFigure(FolioRingColors.year, "\(goals.booksThisYear)/\(goals.yearlyGoal) books", "This year")
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 28) {
                figure("\(store.streak)", store.streak == 1 ? "day streak" : "days streak")
                figure("\(bestStreak)", "best streak")
            }
        }
    }

    private func ringFigure(_ color: Color, _ value: String, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().stroke(color, lineWidth: 3).frame(width: 10, height: 10).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(value)
                    .font(.system(.headline, design: .serif))
                    .foregroundStyle(FolioTheme.ink)
                    .monospacedDigit()
                Text(label)
                    .font(.caption)
                    .foregroundStyle(FolioTheme.muted)
            }
        }
        .accessibilityElement(children: .combine)
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

    private var highlightsLink: some View {
        NavigationLink {
            FolioMobileHighlightsView()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "highlighter")
                    .foregroundStyle(FolioTheme.olive)
                    .frame(width: 24)
                Text("Highlights")
                    .foregroundStyle(FolioTheme.ink)
                Spacer(minLength: 0)
                Text("\(FolioHighlights.all().count)")
                    .foregroundStyle(FolioTheme.muted)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(FolioTheme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
            .folioCard(cornerRadius: FolioTheme.panelRadius)
        }
        .buttonStyle(.plain)
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
            .folioCard(cornerRadius: FolioTheme.panelRadius)
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
