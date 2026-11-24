import SwiftUI

struct FolioMobileSettingsView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(ReaderPrefsStore.self) private var preferences
    let showImporter: () -> Void
    @AppStorage(BookLanguage.readingLanguageKey) private var bookLanguage = ""

    var body: some View {
        Form {
            Section("Library") {
                LabeledContent("Imported Books", value: String(store.books.count))
                Button("Import from Files", systemImage: "square.and.arrow.down", action: showImporter)
                    .folioFormButton()
                Button {
                    UserDefaults.standard.set(false, forKey: "folioIOS.onboardingCompleted")
                } label: {
                    Label("Show Welcome Tour", systemImage: "sparkles")
                }
                .folioFormButton()
            }
            .folioRow()

            FolioMobileHardcoverAccountSection()

            FolioCloudSyncSection()

            Section {
                Picker("Book Language", selection: $bookLanguage) {
                    Text("Automatic (\(BookLanguage.displayName(BookLanguage.preferred)))").tag("")
                    ForEach(BookLanguage.common, id: \.self) { code in
                        Text(BookLanguage.displayName(code)).tag(code)
                    }
                }
            } footer: {
                Text("Book pages show the edition in this language when Hardcover has one: its title, cover and pages. Imported books always use their own language.")
            }
            .folioRow()

            FolioEncryptedDNSSection()

            Section("Reading Goals") {
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

            FolioMobileReadabilitySettings()

            Section("Reading Appearance") {
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
                Toggle("Bold Text", isOn: Binding(
                    get: { preferences.prefs.boldText },
                    set: { preferences.prefs.boldText = $0 }
                ))
            }
            .folioRow()

            FolioMobileMoreSettings()

            Section("About") {
                LabeledContent("App", value: "Folio for iOS")
                LabeledContent(
                    "Version",
                    value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
                )
                FolioUpdateRow()
                FolioDebugLogRow()
            }
            .folioRow()
        }
        .navigationTitle("Settings")
        .folioPageHeader("Settings")
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

/// Settings › Network: encrypted DNS through Cloudflare (1.1.1.1).
struct FolioEncryptedDNSSection: View {
    @State private var dns = FolioEncryptedDNS.shared

    var body: some View {
        Section {
            Toggle(isOn: $dns.enabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Encrypted DNS")
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(dns.status == .unavailable ? FolioTheme.caution : FolioTheme.muted)
                }
            }
            .accessibilityIdentifier("folio.settings.encryptedDNS")
        } header: {
            Text("Network")
        } footer: {
            Text("Looks up websites through Cloudflare's 1.1.1.1 over HTTPS for book details, covers and downloads, instead of your network's DNS. If Cloudflare can't be reached, Folio keeps using your network's DNS.")
        }
        .folioRow()
    }

    private var statusText: String {
        if dns.needsRelaunch { return dns.enabled ? "On · applies fully after Folio restarts" : "Off · applies fully after Folio restarts" }
        return switch dns.status {
        case .off: "Off · using your network's DNS"
        case .checking: "Checking Cloudflare…"
        case .active: "On · Cloudflare 1.1.1.1"
        case .unavailable: "Cloudflare unreachable · using your network's DNS"
        }
    }
}
