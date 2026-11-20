import SwiftUI
import UniformTypeIdentifiers

// MARK: - Settings → Sources

struct ExtensionsSettings: View {
    @Environment(ExtensionStore.self) private var exts
    @State private var showImporter = false
    @State private var newValue: [String: String] = [:]

    var body: some View {
        Form {
            Section {
                ForEach(exts.installed) { e in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "puzzlepiece.extension.fill").foregroundStyle(.secondary)
                            Text(e.manifest.name).font(.headline)
                            Text("v\(e.manifest.version)").foregroundStyle(.secondary)
                            if e.saved.builtIn { Text("Built-in").font(.caption).padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: .capsule) }
                            Spacer()
                            Toggle("Enabled", isOn: Binding(get: { e.saved.enabled }, set: { v in exts.update(e.id) { $0.enabled = v } }))
                                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                            if !e.saved.builtIn {
                                Button(role: .destructive) { exts.remove(e.id) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            }
                        }
                        Text(e.manifest.description).font(.callout).foregroundStyle(.secondary)
                        ForEach(e.manifest.settings.filter { $0.kind == "list" }, id: \.key) { setting in
                            listEditor(e, setting)
                        }
                        let reach = exts.reach(e).map { $0.replacingOccurrences(of: ":443", with: "").replacingOccurrences(of: ":80", with: "") }.sorted()
                        Text(reach.isEmpty ? "Can reach: nothing yet" : "Can reach: " + reach.joined(separator: ", "))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                }
                if let err = exts.lastError { Label(err, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout) }
            } header: {
                Text("Sources")
            } footer: {
                Text("When you open a book that isn't on this Mac yet, Folio asks these sources for a copy. Each source is a JavaScript extension that runs isolated: its own engine, no access to your files, and network access only to its own servers.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Add Extension from File…") { showImporter = true }
            }
        }
        .formStyle(.grouped)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "js") ?? .javaScript, .javaScript]) { r in
            if case .success(let url) = r { Task { await exts.install(from: url) } }
        }
    }

    @ViewBuilder
    private func listEditor(_ e: ExtensionStore.Installed, _ setting: SourceSetting) -> some View {
        let values = e.saved.config[setting.key] ?? []
        let field = "\(e.id).\(setting.key)"
        VStack(alignment: .leading, spacing: 4) {
            Text(setting.label).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(values, id: \.self) { v in
                HStack {
                    Image(systemName: "server.rack").foregroundStyle(.secondary)
                    Text(v).textSelection(.enabled)
                    Spacer()
                    Button(role: .destructive) { exts.update(e.id) { $0.config[setting.key] = values.filter { $0 != v } } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
                .font(.callout)
            }
            HStack {
                TextField(setting.placeholder.isEmpty ? "https://" : setting.placeholder, text: Binding(get: { newValue[field] ?? "" }, set: { newValue[field] = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { add(e, setting, field) }
                Button("Add") { add(e, setting, field) }
            }
            .controlSize(.small)
        }
    }

    private func add(_ e: ExtensionStore.Installed, _ setting: SourceSetting, _ field: String) {
        var h = (newValue[field] ?? "").trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return }
        if !h.lowercased().hasPrefix("http") { h = "http://" + h }
        while h.hasSuffix("/") { h.removeLast() }
        guard URL(string: h).flatMap(SourceRuntime.hostKey) != nil else { return }
        let values = e.saved.config[setting.key] ?? []
        if !values.contains(h) { exts.update(e.id) { $0.config[setting.key] = values + [h] } }
        newValue[field] = ""
    }
}
