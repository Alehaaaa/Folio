import SwiftUI
import UniformTypeIdentifiers

/// The same service configuration, reminder cadence and reader options as
/// Folio on macOS, presented with native iPhone and iPad navigation.
struct FolioMobileMoreSettings: View {
    var body: some View {
        Section("Accounts & Library") {
            NavigationLink {
                FolioMobileGoodreadsSettings()
            } label: {
                Label("Goodreads Shelves", systemImage: "books.vertical.circle")
            }
            NavigationLink {
                FolioMobileCollectionsSettings()
            } label: {
                Label("Manage Collections", systemImage: "rectangle.stack")
            }
        }
        .folioRow()
        Section("Personalise Folio") {
            NavigationLink {
                FolioMobileNookSettings()
            } label: {
                Label("Home Nook", systemImage: "books.vertical")
            }
            NavigationLink {
                FolioMobileReaderAdvancedSettings()
            } label: {
                Label("Typography & Reading Layout", systemImage: "textformat.size")
            }
            NavigationLink {
                FolioMobileReminderSettings()
            } label: {
                Label("Reading Reminders", systemImage: "bell.badge")
            }
        }
        .folioRow()
        Section("Sources") {
            NavigationLink {
                FolioMobileExtensionSettings()
            } label: {
                Label("Manage Source Extensions", systemImage: "puzzlepiece.extension")
            }
        }
        .folioRow()
    }
}

struct FolioMobileGoodreadsSettings: View {
    @Environment(LibraryStore.self) private var library
    @Environment(HardcoverClient.self) private var hardcover
    @State private var goodreads = GoodreadsClient.shared
    @State private var profile = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var exportFile: FolioMobileCSVDocument?
    @State private var notice: String?
    @State private var copying = false

    var body: some View {
        Form {
            Section {
                if goodreads.isLinked {
                    Label("Linked Goodreads profile \(goodreads.userID)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(FolioTheme.success)
                    HStack {
                        Button("Refresh Shelves") { Task { await goodreads.syncAll(into: library) } }
                        Button("Unlink", role: .destructive) { goodreads.userID = "" }
                    }
                    .folioGlassPill()
                    .disabled(!goodreads.loading.isEmpty)
                } else {
                    TextField("Goodreads user ID or profile URL", text: $profile)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button {
                        let id = GoodreadsClient.normalize(profile)
                        guard !id.isEmpty else { return }
                        goodreads.userID = id
                        Task { await goodreads.syncAll(into: library) }
                    } label: { Label("Link Goodreads", systemImage: "link") }
                        .folioGlassPill(prominent: true)
                        .disabled(profile.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let date = goodreads.lastSync {
                    LabeledContent("Last Sync", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                if let error = goodreads.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(FolioTheme.danger)
                }
            } header: {
                Text("Goodreads Account")
            } footer: {
                Text("Public Goodreads shelves are read through PirateReads. Goodreads does not allow Folio to publish changes directly.")
            }
            .folioRow()
            Section("Import & Export") {
                Button { importing = true } label: {
                    Label("Import Goodreads CSV", systemImage: "square.and.arrow.down")
                }
                Button {
                    Task {
                        let csv = await exportCSV()
                        exportFile = FolioMobileCSVDocument(text: csv)
                        exporting = true
                    }
                } label: {
                    Label("Export Library for Goodreads", systemImage: "square.and.arrow.up")
                }
            }
            .folioRow()
            Section {
                if let copy = library.hardcoverCopy {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(copy.done), total: Double(max(copy.total, 1)))
                        Text(copy.stage == "Copying" ? "Copying \(copy.done) of \(copy.total)" : "\(copy.stage)…")
                            .font(.subheadline)
                        if copy.done > 0 {
                            Text("\(copy.sent) on Hardcover\(copy.missed > 0 ? ", \(copy.missed) not found" : "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } else {
                    let waiting = library.data.tracked.filter { !$0.sentToHardcover }.count
                    Button {
                        Task {
                            let result = await library.sendTrackedToHardcover(hardcover)
                            notice = "Copied \(result.sent) books to Hardcover; \(result.missed) could not be matched."
                        }
                    } label: {
                        Label(waiting > 0 ? "Copy \(waiting) Goodreads Books to Hardcover" : "All Goodreads Books Are on Hardcover",
                              systemImage: "arrow.up.forward.app")
                    }
                    .disabled(waiting == 0 || !hardcover.isConnected)
                }
            } header: {
                Text("Sync to Hardcover")
            } footer: {
                Text("Keeps going if you leave this screen. Books already on Hardcover with the same shelf are skipped.")
            }
            .folioRow()
        }
        .navigationTitle("Goodreads")
        .folioScreen()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
            if case .success(let file) = result {
                library.importGoodreads(file)
                notice = library.goodreadsMessage ?? library.lastError
            } else if case .failure(let error) = result {
                notice = error.localizedDescription
            }
        }
        .fileExporter(isPresented: $exporting,
                      document: exportFile, contentType: .commaSeparatedText,
                      defaultFilename: "folio_goodreads_import.csv") { result in
            if case .failure(let error) = result { notice = error.localizedDescription }
        }
        .alert("Goodreads", isPresented: Binding(
            get: { notice != nil }, set: { if !$0 { notice = nil } }
        )) {
            Button("OK") { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func exportCSV() async -> String {
        var rows: [GoodreadsCSV.ExportRow] = []
        var seen = Set<String>()
        if hardcover.isConnected, let all = try? await hardcover.allUserBooks() {
            for item in all {
                guard let status = item.status else { continue }
                seen.insert(BookMatch.key(author: item.book.authors, title: item.book.title))
                rows.append(.init(title: item.book.title, author: item.book.authors,
                                  isbn13: nil, rating: Int((item.rating ?? 0).rounded()),
                                  pages: item.book.pages, year: item.book.year,
                                  dateRead: item.finishedAt, dateAdded: item.dateAdded,
                                  shelf: GoodreadsCSV.shelf(for: status)))
            }
        }
        for book in library.books where book.status != .none {
            let key = BookMatch.key(author: book.author, title: book.title)
            guard seen.insert(key).inserted else { continue }
            rows.append(.init(title: book.title, author: book.author, isbn13: book.isbn,
                              rating: 0, pages: book.hardcoverPages, year: book.publishedYear,
                              dateRead: book.finishedAt?.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                              dateAdded: book.addedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash)),
                              shelf: GoodreadsCSV.shelf(for: book.status.hardcover ?? .wantToRead)))
        }
        for book in library.data.tracked {
            let key = BookMatch.key(author: book.author, title: book.title)
            guard seen.insert(key).inserted else { continue }
            rows.append(.init(title: book.title, author: book.author, isbn13: book.isbn13,
                              rating: book.rating, pages: book.pages, year: book.year,
                              dateRead: book.dateRead, dateAdded: book.dateAdded,
                              shelf: book.shelf))
        }
        return GoodreadsCSV.write(rows)
    }
}

struct FolioMobileCSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText, .plainText] }
    static var writableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct FolioMobileCollectionsSettings: View {
    @Environment(LibraryStore.self) private var library
    @State private var newName = ""
    @State private var editing: UUID?
    @State private var editingName = ""

    var body: some View {
        Form {
            Section("Create Collection") {
                HStack {
                    TextField("Collection name", text: $newName)
                    Button("Create") {
                        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !name.isEmpty else { return }
                        _ = library.addCollection(name)
                        newName = ""
                    }
                    .folioGlassPill(prominent: true)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .folioRow()
            Section("Your Collections") {
                ForEach(library.data.collections) { collection in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(collection.name).font(.headline)
                            Text("\(library.books(in: collection.id).count) books")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rename", systemImage: "pencil") {
                            editing = collection.id
                            editingName = collection.name
                        }
                        .labelStyle(.iconOnly)
                        .folioGlassPill()
                    }
                }
                .onDelete { offsets in
                    let ids = offsets.compactMap { library.data.collections.indices.contains($0) ? library.data.collections[$0].id : nil }
                    for id in ids { library.deleteCollection(id) }
                }
            }
            .folioRow()
        }
        .navigationTitle("Collections")
        .folioScreen()
        .alert("Rename Collection", isPresented: Binding(
            get: { editing != nil }, set: { if !$0 { editing = nil } }
        )) {
            TextField("Collection name", text: $editingName)
            Button("Cancel", role: .cancel) { editing = nil }
            Button("Save") {
                if let editing, !editingName.trimmingCharacters(in: .whitespaces).isEmpty {
                    library.renameCollection(editing, editingName.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                editing = nil
            }
        }
    }
}

struct FolioMobileReminderSettings: View {
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
                    get: { reminders.frequency }, set: { reminders.setFrequency($0) }
                )) {
                    ForEach(ReadingReminders.Frequency.allCases) { interval in
                        Text(interval.title).tag(interval)
                    }
                }
                DatePicker("Reminder Time", selection: Binding(
                    get: { reminders.reminderTime }, set: { reminders.setReminderTime($0) }
                ), displayedComponents: .hourAndMinute)
                Toggle("Show reminders while Folio is open", isOn: Binding(
                    get: { reminders.showWhileOpen }, set: { reminders.setShowWhileOpen($0) }
                ))
            } header: {
                Text("Daily Reading")
            } footer: {
                Text("Notifications are requested only when you enable reminders.")
            }
            .folioRow()
            Section("Notification Status") {
                if reminders.isUpdating { ProgressView("Updating reminders…") }
                else if reminders.authorizationStatus == .denied {
                    Label("Notifications are disabled in Settings", systemImage: "exclamationmark.triangle")
                    Button("Open Settings") { reminders.openSystemNotificationSettings() }
                        .folioGlassPill()
                } else if reminders.enabled, let next = reminders.nextReminder {
                    Label("Next reminder: \(next.formatted(date: .abbreviated, time: .shortened))",
                          systemImage: "checkmark.circle")
                } else {
                    Text("Reminders are off").foregroundStyle(.secondary)
                }
                if let error = reminders.errorMessage {
                    Text(error).font(.footnote).foregroundStyle(FolioTheme.danger)
                }
            }
            .folioRow()
        }
        .navigationTitle("Reading Reminders")
        .folioScreen()
        .task { await reminders.refreshAuthorization() }
    }
}

struct FolioMobileReaderAdvancedSettings: View {
    @Environment(ReaderPrefsStore.self) private var reader

    var body: some View {
        Form {
            Section("Typeface") {
                Picker("Font", selection: Binding(
                    get: { reader.prefs.font },
                    set: { reader.prefs.font = $0 }
                )) {
                    ForEach(ReaderFont.allCases) { font in Text(font.label).tag(font) }
                }
                Toggle("Bold Text", isOn: Binding(
                    get: { reader.prefs.boldText },
                    set: { reader.prefs.boldText = $0 }
                ))
            }
            .folioRow()
            Section("Page Layout") {
                Picker("Reading Mode", selection: Binding(
                    get: { reader.prefs.navigation },
                    set: { reader.prefs.navigation = $0 }
                )) {
                    ForEach(PageNavigation.allCases) { mode in Text(mode.label).tag(mode) }
                }
                Toggle("Justify Paragraphs", isOn: Binding(
                    get: { reader.prefs.justify },
                    set: { reader.prefs.justify = $0 }
                ))
                Toggle("Use Multiple Columns on iPad", isOn: Binding(
                    get: { reader.prefs.multipleColumns },
                    set: { reader.prefs.multipleColumns = $0 }
                ))
            }
            .folioRow()
            Section("Spacing") {
                Toggle("Custom Line Spacing", isOn: Binding(
                    get: { reader.prefs.customLineSpacing },
                    set: { reader.prefs.customLineSpacing = $0 }
                ))
                if reader.prefs.customLineSpacing {
                    LabeledContent("Line Height", value: reader.prefs.lineSpacing.formatted(.number.precision(.fractionLength(1))))
                    Slider(value: Binding(
                        get: { reader.prefs.lineSpacing },
                        set: { reader.prefs.lineSpacing = $0 }
                    ), in: 1.0...2.5, step: 0.1)
                }
                Toggle("Custom Letter Spacing", isOn: Binding(
                    get: { reader.prefs.customCharacterSpacing },
                    set: { reader.prefs.customCharacterSpacing = $0 }
                ))
                if reader.prefs.customCharacterSpacing {
                    Slider(value: Binding(
                        get: { reader.prefs.characterSpacing },
                        set: { reader.prefs.characterSpacing = $0 }
                    ), in: 0...0.2, step: 0.01)
                }
                Toggle("Custom Word Spacing", isOn: Binding(
                    get: { reader.prefs.customWordSpacing },
                    set: { reader.prefs.customWordSpacing = $0 }
                ))
                if reader.prefs.customWordSpacing {
                    Slider(value: Binding(
                        get: { reader.prefs.wordSpacing },
                        set: { reader.prefs.wordSpacing = $0 }
                    ), in: 0...0.5, step: 0.01)
                }
                Toggle("Custom Page Margins", isOn: Binding(
                    get: { reader.prefs.customMargins },
                    set: { reader.prefs.customMargins = $0 }
                ))
                if reader.prefs.customMargins {
                    Slider(value: Binding(
                        get: { reader.prefs.margins },
                        set: { reader.prefs.margins = $0 }
                    ), in: 8...100, step: 4)
                }
            }
            .folioRow()
        }
        .navigationTitle("Typography & Layout")
        .folioScreen()
    }
}

struct FolioMobileExtensionSettings: View {
    @Environment(ExtensionStore.self) private var extensions
    @State private var importing = false
    @State private var newHost: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(extensions.installed) { ext in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Image(systemName: "puzzlepiece.extension.fill")
                            VStack(alignment: .leading) {
                                Text(ext.manifest.name).font(.headline)
                                Text("Version \(ext.manifest.version)")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(
                                get: { ext.saved.enabled },
                                set: { enabled in extensions.update(ext.id) { $0.enabled = enabled } }
                            )).labelsHidden()
                        }
                        Text(ext.manifest.description)
                            .font(.footnote).foregroundStyle(.secondary)
                        ForEach(ext.manifest.settings.filter { $0.kind == "list" }, id: \.key) { setting in
                            hostEditor(ext, setting: setting)
                        }
                        let hosts = extensions.reach(ext).sorted()
                        Text(hosts.isEmpty ? "No permitted servers" : "Permitted: \(hosts.joined(separator: ", "))")
                            .font(.caption2).foregroundStyle(.tertiary)
                        if !ext.saved.builtIn {
                            Button("Remove Extension", role: .destructive) { extensions.remove(ext.id) }
                                .folioGlassPill()
                        }
                    }
                    .padding(.vertical, 6)
                }
                if let error = extensions.lastError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(FolioTheme.danger)
                }
            } header: {
                Text("Installed Extensions")
            } footer: {
                Text("JavaScript sources run in isolated engines and can access only approved servers. Updates to bundled extensions arrive with Folio builds.")
            }
            .folioRow()
            Section {
                Button { importing = true } label: {
                    Label("Add Extension from File", systemImage: "plus")
                }
                .folioGlassPill(prominent: true)
            }
            .folioRow()
        }
        .navigationTitle("Source Extensions")
        .folioScreen()
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, UTType(filenameExtension: "js") ?? .javaScript]) { result in
            if case .success(let url) = result { Task { await extensions.install(from: url) } }
        }
    }

    @ViewBuilder
    private func hostEditor(_ ext: ExtensionStore.Installed, setting: SourceSetting) -> some View {
        let key = "\(ext.id).\(setting.key)"
        let values = ext.saved.config[setting.key] ?? []
        VStack(alignment: .leading, spacing: 5) {
            Text(setting.label).font(.caption.weight(.semibold))
            ForEach(values, id: \.self) { host in
                HStack {
                    Text(host).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button(role: .destructive) {
                        extensions.update(ext.id) { $0.config[setting.key] = values.filter { $0 != host } }
                    } label: {
                        Image(systemName: "minus.circle")
                    }.folioGlassPill()
                }
            }
            HStack {
                TextField(setting.placeholder.isEmpty ? "https://" : setting.placeholder,
                          text: Binding(get: { newHost[key] ?? "" }, set: { newHost[key] = $0 }))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { addHost(ext, setting: setting, field: key) }
                Button("Add") { addHost(ext, setting: setting, field: key) }
                    .folioGlassPill()
            }
        }
    }

    private func addHost(_ ext: ExtensionStore.Installed, setting: SourceSetting, field: String) {
        var value = (newHost[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "http://" + value }
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: value), SourceRuntime.hostKey(url) != nil else { return }
        let previous = ext.saved.config[setting.key] ?? []
        if !previous.contains(value) {
            extensions.update(ext.id) { $0.config[setting.key] = previous + [value] }
        }
        newHost[field] = ""
    }
}

/// How many shelves the Home nook may grow to, and the books hidden from it.
struct FolioMobileNookSettings: View {
    @State private var nook = FolioNookStore.shared
    @State private var resetting = false

    var body: some View {
        Form {
            Section {
                Stepper(nook.maxShelves == 1 ? "1 shelf" : "\(nook.maxShelves) shelves",
                        value: $nook.maxShelves, in: FolioNookStore.shelfRange)
            } header: {
                Text("Shelves")
            } footer: {
                Text("New books go at the end of the nook. When a shelf is full, the next book opens a new one, up to this many.")
            }
            .folioRow()

            Section("Hidden from Nook") {
                if nook.hidden.isEmpty {
                    Text("Books you hide from the nook appear here.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(nook.hidden.sorted { $0.value < $1.value }, id: \.key) { entry in
                        HStack {
                            Text(entry.value).lineLimit(2)
                            Spacer(minLength: 8)
                            Button("Show") { nook.unhide(entry.key) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(FolioTheme.olive)
                        }
                    }
                }
            }
            .folioRow()

            Section {
                Button("Reset Shelf Order", role: .destructive) { resetting = true }
            } footer: {
                Text("Puts books you're reading first and the rest newest first, as on a fresh shelf.")
            }
            .folioRow()
        }
        .navigationTitle("Home Nook")
        .folioScreen()
        .confirmationDialog("Reset the order of your nook?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset Order", role: .destructive) { nook.resetOrder() }
        }
    }
}
