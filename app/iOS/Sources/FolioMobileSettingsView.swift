import SwiftUI

/// Settings: one short list of pages, each holding one subject.
struct FolioMobileSettingsView: View {
    let showImporter: () -> Void

    var body: some View {
        Form {
            Section {
                NavigationLink { FolioMobileSyncServicesView() } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                NavigationLink { FolioMobileReadingSettings() } label: {
                    Label("Reading", systemImage: "textformat.size")
                }
                NavigationLink { FolioMobileLibrarySettings(showImporter: showImporter) } label: {
                    Label("Library", systemImage: "books.vertical")
                }
                NavigationLink { FolioMobileExtensionSettings() } label: {
                    Label("Extensions", systemImage: "puzzlepiece.extension")
                }
                .accessibilityIdentifier("folio.settings.extensions")
                NavigationLink { FolioMobileGoalsSettings() } label: {
                    Label("Goals & Reminders", systemImage: "target")
                }
                NavigationLink { FolioMobileNetworkSettings() } label: {
                    Label("Network", systemImage: "network")
                }
            }
            .folioRow()

            Section("About") {
                LabeledContent(
                    "Version",
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                )
                FolioUpdateRow()
                FolioDebugLogRow()
                Button {
                    UserDefaults.standard.set(false, forKey: "folioIOS.onboardingCompleted")
                } label: {
                    Label("Show Welcome Tour", systemImage: "sparkles")
                }
                .folioFormButton()
            }
            .folioRow()
        }
        .navigationTitle("Settings")
        .folioPageHeader("Settings")
        .folioScreen()
    }
}

/// Settings › Reading: everything about how pages look, in one place.
struct FolioMobileReadingSettings: View {
    @Environment(ReaderPrefsStore.self) private var preferences

    var body: some View {
        Form {
            FolioMobileReadabilitySettings(rowBackground: FolioTheme.surface)

            Section("Appearance") {
                Picker("Appearance", selection: Binding(
                    get: { preferences.appearance },
                    set: { preferences.appearance = $0 }
                )) {
                    ForEach(ReaderAppearance.allCases) { appearance in
                        Label(appearance.label, systemImage: appearance.symbol).tag(appearance)
                    }
                }
                Picker("Theme", selection: Binding(
                    get: { preferences.prefs.theme },
                    set: { preferences.pickTheme($0) }
                )) {
                    ForEach(ReaderTheme.allCases) { theme in
                        Text(theme.label).tag(theme)
                    }
                }
                Stepper(
                    "Text Size: \(preferences.prefs.fontSize) pt",
                    value: Binding(
                        get: { preferences.prefs.fontSizeIndex },
                        set: { preferences.prefs.fontSizeIndex = $0 }
                    ),
                    in: 0...(ReaderPrefs.fontSizes.count - 1)
                )
            }
            .folioRow()

            FolioMobileTypographySections()
        }
        .navigationTitle("Reading")
        .folioPageHeader("Reading")
        .folioScreen()
    }
}

/// Settings › Library: importing, collections, the home nook and book language.
struct FolioMobileLibrarySettings: View {
    @Environment(LibraryStore.self) private var store
    let showImporter: () -> Void
    @AppStorage(BookLanguage.readingLanguageKey) private var bookLanguage = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Imported Books", value: String(store.books.count))
                Button("Import from Files", systemImage: "square.and.arrow.down", action: showImporter)
                    .folioFormButton()
                NavigationLink { FolioMobileCollectionsSettings() } label: {
                    Label("Collections", systemImage: "rectangle.stack")
                }
                NavigationLink { FolioMobileNookSettings() } label: {
                    Label("Home Nook", systemImage: "books.vertical")
                }
            }
            .folioRow()

            Section {
                Picker("Book Language", selection: $bookLanguage) {
                    Text("Automatic (\(BookLanguage.displayName(BookLanguage.preferred)))").tag("")
                    ForEach(BookLanguage.common, id: \.self) { code in
                        Text(BookLanguage.displayName(code)).tag(code)
                    }
                }
            } footer: {
                Text("Book pages show the edition in this language when Hardcover has one. Imported books keep their own language.")
            }
            .folioRow()
        }
        .navigationTitle("Library")
        .folioPageHeader("Library")
        .folioScreen()
    }
}

/// Settings › Goals & Reminders.
struct FolioMobileGoalsSettings: View {
    @Environment(LibraryStore.self) private var store

    var body: some View {
        Form {
            Section("Goals") {
                Stepper(
                    "Daily: \(store.data.goals.dailyMinutes) minutes",
                    value: Binding(
                        get: { store.data.goals.dailyMinutes },
                        set: { store.data.goals.dailyMinutes = $0; store.save() }
                    ),
                    in: 1...240
                )
                Stepper(
                    "Yearly: \(store.data.goals.booksPerYear) books",
                    value: Binding(
                        get: { store.data.goals.booksPerYear },
                        set: { store.data.goals.booksPerYear = $0; store.save() }
                    ),
                    in: 1...365
                )
            }
            .folioRow()
            Section {
                NavigationLink { FolioMobileReminderSettings() } label: {
                    Label("Reading Reminders", systemImage: "bell.badge")
                }
            }
            .folioRow()
        }
        .navigationTitle("Goals & Reminders")
        .folioPageHeader("Goals & Reminders")
        .folioScreen()
    }
}

/// Settings › Network.
struct FolioMobileNetworkSettings: View {
    var body: some View {
        Form { FolioEncryptedDNSSection() }
            .navigationTitle("Network")
            .folioPageHeader("Network")
            .folioScreen()
    }
}

/// Hardcover's token sign-in, shared by Settings and the Sync screen.
struct FolioMobileHardcoverAccountSection: View {
    @Environment(HardcoverClient.self) private var hardcover
    @State private var token = ""

    var body: some View {
        Section("Hardcover Account") {
            if let user = hardcover.user {
                Label(user.name ?? user.username, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(FolioTheme.success)
                Button("Disconnect", role: .destructive) {
                    hardcover.disconnect()
                }
            } else {
                SecureField("Hardcover API token", text: $token)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                Link("Get token at hardcover.app", destination: URL(string: "https://hardcover.app/account/api")!)
                Button {
                    Task {
                        await hardcover.connect(token: token)
                        if hardcover.isConnected { token = "" }
                    }
                } label: {
                    if hardcover.connecting {
                        ProgressView()
                    } else {
                        Label("Connect Hardcover", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                .folioFormButton()
                .disabled(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hardcover.connecting)
                if let error = hardcover.lastError {
                    Text(error).font(.footnote).foregroundStyle(FolioTheme.danger)
                }
            }
        }
        .folioRow()
    }
}

/// Settings › Network: encrypted DNS (DNS over HTTPS) through a chosen provider.
struct FolioEncryptedDNSSection: View {
    @State private var dns = FolioEncryptedDNS.shared

    var body: some View {
        Section {
            Toggle("Encrypted DNS", isOn: $dns.enabled)
                .accessibilityIdentifier("folio.settings.encryptedDNS")
            if dns.enabled {
                Picker("Provider", selection: $dns.provider) {
                    ForEach(FolioEncryptedDNS.Provider.allCases) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("folio.settings.encryptedDNS.provider")
                if dns.provider == .nextdns {
                    TextField("Configuration ID", text: $dns.nextDNSID, prompt: Text("abc123"))
                        .plainEntry()
                        .accessibilityIdentifier("folio.settings.encryptedDNS.nextdns")
                }
                if dns.provider == .custom {
                    TextField("DoH URL", text: $dns.customURL, prompt: Text("https://dns.example/dns-query"))
                        .plainEntry(url: true)
                        .accessibilityIdentifier("folio.settings.encryptedDNS.custom")
                }
                LabeledContent("Status") {
                    Text(statusText)
                        .foregroundStyle(dns.status == .unavailable || dns.status == .needsSetup
                                         ? FolioTheme.caution : FolioTheme.muted)
                }
            }
        } footer: {
            Text("Book details, covers and downloads look up websites over HTTPS with this provider. If it can't be reached, Folio uses your network's DNS.")
        }
        .folioRow()
    }

    private var statusText: String {
        switch dns.status {
        case .off: return "Off"
        case .needsSetup: return dns.provider == .nextdns ? "Enter your ID" : "Enter an https address"
        case .checking: return "Checking…"
        case .unavailable: return "Unreachable, using network DNS"
        case .active: return dns.needsRelaunch ? "Restart Folio to finish" : "On"
        }
    }
}

private extension View {
    func plainEntry(url: Bool = false) -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(url ? .URL : .asciiCapable)
            .multilineTextAlignment(.trailing)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
