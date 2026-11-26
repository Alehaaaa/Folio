import SwiftUI
import UniformTypeIdentifiers

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
        .folioPageHeader("Collections")
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
                        .folioFormButton()
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
        .folioPageHeader("Reading Reminders")
        .folioScreen()
        .task { await reminders.refreshAuthorization() }
    }
}

struct FolioMobileReaderAdvancedSettings: View {
    var body: some View {
        Form { FolioMobileTypographySections() }
            .navigationTitle("Typography & Layout")
            .folioPageHeader("Typography & Layout")
            .folioScreen()
    }
}

/// Font, page layout and spacing: shared by Settings › Reading and the reader.
struct FolioMobileTypographySections: View {
    @Environment(ReaderPrefsStore.self) private var reader

    var body: some View {
        Group {
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
    }
}

/// Settings › Extensions: the download sources, turned on and off, ordered and
/// browsed one at a time.
struct FolioMobileExtensionSettings: View {
    @Environment(ExtensionStore.self) private var extensions
    @State private var importing = false
    @State private var newHost: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    FolioMobileSourcesView()
                } label: {
                    Label("Browse Sources", systemImage: "square.stack.3d.up")
                }
                .disabled(extensions.enabled.isEmpty)
                NavigationLink {
                    FolioSourceOrderEditor()
                } label: {
                    LabeledContent("Download Order") {
                        Text(extensions.enabled.map(\.manifest.name).formatted(.list(type: .and)))
                            .lineLimit(1)
                    }
                }
            } footer: {
                Text("When two sources have the same edition, Folio downloads from the one higher on this list. A source made for one language goes first when you download in that language.")
            }
            .folioRow()
            Section {
                ForEach(extensions.installed) { ext in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Image(systemName: "puzzlepiece.extension.fill")
                                .foregroundStyle(FolioTheme.olive)
                            VStack(alignment: .leading) {
                                Text(ext.manifest.name).font(.headline)
                                // One caption line: the languages follow the version, no icon column.
                                Text("Version \(ext.manifest.version) · \(ext.manifest.languageLabel)")
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
                .folioFormButton()
            }
            .folioRow()
        }
        .navigationTitle("Extensions")
        .folioPageHeader("Extensions")
        .folioScreen()
        .task { await extensions.ensureLoaded() }
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
        .folioPageHeader("Home Nook")
        .folioScreen()
        .confirmationDialog("Reset the order of your nook?", isPresented: $resetting, titleVisibility: .visible) {
            Button("Reset Order", role: .destructive) { nook.resetOrder() }
        }
    }
}

/// The order Folio prefers download sources in, reordered with the system's
/// own drag handles, in the same cream grouped style as Settings.
struct FolioSourceOrderEditor: View {
    @Environment(ExtensionStore.self) private var extensions
    @State private var order: [String] = ExtensionStore.shared.downloadSources.map(\.id)

    var body: some View {
        List {
            Section {
                ForEach(order, id: \.self) { id in
                    if let source = extensions.ext(id) {
                        row(source)
                    }
                }
                .onMove { from, to in
                    order.move(fromOffsets: from, toOffset: to)
                    extensions.setSourceOrder(order)
                }
            } header: {
                Text("Preferred First")
            } footer: {
                Text("When two sources have the same edition, Folio downloads from the one higher up. The right edition and language always come first.")
            }
            .folioRow()

            Section {
                Label {
                    Text("A source made for one language goes first when you download in that language.")
                        .font(.subheadline)
                        .foregroundStyle(FolioTheme.muted)
                } icon: {
                    Image(systemName: "globe")
                        .foregroundStyle(FolioTheme.olive)
                }
            }
            .folioRow()
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, .constant(.active))
        .folioScreen()
        .navigationTitle("Download Order")
        .folioPageHeader("Download Order")
    }

    private func row(_ source: ExtensionStore.Installed) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.body)
                .foregroundStyle(source.saved.enabled ? FolioTheme.olive : FolioTheme.muted)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.manifest.name)
                    .foregroundStyle(source.saved.enabled ? FolioTheme.ink : FolioTheme.muted)
                Text(source.manifest.languageLabel)
                    .font(.caption)
                    .foregroundStyle(FolioTheme.muted)
            }
            Spacer(minLength: 8)
            if !source.saved.enabled {
                Text("Off")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(FolioTheme.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(FolioTheme.line.opacity(0.5), in: Capsule())
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
