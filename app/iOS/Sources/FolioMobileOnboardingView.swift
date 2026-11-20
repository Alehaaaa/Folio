import SwiftUI

/// The iOS welcome flow carries over the macOS intent: import a book, choose
/// reading goals and opt into reminders before opening the regular library.
struct FolioMobileOnboardingView: View {
    let finished: () -> Void
    let importBooks: () -> Void

    @Environment(LibraryStore.self) private var library
    @State private var reminders = ReadingReminders.shared
    @State private var page = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack(spacing: 7) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(index <= page ? Color.accentColor : Color.secondary.opacity(0.2))
                            .frame(maxWidth: .infinity)
                            .frame(height: 5)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 14)

                TabView(selection: $page) {
                    pageBody(
                        symbol: "books.vertical.fill",
                        headline: "A little reading, every day.",
                        description: "Bring your books, highlights, reading goals and discovery sources together in Folio."
                    ) {
                        Label("EPUB • PDF • Comics • Documents", systemImage: "checkmark.seal")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .tag(0)

                    pageBody(
                        symbol: "chart.line.uptrend.xyaxis",
                        headline: "Make reading a habit.",
                        description: "Set a target that suits your day. Folio tracks active reading time and your progress."
                    ) {
                        VStack(spacing: 14) {
                            Stepper(
                                "Daily: \(library.data.goals.dailyMinutes) min",
                                value: Binding(
                                    get: { library.data.goals.dailyMinutes },
                                    set: { library.data.goals.dailyMinutes = $0; library.save() }
                                ), in: 1...240
                            )
                            Stepper(
                                "Books this year: \(library.data.goals.booksPerYear)",
                                value: Binding(
                                    get: { library.data.goals.booksPerYear },
                                    set: { library.data.goals.booksPerYear = $0; library.save() }
                                ), in: 1...365
                            )
                        }
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .tag(1)

                    pageBody(
                        symbol: "bell.badge.fill",
                        headline: "Time for your next chapter.",
                        description: "Optional reading reminders keep your schedule flexible. You can change their frequency at any time."
                    ) {
                        VStack(spacing: 12) {
                            Toggle("Remind me to read", isOn: Binding(
                                get: { reminders.enabled },
                                set: { value in Task { await reminders.setEnabled(value) } }
                            ))
                            Picker("Repeat", selection: Binding(
                                get: { reminders.frequency },
                                set: { reminders.setFrequency($0) }
                            )) {
                                ForEach(ReadingReminders.Frequency.allCases) { frequency in
                                    Text(frequency.title).tag(frequency)
                                }
                            }
                            DatePicker("Reminder time", selection: Binding(
                                get: { reminders.reminderTime },
                                set: { reminders.setReminderTime($0) }
                            ), displayedComponents: .hourAndMinute)
                            if let error = reminders.errorMessage {
                                Text(error).font(.footnote).foregroundStyle(.red)
                            }
                        }
                        .padding(18)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .tag(2)

                    pageBody(
                        symbol: "square.and.arrow.down.fill",
                        headline: "Your library starts here.",
                        description: "Import your own books from Files. Add catalogue metadata and search connected sources later."
                    ) {
                        FolioGlassButton(title: "Import Your First Book",
                                         systemImage: "plus",
                                         prominent: true,
                                         fullWidth: true) {
                            importBooks()
                        }
                    }
                    .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                HStack(spacing: 12) {
                    Button(page == 3 ? "Skip Import" : "Skip Tour") { finished() }
                        .folioGlassPill()
                    Spacer()
                    Button {
                        if page < 3 { withAnimation(.snappy) { page += 1 } }
                        else { finished() }
                    } label: {
                        Label(page == 3 ? "Open Folio" : "Continue",
                              systemImage: page == 3 ? "checkmark" : "arrow.right")
                            .font(.headline)
                            .frame(minWidth: 128, minHeight: 42)
                    }
                    .folioGlassPill(prominent: true)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 26)
            }
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
            .navigationTitle("Welcome to Folio")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled()
    }

    private func pageBody<Extra: View>(
        symbol: String,
        headline: String,
        description: String,
        @ViewBuilder extra: () -> Extra
    ) -> some View {
        ScrollView {
            VStack(spacing: 22) {
                Image(systemName: symbol)
                    .font(.system(size: 72, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 152, height: 152)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 38))
                    .padding(.top, 55)
                Text(headline)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                extra()
                    .frame(maxWidth: 400)
                    .padding(.top, 16)
            }
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }
}
