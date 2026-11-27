import SwiftUI
import WebKit

/// Settings › Sync: this device's other devices first, then every reading
/// service Folio keeps in step, Hardcover first.
struct FolioMobileSyncServicesView: View {
    @Environment(HardcoverClient.self) private var hardcover
    @State private var sync = FolioShelfSync.shared

    var body: some View {
        Form {
            FolioCloudSyncSection()

            Section {
                NavigationLink {
                    Form { FolioMobileHardcoverAccountSection() }
                        .navigationTitle("Hardcover")
                        .folioPageHeader("Hardcover")
                        .folioScreen()
                } label: {
                    LabeledContent {
                        Text(hardcover.isConnected ? "On" : "Off")
                    } label: {
                        Label("Hardcover", systemImage: "books.vertical")
                    }
                }
                ForEach(ShelfService.allCases) { service in
                    NavigationLink {
                        FolioMobileShelfServiceView(service: service)
                    } label: {
                        LabeledContent {
                            if sync.runs[service] != nil {
                                ProgressView()
                            } else if sync.errors[service] != nil {
                                Image(systemName: "exclamationmark.triangle").foregroundStyle(FolioTheme.danger)
                            } else {
                                Text(sync.isConnected(service) ? "On" : "Off")
                            }
                        } label: {
                            Label(service.name, systemImage: service.symbol)
                        }
                    }
                }
            } header: {
                Text("Services")
            } footer: {
                Text("Each book's status and reading progress go to every service that's on.")
            }
            .folioRow()
        }
        .navigationTitle("Sync")
        .folioPageHeader("Sync")
        .folioScreen()
    }
}

struct FolioMobileShelfServiceView: View {
    let service: ShelfService
    @State private var sync = FolioShelfSync.shared
    @State private var login = ""
    @State private var password = ""
    @State private var signingIn = false
    @State private var webSignIn = false
    @State private var resolvingGoodreadsName = false

    var body: some View {
        Form {
            Section("Account") {
                if let account = sync.accounts[service] {
                    Label(service == .goodreads
                          ? GoodreadsProfileName.display(account.name)
                          : (account.name ?? "Signed In"), systemImage: "checkmark.circle.fill")
                        .foregroundStyle(FolioTheme.success)
                    Button("Sign Out", role: .destructive) { sync.signOut(service) }
                } else if service.signIn == .web {
                    Button { webSignIn = true } label: {
                        Label("Sign In to \(service.name)", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .folioFormButton()
                } else {
                    TextField(service.signIn == .email ? "Email" : "Username", text: $login)
                        .textContentType(service.signIn == .email ? .emailAddress : .username)
                        .keyboardType(service.signIn == .email ? .emailAddress : .default)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                    Button {
                        Task {
                            signingIn = true
                            await sync.signIn(service, login: login, password: password)
                            signingIn = false
                            if sync.isConnected(service) { password = "" }
                        }
                    } label: {
                        if signingIn { ProgressView() } else {
                            Label("Sign In", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                    .folioFormButton()
                    .disabled(login.isEmpty || password.isEmpty || signingIn)
                }
                if let error = sync.errors[service] {
                    Text(error).font(.footnote).foregroundStyle(FolioTheme.danger)
                }
            }
            .folioRow()

            if sync.isConnected(service) {
                Section("Sync") {
                    Toggle("Sync Automatically", isOn: Binding(
                        get: { sync.automatic[service] ?? true },
                        set: { sync.setAutomatic(service, $0) }
                    ))
                    if let run = sync.runs[service] {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: Double(run.done), total: Double(max(run.total, 1)))
                            Text("Syncing \(run.done) of \(run.total)").font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            Task { await sync.syncLibrary(service) }
                        } label: {
                            Label("Sync Library Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    LabeledContent("Linked Books", value: String(sync.linkedCount(service)))
                    if let date = sync.lastSync[service] {
                        LabeledContent("Last Sync", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                .folioRow()
            }
        }
        .navigationTitle(service.name)
        .folioPageHeader(service.name)
        .folioScreen()
        .task(id: sync.accounts[service]?.userID) {
            guard service == .goodreads,
                  let account = sync.accounts[.goodreads],
                  !GoodreadsProfileName.isPersonName(account.name),
                  !resolvingGoodreadsName else { return }
            resolvingGoodreadsName = true
            defer { resolvingGoodreadsName = false }
            if let name = await GoodreadsProfileName.fetch(account: account),
               sync.accounts[.goodreads]?.userID == account.userID {
                var updated = account
                updated.name = name
                sync.connect(.goodreads, account: updated)
            }
        }
        .sheet(isPresented: $webSignIn) {
            FolioShelfWebSignIn(service: service) { account in
                webSignIn = false
                sync.connect(service, account: account)
                if service != .goodreads {
                    Task { await sync.syncLibrary(service) }
                }
            }
            #if os(macOS)
            .frame(minWidth: 850, minHeight: 660)
            #else
            .presentationDetents([.large])
            #endif
        }
    }
}

// MARK: - Web sign-in (StoryGraph and Goodreads have no sign-in API)

struct FolioShelfWebSignIn: View {
    let service: ShelfService
    let done: (ShelfAccount) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var webError: String?
    @State private var loading = true
    @State private var reloadID = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if loading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading \(service.name) sign-in…")
                            .font(.callout)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(10)
                }
                if let webError {
                    Text(webError)
                        .font(.footnote)
                        .foregroundStyle(FolioTheme.danger)
                        .padding(8)
                }
                FolioShelfWebView(service: service, done: done,
                                  loaded: { loading = false },
                                  failed: { webError = $0; loading = false })
                    .id(reloadID)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
                .frame(minHeight: 520)
                .background(Color.white)
                .navigationTitle(service.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .automatic) {
                        Button("Reload") {
                            webError = nil
                            loading = true
                            reloadID += 1
                        }
                    }
                }
        }
    }
}

private struct FolioShelfWebView: UIViewRepresentable {
    let service: ShelfService
    let done: (ShelfAccount) -> Void
    let loaded: () -> Void
    let failed: (String) -> Void

    var start: URL {
        switch service {
        case .goodreads: URL(string: "https://www.goodreads.com/")!
        default: URL(string: "https://app.thestorygraph.com/users/sign_in")!
        }
    }

    var domain: String { service == .goodreads ? "goodreads.com" : "thestorygraph.com" }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Goodreads Home is the working sign-in entrypoint in Goodreads Lab.
        // A persistent web store also keeps its Amazon/Goodreads redirect flow.
        config.websiteDataStore = service == .goodreads ? .default() : .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.load(URLRequest(url: start))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let parent: FolioShelfWebView
        private var finished = false

        init(_ parent: FolioShelfWebView) { self.parent = parent }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            parent.loaded()
            Task { await check(web) }
        }

        func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.failed("Could not load the sign-in page: \(error.localizedDescription)")
        }

        func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.failed("Goodreads navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // Some Goodreads sign-in links use target=_blank/window.open.
            if navigationAction.targetFrame == nil, let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        private func check(_ web: WKWebView) async {
            guard !finished, let url = web.url, let host = url.host, host.hasSuffix(parent.domain) else { return }
            let path = url.path
            if path.contains("sign_in") || path.contains("sign_up") || path.hasPrefix("/ap/") { return }
            let cookies = await web.configuration.websiteDataStore.httpCookieStore.allCookies()
                .filter { $0.domain.hasSuffix(parent.domain) }
            var name: String?
            switch parent.service {
            case .storygraph:
                guard cookies.contains(where: { $0.name == "remember_user_token" }) else { return }
                name = try? await web.evaluateJavaScript(
                    "(document.querySelector('a[href^=\"/profile/\"]')||{}).getAttribute ? document.querySelector('a[href^=\"/profile/\"]').getAttribute('href').split('/').pop() : ''"
                ) as? String
            case .goodreads:
                let identity = (try? await web.evaluateJavaScript(
                    #"""
                    (() => {
                      for (const selector of [
                        '.siteHeader__personal a[href*="/user/show/"]',
                        'nav a[href*="/user/show/"]',
                        '[data-testid="header-personal-nav"] a[href*="/user/show/"]'
                      ]) {
                        const link = document.querySelector(selector);
                        const id = link?.getAttribute('href')?.match(/\/user\/show\/(\d+)/)?.[1];
                        if (id) {
                          const label = (link.getAttribute('title') ||
                            link.getAttribute('aria-label') || link.textContent || '').trim();
                          return {id, name: label};
                        }
                      }
                      return {id: '', name: ''};
                    })()
                    """#
                ) as? [String: String]) ?? [:]
                let id = identity["id"] ?? ""
                guard !id.isEmpty else { return }
                let headerName = identity["name"]
                let agent = (try? await web.evaluateJavaScript("navigator.userAgent") as? String) ?? ShelfWeb.fallbackAgent
                var account = ShelfAccount(name: headerName, userID: id,
                                           cookies: cookies.map { ShelfCookie($0) }, userAgent: agent)
                if !GoodreadsProfileName.isPersonName(account.name) {
                    account.name = await GoodreadsProfileName.fetch(account: account)
                }
                finished = true
                parent.done(account)
                return
            default:
                return
            }
            let agent = (try? await web.evaluateJavaScript("navigator.userAgent") as? String) ?? ShelfWeb.fallbackAgent
            finished = true
            let account = ShelfAccount(name: (name?.isEmpty ?? true) ? nil : name,
                                       cookies: cookies.map { ShelfCookie($0) }, userAgent: agent)
            parent.done(account)
        }
    }
}

/// Identifies the signed-in Goodreads reader once, then caches the resulting
/// display name in the existing Keychain-backed ShelfAccount. This is not a
/// second login, a profile link field, or a recurring shelf request.
@MainActor
private enum GoodreadsProfileName {
    /// Avoid repeated profile lookups when a page is reopened or the server
    /// rejects profile access. Logging in again is not required to retry.
    private static var attempted: Set<String> = []

    static func display(_ name: String?) -> String {
        isPersonName(name) ? name!.trimmingCharacters(in: .whitespacesAndNewlines) : "Connected to Goodreads"
    }

    static func isPersonName(_ raw: String?) -> Bool {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return false }
        let lower = name.lowercased()
        return !lower.hasPrefix("goodreads #") && lower != "goodreads" &&
            lower != "my profile" && lower != "profile" && lower != "account" &&
            lower != "user" && lower != "me" && lower != "my books" &&
            lower != "account settings" && lower != "settings" &&
            !name.allSatisfy(\.isNumber)
    }

    static func fetch(account: ShelfAccount) async -> String? {
        guard let id = account.userID, !id.isEmpty, id.allSatisfy(\.isNumber),
              let url = URL(string: "https://www.goodreads.com/user/show/\(id)") else { return nil }
        guard attempted.insert(id).inserted else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(account.userAgent ?? ShelfWeb.fallbackAgent, forHTTPHeaderField: "User-Agent")
        let cookies = (account.cookies ?? []).filter { cookie in
            let host = cookie.domain.lowercased()
            return host == "goodreads.com" || host.hasSuffix(".goodreads.com")
        }
        if !cookies.isEmpty {
            request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "), forHTTPHeaderField: "Cookie")
        }
        let session = URLSession(configuration: .ephemeral, delegate: GoodreadsRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              http.url?.host == "www.goodreads.com",
              data.count < 2_000_000,
              let html = String(data: data, encoding: .utf8) else { return nil }

        func capture(_ pattern: String) -> String? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: html) else { return nil }
            return String(html[range])
        }

        let candidates: [String?] = [
            capture(#"<meta\b[^>]*property=["']og:title["'][^>]*content=["']([^"']+)["']"#),
            capture(#"<meta\b[^>]*content=["']([^"']+)["'][^>]*property=["']og:title["']"#),
            capture(#"<h1\b[^>]*>(.*?)</h1>"#),
            capture(#"<title[^>]*>(.*?)</title>"#),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            var text = candidate.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            for (entity, value) in [("&amp;", "&"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
                                    ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
                text = text.replacingOccurrences(of: entity, with: value)
            }
            text = text.replacingOccurrences(of: #"\s*[-|–—]\s*Goodreads.*$"#,
                                              with: "", options: [.regularExpression, .caseInsensitive])
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isPersonName(text), text.count < 100 { return text }
        }
        return nil
    }
}

/// Do not forward a signed-in Goodreads cookie header to another host if a
/// session has expired and Goodreads redirects toward an external login.
private final class GoodreadsRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.host == "www.goodreads.com" ? request : nil)
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { c in getAllCookies { c.resume(returning: $0) } }
    }
}
