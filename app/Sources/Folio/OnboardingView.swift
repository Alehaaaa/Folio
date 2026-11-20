import SwiftUI
import Observation

/// Keeps first-run presentation to one window, even if several main windows are opened.
@Observable
@MainActor
final class OnboardingCoordinator {
    static let shared = OnboardingCoordinator()

    private static let completedKey = "folio.onboarding.completed.v1"
    private var attemptedAutomaticPresentation = false
    var presentationID = UUID()

    var hasCompleted: Bool { UserDefaults.standard.bool(forKey: Self.completedKey) }

    func shouldPresentAutomatically() -> Bool {
        guard !attemptedAutomaticPresentation else { return false }
        let preview = ProcessInfo.processInfo.environment["FOLIO_PREVIEW_ONBOARDING"] == "1"
        guard ScreenshotMode.path == nil || preview else { return false }
        guard !hasCompleted || preview else { return false }
        attemptedAutomaticPresentation = true
        presentationID = UUID()
        return true
    }

    func replay() { presentationID = UUID() }

    func complete() { UserDefaults.standard.set(true, forKey: Self.completedKey) }
}

struct OnboardingView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.colorScheme) private var colorScheme

    @State private var step = ProcessInfo.processInfo.environment["FOLIO_PREVIEW_ONBOARDING"] == "1"
        ? min(2, max(0, Int(ProcessInfo.processInfo.environment["FOLIO_ONBOARDING_STEP"] ?? "0") ?? 0)) : 0
    @State private var importing = false
    @State private var minutes = LibraryStore.shared.data.goals.dailyMinutes
    @State private var remindMe = ReadingReminders.shared.enabled
    @State private var frequency = ReadingReminders.shared.frequency
    @State private var reminderTime = ReadingReminders.shared.reminderTime
    @State private var completing = false
    @State private var notificationError: String?

    private let accent = Color(red: 0.64, green: 0.45, blue: 0.91)

    var body: some View {
        ZStack {
            ambientBackground

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, 34)
                    .padding(.top, 27)

                HStack(spacing: 31) {
                    illustration
                        .frame(width: 326, height: 379)
                    stepContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(height: 379, alignment: .center)
                }
                .padding(.horizontal, 34)
                .frame(maxHeight: .infinity)

                bottomBar
                    .padding(.horizontal, 34)
                    .padding(.bottom, 27)
            }
        }
        .frame(width: 840, height: 568)
        .fileImporter(isPresented: $importing, allowedContentTypes: BookFormat.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.importFiles(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let books = urls.filter { BookFormat.from(url: $0) != nil }
            guard !books.isEmpty else { return false }
            store.importFiles(books)
            return true
        }
        .accessibilityIdentifier("folio.onboarding")
    }

    private var ambientBackground: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack {
            HStack(spacing: 9) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(accent, in: .rect(cornerRadius: 11))
                Text("Folio")
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }

            Spacer()

            HStack(spacing: 6) {
                ForEach(0..<3) { index in
                    Capsule()
                        .fill(index == step ? accent : Color.primary.opacity(0.14))
                        .frame(width: index == step ? 25 : 7, height: 7)
                }
            }
            .animation(.smooth(duration: 0.25), value: step)

            Spacer()

            Button(OnboardingCoordinator.shared.hasCompleted ? "Close" : "Skip setup") {
                close()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.subheadline)
            .frame(width: 85, alignment: .trailing)
            .accessibilityIdentifier("onboarding.skip")
        }
    }

    private var illustration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 33, style: .continuous)
                .fill(.white.opacity(colorScheme == .dark ? 0.03 : 0.16))
                .glassEffect(.regular, in: .rect(cornerRadius: 33))
            RoundedRectangle(cornerRadius: 33, style: .continuous)
                .strokeBorder(.white.opacity(colorScheme == .dark ? 0.12 : 0.65), lineWidth: 0.8)

            Group {
                switch step {
                case 0: welcomeArt
                case 1: libraryArt
                default: habitArt
                }
            }
            .id(step)
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        }
        .clipShape(RoundedRectangle(cornerRadius: 33, style: .continuous))
        .animation(.easeInOut(duration: 0.25), value: step)
        .accessibilityHidden(true)
    }

    private var welcomeArt: some View {
        ZStack {
            OnboardingBookCover(title: "THE ART OF\nSLOW DAYS", subtitle: "A FIELD GUIDE",
                                color: Color(red: 0.20, green: 0.32, blue: 0.44))
                .frame(width: 141, height: 211)
                .rotationEffect(.degrees(-18))
                .offset(x: -54, y: 22)

            OnboardingBookCover(title: "SMALL\nWORLDS", subtitle: "VOLUME ONE",
                                color: Color(red: 0.65, green: 0.35, blue: 0.35))
                .frame(width: 141, height: 211)
                .rotationEffect(.degrees(13))
                .offset(x: 55, y: -14)

            Image(systemName: "sparkle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(accent)
                .offset(x: 113, y: -135)
        }
    }

    private var libraryArt: some View {
        ZStack {
            OnboardingBookCover(title: "A PLACE\nTO BEGIN", subtitle: "YOUR COLLECTION",
                                color: Color(red: 0.15, green: 0.43, blue: 0.43))
                .frame(width: 150, height: 224)
                .rotationEffect(.degrees(-10))
                .offset(x: -40, y: 4)

            RoundedRectangle(cornerRadius: 25, style: .continuous)
                .fill(.ultraThinMaterial)
                .frame(width: 108, height: 108)
                .glassEffect(.regular, in: .rect(cornerRadius: 25))
                .overlay {
                    Image(systemName: "square.and.arrow.down.fill")
                        .font(.system(size: 39, weight: .light))
                        .foregroundStyle(.primary)
                }
                .rotationEffect(.degrees(8))
                .offset(x: 80, y: 72)
        }
    }

    private var habitArt: some View {
        ZStack {
            Circle()
                .stroke(accent.opacity(0.15), lineWidth: 15)
                .frame(width: 216, height: 216)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(accent, style: StrokeStyle(lineWidth: 15, lineCap: .round))
                .frame(width: 216, height: 216)
                .rotationEffect(.degrees(-90))

            VStack(spacing: 8) {
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 35, weight: .light))
                    .foregroundStyle(accent)
                    .padding(.bottom, 3)
                Text("\(minutes)")
                    .font(.system(size: 55, weight: .light, design: .rounded))
                    .contentTransition(.numericText())
                Text("MIN / DAY")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .tracking(2)
                    .foregroundStyle(.secondary)
            }
            .animation(.smooth, value: minutes)
        }
    }

    private var stepContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(step == 0 ? "A NEW CHAPTER" : step == 1 ? "YOUR LIBRARY" : "YOUR RHYTHM")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(accent)
                .padding(.bottom, 13)

            Text(step == 0 ? "A beautiful place\nto get lost in books." : step == 1 ? "Every book,\nin its place." : "A little reading,\nevery day.")
                .font(.system(size: 32, weight: .semibold, design: .rounded))
                .tracking(-0.9)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 12)

            Text(step == 0 ? "Bring your books together, find your next favorite, and enjoy a calmer reading experience." : step == 1 ? "Your EPUBs, PDFs, and documents all belong in a library that feels like home." : "Set a goal that fits your life. A gentle reminder can help you make room for the next chapter.")
                .font(.system(size: 13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
                .padding(.bottom, step == 2 ? 17 : 23)

            switch step {
            case 0: welcomeFeatures
            case 1: importControls
            default: routineControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(step)
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.20), value: step)
    }

    private var welcomeFeatures: some View {
        VStack(alignment: .leading, spacing: 13) {
            feature("books.vertical", "Everything in one place", "Books, PDFs, comics, and more")
            feature("textformat.size", "Made for your eyes", "Beautiful themes, type, and layouts")
            feature("chart.line.uptrend.xyaxis", "Follow your story", "Reading goals and gentle reminders")
        }
    }

    private func feature(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(accent)
                .frame(width: 35, height: 35)
                .background(accent.opacity(0.11), in: .rect(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var importControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { importing = true } label: {
                HStack(spacing: 11) {
                    Image(systemName: "plus.circle.fill").font(.title3)
                    Text("Choose Books…").font(.headline)
                    Spacer()
                    Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                }
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                .padding(16)
                .background(.white.opacity(colorScheme == .dark ? 0.10 : 0.36), in: .rect(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("onboarding.chooseBooks")

            Label(store.books.isEmpty ? "Or drop book files anywhere here" : "\(store.books.count) book\(store.books.count == 1 ? "" : "s") in your library",
                  systemImage: store.books.isEmpty ? "arrow.down.doc" : "checkmark.circle.fill")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)

            Text("You can always add more books later.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    private var routineControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("DAILY READING GOAL")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach([5, 10, 15, 20, 30], id: \.self) { value in
                    Button("\(value)m") { minutes = value }
                        .font(.system(size: 12, weight: minutes == value ? .bold : .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(minutes == value ? accent.opacity(0.20) : Color.primary.opacity(0.055), in: .rect(cornerRadius: 9))
                        .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(minutes == value ? accent.opacity(0.65) : .clear, lineWidth: 1) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(minutes == value ? .isSelected : [])
                }
            }

            Toggle("Remind me to read", isOn: $remindMe)
                .toggleStyle(.switch)
                .font(.subheadline.weight(.medium))
                .padding(.top, 4)
                .accessibilityIdentifier("onboarding.remindMe")

            if remindMe {
                HStack(spacing: 8) {
                    Picker("Repeat", selection: $frequency) {
                        ForEach(ReadingReminders.Frequency.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)

                    DatePicker("At", selection: $reminderTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)
            }

            if let notificationError {
                Text(notificationError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Notifications are optional. You can change this later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            Text("\(step + 1) of 3")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer()

            if step > 0 {
                Button("Back") {
                    withAnimation(.easeInOut(duration: 0.20)) { step -= 1 }
                }
                .buttonStyle(.glass)
                .foregroundColor(colorScheme == .dark ? .white : .primary)
                .background(.white.opacity(colorScheme == .dark ? 0.09 : 0.20), in: .capsule)
                .controlSize(.large)
                .disabled(completing)
                .accessibilityIdentifier("onboarding.back")
            }

            Button {
                if step < 2 {
                    withAnimation(.easeInOut(duration: 0.20)) { step += 1 }
                } else {
                    Task { await finish() }
                }
            } label: {
                HStack(spacing: 8) {
                    if completing { ProgressView().controlSize(.small) }
                    Text(step == 2 ? (notificationError == nil ? "Start Reading" : "Continue without Reminders") : "Continue")
                    if !completing { Image(systemName: "arrow.right") }
                }
                .foregroundStyle(.white)
                .frame(minWidth: 130)
            }
            .buttonStyle(.glassProminent)
            .tint(accent)
            .foregroundStyle(.white)
            .background(accent.opacity(0.75), in: .capsule)
            .controlSize(.large)
            .disabled(completing)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.continue")
        }
    }

    private func finish() async {
        guard !completing else { return }
        completing = true
        store.data.goals.dailyMinutes = minutes
        store.save()

        let reminders = ReadingReminders.shared
        if remindMe && notificationError == nil {
            reminders.setFrequency(frequency)
            reminders.setReminderTime(reminderTime)
            await reminders.setEnabled(true)
            if !reminders.enabled {
                notificationError = reminders.errorMessage ?? "Notifications are disabled. You can enable them later in System Settings."
                completing = false
                return
            }
        } else if !remindMe || notificationError != nil {
            await reminders.setEnabled(false)
        }
        close()
    }

    private func close() {
        OnboardingCoordinator.shared.complete()
        dismissWindow(id: "onboarding")
    }
}

private struct OnboardingBookCover: View {
    let title: String
    let subtitle: String
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color)
            .overlay(alignment: .leading) {
                Rectangle().fill(.black.opacity(0.23)).frame(width: 9)
                    .blur(radius: 3)
                    .padding(.leading, 3)
            }
            .overlay {
                VStack(alignment: .leading, spacing: 0) {
                    Text(subtitle)
                        .font(.system(size: 8, weight: .medium, design: .serif))
                        .tracking(2)
                        .padding(.bottom, 17)
                    Text(title)
                        .font(.system(size: 20, weight: .semibold, design: .serif))
                        .lineSpacing(3)
                    Spacer()
                    Rectangle().fill(.white.opacity(0.7)).frame(width: 34, height: 1)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(18)
            }
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.15), lineWidth: 0.7) }
            .shadow(color: .black.opacity(0.28), radius: 15, x: 0, y: 13)
    }
}
