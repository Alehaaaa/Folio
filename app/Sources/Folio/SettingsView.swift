import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Accounts", systemImage: "person.crop.circle") { AccountsSettings() }
            Tab("Reading", systemImage: "textformat.size") { ReadingSettings() }
            Tab("Reminders", systemImage: "bell") { ReadingReminderSettings() }
            Tab("Extensions", systemImage: "puzzlepiece.extension") { ExtensionsSettings() }
        }
        .frame(width: 560, height: 520)
    }
}

struct GeneralSettings: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                HStack(spacing: 15) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(.tint)
                        .frame(width: 52, height: 52)
                        .background(.tint.opacity(0.1), in: .rect(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Make Folio your own").font(.headline)
                        Text("Revisit the welcome tour, import books, and choose your reading routine.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                Button {
                    OnboardingCoordinator.shared.replay()
                    openWindow(id: "onboarding")
                } label: {
                    Label("Show Welcome Tour…", systemImage: "sparkles")
                }
                .buttonStyle(.glass)
                .accessibilityIdentifier("settings.showOnboarding")
            } header: {
                Text("Getting Started")
            }

            Section("About") {
                LabeledContent("App", value: "Folio")
                LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
        }
        .formStyle(.grouped)
    }
}

struct AccountsSettings: View {
    @Environment(HardcoverClient.self) private var hc
    @Environment(GoodreadsClient.self) private var gr
    @Environment(LibraryStore.self) private var store
    @State private var token = ""
    @State private var grField = ""

    var body: some View {
        Form {
            Section {
                if let user = hc.user {
                    HStack(spacing: 12) {
                        AsyncImage(url: user.imageURL) { i in i.resizable().scaledToFill() } placeholder: {
                            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                        }
                        .frame(width: 40, height: 40).clipShape(Circle())
                        VStack(alignment: .leading) {
                            Text(user.name ?? user.username).font(.headline)
                            Text("@\(user.username)").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Disconnect") { hc.disconnect() }
                    }
                } else {
                    SecureField("API token", text: $token, prompt: Text("Paste your Hardcover API token"))
                        .onSubmit { Task { await hc.connect(token: token) } }
                    HStack {
                        Link("Get your token at hardcover.app/account/api", destination: URL(string: "https://hardcover.app/account/api")!)
                            .font(.callout)
                        Spacer()
                        if hc.connecting { ProgressView().controlSize(.small) }
                        Button("Connect") { Task { await hc.connect(token: token) } }
                            .buttonStyle(.glassProminent)
                            .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || hc.connecting)
                    }
                    if let e = hc.lastError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
                }
            } header: {
                Text("Hardcover")
            } footer: {
                Text("Your token is kept in your Mac's keychain and only sent to api.hardcover.app.").font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if gr.isLinked {
                    HStack {
                        Label("Goodreads user \(gr.userID)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        Spacer()
                        Button("Refresh Shelves") { Task { await gr.syncAll(into: store) } }.disabled(!gr.loading.isEmpty)
                        Button("Unlink") { gr.userID = "" }
                    }
                    if let e = gr.lastError { Text(e).font(.callout).foregroundStyle(.red) }
                } else {
                    HStack {
                        TextField("Goodreads profile link or user ID", text: $grField)
                        Button("Link") {
                            let id = GoodreadsClient.normalize(grField)
                            guard !id.isEmpty else { return }
                            gr.userID = id
                            Task { await gr.syncAll(into: store) }
                        }
                        .buttonStyle(.glassProminent)
                    }
                }
            } header: {
                Text("Goodreads")
            } footer: {
                Text("Public shelves are read through PirateReads (api.piratereads.com). Goodreads offers no way to write changes, so use Export in a Goodreads shelf to bring Folio's changes back to Goodreads.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct ReadingSettings: View {
    @Environment(LibraryStore.self) private var store
    var body: some View {
        @Bindable var store = store
        Form {
            Section("Reading Goals") {
                Stepper("Daily goal: \(store.data.goals.dailyMinutes) minutes", value: $store.data.goals.dailyMinutes, in: 1...240)
                Stepper("Yearly goal: \(store.data.goals.booksPerYear) books", value: $store.data.goals.booksPerYear, in: 1...365)
            }
            .onChange(of: store.data.goals) { store.save() }
            Section("Themes & Settings") {
                ThemePanel().frame(maxWidth: .infinity)
            }
        }
        .formStyle(.grouped)
    }
}

struct ReadingReminderSettings: View {
    @State private var reminders = ReadingReminders.shared

    var body: some View {
        Form {
            Section {
                Toggle("Remind me to read", isOn: Binding(
                    get: { reminders.enabled },
                    set: { enabled in Task { await reminders.setEnabled(enabled) } }
                ))
                .disabled(reminders.isUpdating)

                Picker("Repeat", selection: Binding(
                    get: { reminders.frequency },
                    set: { reminders.setFrequency($0) }
                )) {
                    ForEach(ReadingReminders.Frequency.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                DatePicker("Reminder time", selection: Binding(
                    get: { reminders.reminderTime },
                    set: { reminders.setReminderTime($0) }
                ), displayedComponents: .hourAndMinute)

                Toggle("Show reminders while Folio is open", isOn: Binding(
                    get: { reminders.showWhileOpen },
                    set: { reminders.setShowWhileOpen($0) }
                ))
            } header: {
                Text("Reading Reminders")
            } footer: {
                Text("Choose a time and how often you'd like to read. Folio will only request notification permission when you enable reminders.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Status") {
                if reminders.isUpdating {
                    Label("Updating reminders…", systemImage: "clock")
                } else if reminders.authorizationStatus == .denied {
                    Label("Notifications are disabled for Folio in System Settings.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Open Notification Settings") { reminders.openSystemNotificationSettings() }
                } else if reminders.enabled, let next = reminders.nextReminder {
                    Label("Next reminder: \(next.formatted(date: .abbreviated, time: .shortened))", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else if !reminders.enabled {
                    Text("Reminders are off.").foregroundStyle(.secondary)
                }
                if let error = reminders.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .task { await reminders.refreshAuthorization() }
    }
}
