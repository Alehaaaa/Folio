import SwiftUI
import WebKit

/// Every reading service Folio keeps in step, Hardcover first.
struct FolioMobileSyncServicesView: View {
    @Environment(HardcoverClient.self) private var hardcover
    @State private var sync = FolioShelfSync.shared

    var body: some View {
        Form {
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

    var body: some View {
        Form {
            Section("Account") {
                if let account = sync.accounts[service] {
                    Label(account.name ?? "Signed In", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(FolioTheme.success)
                    Button("Sign Out", role: .destructive) { sync.signOut(service) }
                } else if service.signIn == .web {
                    Button { webSignIn = true } label: {
                        Label("Sign In to \(service.name)", systemImage: "person.crop.circle.badge.checkmark")
                    }
                    .folioGlassPill(prominent: true)
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
                    .folioGlassPill(prominent: true)
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
        .sheet(isPresented: $webSignIn) {
            FolioShelfWebSignIn(service: service) { account in
                webSignIn = false
                sync.connect(service, account: account)
                Task { await sync.syncLibrary(service) }
            }
        }
    }
}

// MARK: - Web sign-in (StoryGraph and Goodreads have no sign-in API)

struct FolioShelfWebSignIn: View {
    let service: ShelfService
    let done: (ShelfAccount) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FolioShelfWebView(service: service, done: done)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(service.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }
    }
}

private struct FolioShelfWebView: UIViewRepresentable {
    let service: ShelfService
    let done: (ShelfAccount) -> Void

    var start: URL {
        switch service {
        case .goodreads: URL(string: "https://www.goodreads.com/user/sign_in")!
        default: URL(string: "https://app.thestorygraph.com/users/sign_in")!
        }
    }

    var domain: String { service == .goodreads ? "goodreads.com" : "thestorygraph.com" }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: start))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: FolioShelfWebView
        private var finished = false

        init(_ parent: FolioShelfWebView) { self.parent = parent }

        func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) {
            Task { await check(web) }
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
                let id = (try? await web.evaluateJavaScript(
                    "(document.documentElement.innerHTML.match(/\\/user\\/show\\/(\\d+)/)||[])[1]||''"
                ) as? String) ?? ""
                guard !id.isEmpty else { return }
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

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { c in getAllCookies { c.resume(returning: $0) } }
    }
}
