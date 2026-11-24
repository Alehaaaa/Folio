import Combine
import SwiftUI
import WebKit

/// Separate Goodreads experiment. It does not read Folio's library, keychain,
/// user defaults, or cookies and never syncs in the background.
@main
struct GoodreadsLabApp: App {
    @StateObject private var lab = GoodreadsLabModel()

    var body: some Scene {
        WindowGroup("Goodreads Lab") {
            GoodreadsLabView(lab: lab)
                .frame(minWidth: 860, minHeight: 540)
        }
        .defaultSize(width: 1120, height: 720)
    }
}

private struct GoodreadsBook: Identifiable {
    var id: String
    var title: String
    var author: String
    var shelf: String
    var percent: Int?
}

@MainActor
private final class GoodreadsLabModel: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    @Published var profileID = "188989236"
    @Published var bookID = ""
    @Published var shelf = "to-read"
    @Published var statusMethod = "graphql"
    @Published var progress = "25"
    @Published var progressUnit = "percent"
    @Published var busy = false
    @Published var page = "Goodreads is opening…"
    @Published var summary = "Sign in on the right, then read your Goodreads shelves."
    @Published var events: [String] = []
    @Published var books: [GoodreadsBook] = []
    @Published var readingSessions: [String] = []
    @Published var shelfCounts: [String: Int] = [:]
    @Published var recording = false
    @Published var recordedEvents = 0
    @Published var recordingFile = ""

    let browser: WKWebView
    private let bridge: String
    private var trace: [[String: Any]] = []
    private var beganAt: Date?
    private var attemptedInitialShelfLoad = false

    static let shelves = [
        ("to-read", "Want to Read"),
        ("currently-reading", "Currently Reading"),
        ("read", "Read"),
        ("did-not-finish", "Did Not Finish"),
    ]

    var sortedBooks: [GoodreadsBook] {
        books.sorted {
            let firstRank = $0.shelf == "currently-reading" ? 0 : 1
            let secondRank = $1.shelf == "currently-reading" ? 0 : 1
            if firstRank != secondRank { return firstRank < secondRank }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    var selectedBook: GoodreadsBook? { books.first { $0.id == bookID } }

    func selectBook(_ id: String) {
        bookID = id
        guard let book = selectedBook else { return }
        if !book.shelf.isEmpty { shelf = book.shelf }
        progress = book.percent.map(String.init) ?? ""
        if book.percent != nil { progressUnit = "percent" }
    }

    override init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        if let scriptURL = Bundle.module.url(forResource: "GoodreadsTrafficProbe", withExtension: "js"),
           let probe = try? String(contentsOf: scriptURL, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(
                source: probe, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        browser = WKWebView(frame: .zero, configuration: config)
        if #available(macOS 13.3, *) { browser.isInspectable = true }
        bridge = (Bundle.module.url(forResource: "GoodreadsBridge", withExtension: "js")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }) ?? "throw new Error('Missing GoodreadsBridge.js resource')"
        super.init()
        config.userContentController.add(self, name: "goodreadsRecorder")
        browser.navigationDelegate = self
        browser.uiDelegate = self
        go("https://www.goodreads.com/")
    }

    func go(_ address: String) {
        guard let url = URL(string: address), url.scheme == "https",
              url.host == "www.goodreads.com" else { return }
        browser.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        page = webView.url?.absoluteString ?? "Goodreads"
        if recording { Task { await armRecorder() } }
        if !attemptedInitialShelfLoad,
           webView.url?.host == "www.goodreads.com",
           ["/", "/home"].contains(webView.url?.path ?? ""),
           !profileID.isEmpty {
            attemptedInitialShelfLoad = true
            Task { await readShelves() }
        }
        // The user's profile page is an unambiguous source for an ID. Do not
        // infer the account from random profile links in another person's feed.
        if profileID.isEmpty, let path = webView.url?.path,
           let range = path.range(of: #"^/user/show/(\d+)"#, options: .regularExpression) {
            profileID = String(path[range].split(separator: "/").last ?? "")
                .prefix(while: { $0.isNumber }).description
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if recording { Task { await armRecorder() } }
        if recording { appendTrace(["type": "navigation", "url": webView.url?.host ?? "unknown",
                                    "path": webView.url?.path ?? "", "time": ISO8601DateFormatter().string(from: Date())]) }
    }

    /// WebKit otherwise silently drops target=_blank and window.open links.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if recording {
            appendTrace(["type": "popup-navigation", "host": navigationAction.request.url?.host ?? "",
                         "path": navigationAction.request.url?.path ?? "",
                         "time": ISO8601DateFormatter().string(from: Date())])
        }
        if navigationAction.request.url?.host == "www.goodreads.com" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "goodreadsRecorder", recording,
              let payload = message.body as? [String: Any] else { return }
        appendTrace(payload)
    }

    private func appendTrace(_ item: [String: Any]) {
        guard trace.count < 10_000 else { return }
        trace.append(item)
        if trace.count.isMultiple(of: 10) || trace.count <= 2 { recordedEvents = trace.count }
    }

    private func armRecorder() async {
        guard recording, browser.url?.host == "www.goodreads.com" else { return }
        _ = try? await browser.evaluateJavaScript("window.__goodreadsLabRecorder?.start()")
    }

    func startRecording() {
        guard !recording else { return }
        recording = true
        trace = []
        recordedEvents = 0
        recordingFile = ""
        beganAt = Date()
        appendTrace(["type": "recording-start-native", "time": ISO8601DateFormatter().string(from: Date()),
                     "page": browser.url?.path ?? "unknown"])
        summary = "Recording clicks, DOM changes, JavaScript diagnostics, navigation and traffic. Reproduce the issue, then Stop & Save."
        Task { await armRecorder() }
    }

    func stopRecording() async {
        guard recording else { return }
        _ = try? await browser.evaluateJavaScript("window.__goodreadsLabRecorder?.stop()")
        // JavaScript-to-native messages are delivered asynchronously.
        try? await Task.sleep(nanoseconds: 200_000_000)
        appendTrace(["type": "recording-stop-native", "time": ISO8601DateFormatter().string(from: Date())])
        recording = false
        recordedEvents = trace.count
        // Keep recordings alongside this disposable lab build. The project
        // ignores .build, and the shared workspace can inspect the JSON later.
        let folder = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("recordings", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let file = folder.appendingPathComponent("goodreads-\(stamp)-\(UUID().uuidString.prefix(6)).json")
            let json: [String: Any] = ["app": "Goodreads Lab", "formatVersion": 1,
                                       "startedAt": ISO8601DateFormatter().string(from: beganAt ?? Date()),
                                       "finishedAt": ISO8601DateFormatter().string(from: Date()),
                                       "events": trace]
            let output = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            try output.write(to: file, options: .atomic)
            recordingFile = file.path
            summary = "Recording saved: \(trace.count) events at \(file.path)"
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } catch {
            summary = "Recording could not be saved: \(error.localizedDescription)"
            log(summary)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("Browser navigation error: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("Browser load error: \(error.localizedDescription)")
    }

    private func log(_ message: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        events.insert("\(stamp)  \(message)", at: 0)
        if events.count > 60 { events.removeLast(events.count - 60) }
    }

    private func call(_ action: String, _ values: [String: Any] = [:]) async throws -> [String: Any] {
        guard browser.url?.host == "www.goodreads.com" else {
            throw NSError(domain: "GoodreadsLab", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Return to the Goodreads website after signing in."])
        }
        let output = try await browser.callAsyncJavaScript(bridge,
                                                           arguments: ["action": action, "payload": values],
                                                           in: nil, contentWorld: .page)
        guard let result = output as? [String: Any] else {
            throw NSError(domain: "GoodreadsLab", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Goodreads returned an unexpected response."])
        }
        return result
    }

    private func perform(_ label: String, action: String, values: [String: Any],
                         receive: (([String: Any]) -> Void)? = nil) async {
        guard !busy else { return }
        busy = true
        summary = "\(label)…"
        defer { busy = false }
        do {
            let result = try await call(action, values)
            receive?(result)
            if let endpoint = result["endpoint"] as? String {
                let http = result["httpStatus"] as? Int ?? 0
                let verified = result["verified"] as? Bool ?? false
                let details = result["verification"] as? String ?? "No verification result."
                summary = "\(label): HTTP \(http), \(verified ? "verified" : "not verified"). \(details)"
                log("\(endpoint): HTTP \(http), \(verified ? "verified" : "unverified"). \(details)")
            } else {
                if summary.hasSuffix("…") { summary = "\(label) complete." }
                log("\(label) complete.")
            }
        } catch {
            summary = "\(label) failed: \(error.localizedDescription)"
            log(summary)
        }
    }

    func checkSession() async {
        await perform("Check session", action: "session", values: [:]) { [self] response in
            if profileID.isEmpty, let id = response["userID"] as? String { profileID = id }
            summary = "Website ready. Use your Goodreads profile ID to read shelves."
        }
    }

    func readBook() async {
        await perform("Read book \(bookID)", action: "readBook", values: ["bookID": bookID]) { [self] response in
            guard let book = response["book"] as? [String: Any] else { return }
            let title = book["title"] as? String ?? "Unknown title"
            let author = book["author"] as? String ?? ""
            let progress = book["percent"] as? Int
            summary = "\(title)\(author.isEmpty ? "" : " — " + author). Goodreads page progress: \(progress.map { "\($0)%" } ?? "not exposed")."
            log("Read metadata for book \(bookID).")
        }
    }

    func readShelves() async {
        await perform("Read Goodreads shelves", action: "readShelves", values: ["userID": profileID]) { [self] response in
            let items = response["books"] as? [[String: Any]] ?? []
            var seen = Set<String>()
            books = items.compactMap { item in
                guard let id = item["id"] as? String, let title = item["title"] as? String else { return nil }
                guard seen.insert(id).inserted else { return nil }
                return GoodreadsBook(id: id, title: title,
                                     author: item["author"] as? String ?? "",
                                     shelf: item["shelf"] as? String ?? "",
                                     percent: item["percent"] as? Int)
            }
            shelfCounts = response["counts"] as? [String: Int] ?? [:]
            if !books.contains(where: { $0.id == bookID }), let first = sortedBooks.first {
                selectBook(first.id)
            } else if books.isEmpty {
                bookID = ""
            }
            let truncated = response["truncated"] as? [String] ?? []
            summary = "Loaded \(books.count) shelved books." +
                (truncated.isEmpty ? "" : " Page limit reached for: \(truncated.joined(separator: ", ")).")
        }
    }

    func readProgress() async {
        await perform("Read reading sessions", action: "readProgress", values: [:]) { [self] response in
            let items = response["sessions"] as? [[String: Any]] ?? []
            readingSessions = items.map { session in
                let name = session["title"] as? String ?? "Book"
                let id = session["bookID"] as? String ?? ""
                let pct = (session["percent"] as? NSNumber).map { "\($0)%" } ?? "percent unavailable"
                let current = (session["currentPosition"] as? NSNumber).map { "\($0)" } ?? "?"
                let total = (session["finalPosition"] as? NSNumber).map { "\($0)" } ?? "?"
                return "\(name) [\(id)]: \(pct), position \(current)/\(total)"
            }
            let keys = response["topLevelKeys"] as? [String] ?? []
            summary = "Reading session API returned \(readingSessions.count) recognizable entries." +
                (readingSessions.isEmpty ? " JSON keys: \(keys.joined(separator: ", "))." : "")
        }
    }

    func openMyBooks() {
        let source = profileID.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = Self.profileID(from: source)
        guard let id else {
            summary = "Enter a numeric Goodreads profile ID or a Goodreads My Books URL."
            return
        }
        go("https://www.goodreads.com/review/list/\(id)?shelf=currently-reading")
    }

    static func profileID(from text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.range(of: #"^\d{1,20}$"#, options: .regularExpression) != nil { return value }
        guard let url = URL(string: value), url.scheme == "https",
              ["www.goodreads.com", "goodreads.com"].contains(url.host ?? ""),
              url.path.range(of: #"^/(review/list|user/show)/\d+"#, options: .regularExpression) != nil else { return nil }
        return url.path.split(separator: "/").dropFirst(2).first
            .map { String($0.prefix(while: { $0.isNumber })) }
    }

    func inspectHome() async {
        await perform("Inspect Home progress", action: "inspectHome", values: [:]) { [self] response in
            let items = response["cards"] as? [[String: Any]] ?? []
            readingSessions = items.map { item in
                let name = item["title"] as? String ?? "Book"
                let id = item["id"] as? String ?? ""
                let pct = (item["percent"] as? Int).map { "\($0)%" } ?? "percentage not exposed"
                return "\(name) [\(id)]: \(pct)"
            }
            let buttons = response["updateButtons"] as? Int ?? 0
            summary = "Found \(items.count) reading cards and \(buttons) Update progress controls in the Home page."
        }
    }

    func inspectProgressEditor() async {
        await perform("Inspect Update progress popup", action: "inspectProgressEditor", values: [:]) { [self] response in
            let controls = response["controls"] as? [[String: Any]] ?? []
            let form = response["formAction"] as? String ?? "JavaScript-controlled form"
            readingSessions = ["Form action: \(form)"] + controls.map { item in
                let tag = item["tag"] as? String ?? "element"
                let field = item["name"] as? String ?? item["id"] as? String ?? "unnamed"
                let label = item["label"] as? String ?? ""
                return "\(tag): \(field) \(label)"
            }
            summary = "Inspected \(controls.count) form controls without exposing entered text or authentication tokens."
        }
    }

    func inspectTraffic() async {
        let requests = trace.filter { ["request", "response", "request-error"].contains($0["type"] as? String ?? "") }
        readingSessions = requests.suffix(25).map { request in
            let method = request["method"] as? String ?? "?"
            let path = (request["target"] as? [String: Any])?["path"] as? String ?? "?"
            let status = (request["status"] as? Int).map(String.init) ?? ""
            return "\(request["type"] as? String ?? "request") \(method) \(path) \(status)"
        }
        summary = "Recorded \(requests.count) traffic events. The complete trace is available after Stop & Save Recording."
    }

    func setShelf() async {
        await perform("Set shelf", action: statusMethod == "graphql" ? "setStatusGraphQL" : "setStatus", values: [
            "userID": profileID, "bookID": bookID, "shelf": shelf,
        ])
    }

    func setProgress() async {
        await perform("Set reading progress", action: "setProgress", values: [
            "bookID": bookID, "unit": progressUnit, "value": Int(progress) ?? -1,
        ])
    }
}

private struct GoodreadsWebView: NSViewRepresentable {
    let browser: WKWebView

    func makeNSView(context: Context) -> WKWebView { browser }
    func updateNSView(_ view: WKWebView, context: Context) {}
}

private struct GoodreadsLabView: View {
    @ObservedObject var lab: GoodreadsLabModel
    @State private var pendingAction: String?
    @State private var showDiagnostics = false

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: 338)
                .background(Color(nsColor: .windowBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Goodreads").font(.headline)
                    Spacer()
                    Button("Home") { lab.go("https://www.goodreads.com/") }
                    Button("Sign In") { lab.go("https://www.goodreads.com/user/sign_in") }
                }
                .padding(9)
                Divider()
                GoodreadsWebView(browser: lab.browser)
                HStack {
                    Text(lab.page)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Spacer()
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
            }
        }
        .alert("Send this change to Goodreads?", isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingAction = nil }
            Button("Write to Goodreads") {
                let action = pendingAction
                pendingAction = nil
                if action == "shelf" { Task { await lab.setShelf() } }
                if action == "progress" { Task { await lab.setProgress() } }
            }
        } message: {
            Text(pendingAction == "shelf"
                 ? "Set book \(lab.bookID) to \(lab.shelf) on your Goodreads account?"
                 : "Set book \(lab.bookID) to \(lab.progress) \(lab.progressUnit == "page" ? "pages read" : "% read") on your Goodreads account?")
        }
    }

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Goodreads Lab").font(.headline)
                    Spacer()
                    if lab.busy { ProgressView().controlSize(.small) }
                    Button {
                        Task { await lab.readShelves() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(lab.busy || lab.profileID.isEmpty)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Book").font(.caption.bold())
                    Picker("Book", selection: Binding(
                        get: { lab.bookID }, set: { lab.selectBook($0) }
                    )) {
                        if lab.books.isEmpty {
                            Text("Refresh to load your shelves").tag("")
                        }
                        ForEach(lab.sortedBooks) { book in
                            Text("\(book.title) · \(book.author)").tag(book.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .disabled(lab.books.isEmpty || lab.busy)
                    Text(lab.selectedBook.map { "\($0.shelf.isEmpty ? "Shelved" : $0.shelf) · ID \($0.id)" }
                         ?? "Sign in, then refresh your Goodreads books")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Reading progress").font(.caption.bold())
                    HStack(spacing: 6) {
                        TextField(lab.progressUnit == "page" ? "Page" : "Percent", text: $lab.progress)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 68)
                        Picker("Unit", selection: $lab.progressUnit) {
                            Text("%").tag("percent")
                            Text("Pages").tag("page")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Spacer(minLength: 0)
                        Button("Update") { pendingAction = "progress" }
                            .disabled(lab.busy || lab.selectedBook == nil ||
                                      Int(lab.progress).map { $0 < 0 || (lab.progressUnit == "percent" && $0 > 100) } != false)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Shelf status").font(.caption.bold())
                    HStack(spacing: 6) {
                        Picker("Shelf", selection: $lab.shelf) {
                            ForEach(GoodreadsLabModel.shelves, id: \.0) { item in
                                Text(item.1).tag(item.0)
                            }
                        }
                        .labelsHidden()
                        Button("Update") { pendingAction = "shelf" }
                            .disabled(lab.busy || lab.selectedBook == nil)
                    }
                }

                Divider()
                HStack(spacing: 8) {
                    if lab.recording {
                        Label("\(lab.recordedEvents) events", systemImage: "record.circle")
                            .foregroundStyle(.red)
                        Spacer()
                        Button("Stop & Save") { Task { await lab.stopRecording() } }
                    } else {
                        Button("Start Recording") { lab.startRecording() }
                        Spacer()
                        if !lab.recordingFile.isEmpty {
                            Button("Show File") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: lab.recordingFile)])
                            }
                        }
                    }
                }

                Text(lab.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                DisclosureGroup("Diagnostics & account", isExpanded: $showDiagnostics) {
                    VStack(alignment: .leading, spacing: 9) {
                        TextField("Profile ID / My Books URL", text: $lab.profileID)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Check Session") { Task { await lab.checkSession() } }
                            Button("My Books") { lab.openMyBooks() }
                            Button("Book Page") {
                                if lab.selectedBook != nil {
                                    lab.go("https://www.goodreads.com/book/show/\(lab.bookID)")
                                }
                            }
                            .disabled(lab.selectedBook == nil)
                        }
                        Picker("Status API", selection: $lab.statusMethod) {
                            Text("GraphQL").tag("graphql")
                            Text("Classic form").tag("classic")
                        }
                        .pickerStyle(.segmented)
                        Button("Read Book") { Task { await lab.readBook() } }
                            .disabled(lab.busy || lab.selectedBook == nil)
                        Button("Read Progress Sessions") { Task { await lab.readProgress() } }
                        Button("Inspect Home") { Task { await lab.inspectHome() } }
                        Button("Inspect Progress Popup") { Task { await lab.inspectProgressEditor() } }
                        Button("Inspect Traffic") { Task { await lab.inspectTraffic() } }
                        ForEach(lab.readingSessions.prefix(15), id: \.self) { item in
                            Text(item).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        ForEach(lab.events.prefix(15), id: \.self) { item in
                            Text(item).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                    .padding(.top, 6)
                }
                .font(.caption)
            }
            .padding(12)
        }
    }
}
