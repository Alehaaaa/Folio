import SwiftUI

extension Notification.Name {
    /// In-app confirmation that Find Source queued or reused a background job.
    /// `userInfo` contains `title` and `alreadyInProgress`; never changes pages.
    static let folioDownloadEnqueued = Notification.Name("folio.download.enqueued")
}

enum SidebarItem: Hashable {
    case home, search, browse, goals, downloading
    case library(LibraryFilter)
    case shelf(HCStatus)
    case collection(UUID)
}

struct ContentView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hc
    @Environment(GoodreadsClient.self) private var gr
    @Environment(\.openWindow) private var openWindow

    @State private var downloads = DownloadQueue.shared
    @State private var selection: SidebarItem? = .home
    @State private var searchQuery = ""
    @State private var showImporter = false
    @State private var naming: NamingState?
    @State private var downloadNotice: DownloadNotice?

    private struct DownloadNotice: Identifiable {
        enum Kind { case queued, alreadyQueued, ready, failed }
        let id = UUID()
        let title: String
        let kind: Kind
        var jobID: UUID?
        var bookID: UUID?
    }

    struct NamingState: Identifiable {
        var id = UUID()
        var collection: UUID?
        var name: String
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            NavigationStack(path: Binding(get: { Router.shared.path }, set: { Router.shared.path = $0 })) {
                detail
                    .background(Backdrop())
                    .navigationDestination(for: BookRoute.self) { RouteView(route: $0).background(Backdrop()) }
            }
            .onChange(of: selection) { Router.shared.path = []; PopupCenter.shared.close() }
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: BookFormat.importTypes, allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { store.importFiles(urls) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let books = urls.filter { BookFormat.from(url: $0) != nil }
            store.importFiles(books)
            return !books.isEmpty
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioImport)) { _ in showImporter = true }
        .onReceive(NotificationCenter.default.publisher(for: .folioDownloadEnqueued)) { notification in
            let exists = notification.userInfo?["alreadyInProgress"] as? Bool ?? false
            presentDownloadNotice(DownloadNotice(title: notification.userInfo?["title"] as? String ?? "Book",
                                                kind: exists ? .alreadyQueued : .queued))
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioDownloadReady)) { notification in
            presentDownloadNotice(DownloadNotice(title: notification.userInfo?["title"] as? String ?? "Book",
                                                kind: .ready,
                                                jobID: notification.userInfo?["jobID"] as? UUID,
                                                bookID: notification.userInfo?["bookID"] as? UUID))
        }
        .onReceive(NotificationCenter.default.publisher(for: .folioDownloadFailed)) { notification in
            presentDownloadNotice(DownloadNotice(title: notification.userInfo?["title"] as? String ?? "Book",
                                                kind: .failed,
                                                jobID: notification.userInfo?["jobID"] as? UUID))
        }
        .onOpenURL(perform: handleWidgetLink)
        .onChange(of: hc.revision) { _, _ in
            Task { await FolioWidgetBridge.refreshHardcover() }
        }
        .task {
            if OnboardingCoordinator.shared.shouldPresentAutomatically() {
                await Task.yield() // Allow the main window to appear before opening the welcome window.
                openWindow(id: "onboarding")
            }
            await FolioLaunchDiagnostics.run(library: store, hardcover: hc, openWindow: openWindow) { selection = $0 }
        }
        .alert(naming?.collection == nil ? "New Collection" : "Rename Collection", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: Binding(get: { naming?.name ?? "" }, set: { naming?.name = $0 }))
            Button("Cancel", role: .cancel) { naming = nil }
            Button("Save") {
                if let n = naming, !n.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    if let c = n.collection { store.renameCollection(c, n.name) } else { selection = .collection(store.addCollection(n.name)) }
                }
                naming = nil
            }
        }
        .overlay(alignment: .bottom) { statusToast }
        .overlay { PopupHost() }
        // Above floating detail panels, but never a sheet, system alert, or
        // notification-center banner. Only the explicit button navigates.
        .overlay(alignment: .bottom) { downloadQueueToast }
    }

    /// WidgetKit opens these links in Folio, using the same destinations as the sidebar.
    private func handleWidgetLink(_ url: URL) {
        guard let destination = FolioDeepLink.resolve(url, library: store) else { return }
        switch destination {
        case .read(let id): openWindow(id: "reader", value: id)
        case .select(let route): selection = route
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Home", systemImage: "house").tag(SidebarItem.home)
            Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
            Label("Browse", systemImage: "sparkle.magnifyingglass").tag(SidebarItem.browse)
            Label("Reading Goals", systemImage: "target").tag(SidebarItem.goals)

            Section("Downloading") {
                Label("Downloads", systemImage: "arrow.down.circle")
                    .badge(downloads.activeCount + downloads.errorCount)
                    .tag(SidebarItem.downloading)
            }

            Section("Library") {
                ForEach(LibraryFilter.libraryCategories) { f in
                    let n = store.books(f).count
                    Label(f.label, systemImage: f.symbol)
                        .badge(f == .all || n > 0 ? n : 0)
                        .tag(SidebarItem.library(f))
                }
            }

            Section("My Shelves") {
                ForEach(HCStatus.allCases) { s in
                    Label(s.unifiedLabel, systemImage: s.symbol).tag(SidebarItem.shelf(s))
                }
                if !hc.isConnected || !gr.isLinked {
                    SettingsLink { Label(hc.isConnected ? "Link Goodreads…" : "Connect Hardcover…", systemImage: "person.crop.circle.badge.plus") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Collections") {
                ForEach(store.data.collections) { c in
                    Label(c.name, systemImage: "rectangle.stack")
                        .badge(store.books(in: c.id).count)
                        .tag(SidebarItem.collection(c.id))
                        .contextMenu {
                            Button("Rename…") { naming = NamingState(collection: c.id, name: c.name) }
                            Button("Delete Collection", role: .destructive) {
                                if selection == .collection(c.id) { selection = .library(.all) }
                                store.deleteCollection(c.id)
                            }
                        }
                        .dropDestination(for: String.self) { ids, _ in
                            for s in ids { if let id = UUID(uuidString: s), !(store.book(id)?.collections.contains(c.id) ?? true) { store.toggle(id, in: c.id) } }
                            return true
                        }
                }
                Button { naming = NamingState(collection: nil, name: "") } label: {
                    Label("New Collection", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .home {
        case .home:
            HomeView(selection: $selection) { query in
                searchQuery = query
                selection = .search
            }
        case .search: FolioSearchView(query: searchQuery)
        case .browse: BrowseView()
        case .goals: GoalsView()
        case .downloading: DownloadingView()
        case .library(let f): LibraryGridView(title: f.label, source: .filter(f))
        case .shelf(let s): ShelfView(status: s)
        case .collection(let id):
            if let c = store.data.collections.first(where: { $0.id == id }) {
                LibraryGridView(title: c.name, source: .collection(id))
            } else {
                LibraryGridView(title: "All", source: .filter(.all))
            }
        }
    }

    @ViewBuilder
    private var statusToast: some View {
        let message: String? = store.importing > 0 ? "Adding \(store.importing) book\(store.importing == 1 ? "" : "s")…" : store.lastError
        if let message {
            HStack(spacing: 10) {
                if store.importing > 0 { ProgressView().controlSize(.small) } else { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow) }
                Text(message).font(.callout)
                if store.importing == 0 {
                    Button { store.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.bottom, 18)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var downloadQueueToast: some View {
        if let notice = downloadNotice {
            HStack(spacing: 12) {
                Image(systemName: noticeSymbol(notice.kind))
                    .font(.title3)
                    .foregroundStyle(notice.kind == .ready ? .green : notice.kind == .failed ? .orange : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(noticeHeading(notice.kind))
                        .font(.callout.weight(.semibold))
                    Text(notice.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 10)
                if notice.kind == .ready, let bookID = notice.bookID, store.book(bookID) != nil {
                    Button { downloadNotice = nil; openWindow(id: "reader", value: bookID) } label: {
                        Label("Read", systemImage: "book.fill").foregroundStyle(.white)
                    }
                    .buttonStyle(BookPrimaryActionStyle())
                    .controlSize(.small)
                    Button("Details") { downloadNotice = nil; BookDetailsPresenter.showLocal(bookID) }
                        .buttonStyle(BookSecondaryActionStyle())
                        .controlSize(.small)
                } else if notice.kind == .failed, let jobID = notice.jobID {
                    Button { downloads.retry(jobID); downloadNotice = nil } label: {
                        Text("Retry").foregroundStyle(.white)
                    }
                        .buttonStyle(BookPrimaryActionStyle())
                        .controlSize(.small)
                }
                Button("Downloads") { downloadNotice = nil; selection = .downloading }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { downloadNotice = nil }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss download notice")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: 500)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
            .shadow(color: .black.opacity(0.14), radius: 15, y: 5)
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func presentDownloadNotice(_ notice: DownloadNotice) {
        withAnimation(.easeOut(duration: 0.22)) { downloadNotice = notice }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(notice.kind == .ready ? 12 : 7))
            guard downloadNotice?.id == notice.id else { return }
            withAnimation(.easeOut(duration: 0.20)) { downloadNotice = nil }
        }
    }

    private func noticeSymbol(_ kind: DownloadNotice.Kind) -> String {
        switch kind {
        case .queued: "arrow.down.circle.fill"
        case .alreadyQueued: "arrow.clockwise.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    private func noticeHeading(_ kind: DownloadNotice.Kind) -> String {
        switch kind {
        case .queued: "Added to Downloads"
        case .alreadyQueued: "Already in progress"
        case .ready: "Ready to read"
        case .failed: "Needs attention"
        }
    }
}
