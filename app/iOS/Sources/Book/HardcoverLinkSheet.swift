import SwiftUI

/// A safe manual Hardcover association: the user chooses the catalogue record
/// explicitly, then the local file receives its id, page count and slug.
struct FolioMobileHardcoverLinkSheet: View {
    let bookID: UUID
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hardcover
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var matches: [HCBook] = []
    @State private var searching = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Title or author", text: $query)
                        .submitLabel(.search)
                        .onSubmit { Task { await search() } }
                    Button {
                        Task { await search() }
                    } label: {
                        HStack {
                            Label("Search Hardcover", systemImage: "magnifyingglass")
                            Spacer()
                            if searching { ProgressView() }
                        }
                    }
                    .folioFormButton()
                    .disabled(searching || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .folioRow()
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(FolioTheme.danger)
                }
                if !matches.isEmpty {
                    Section("Select a Matching Book") {
                        ForEach(matches) { book in
                            Button {
                                link(book)
                            } label: {
                                HStack(spacing: 12) {
                                    FolioMobileRemoteCover(url: book.imageURL, title: book.title)
                                        .frame(width: 48, height: 69)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(book.title).font(.headline)
                                        Text(book.authors).font(.caption).foregroundStyle(FolioTheme.muted)
                                        if let year = book.year {
                                            Text(String(year)).font(.caption2).foregroundStyle(FolioTheme.muted)
                                        }
                                    }
                                    .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "link")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .folioRow()
                }
            }
            .navigationTitle("Match on Hardcover")
            .folioScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .task {
            guard let local = store.book(bookID) else { return }
            if query.isEmpty { query = [local.title, local.author].filter { !$0.isEmpty }.joined(separator: " ") }
            if hardcover.isConnected { await search() }
        }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !searching, hardcover.isConnected else { return }
        searching = true
        defer { searching = false }
        do {
            matches = try await hardcover.search(text)
            error = matches.isEmpty ? "No matching titles. Try a shorter search." : nil
        } catch {
            matches = []
            self.error = error.localizedDescription
        }
    }

    private func link(_ remote: HCBook) {
        store.update(bookID) {
            $0.hardcoverBookID = remote.id
            $0.hardcoverPages = remote.pages
            $0.hardcoverSlug = remote.slug
            $0.hardcoverAutoLinkChecked = true
        }
        if let status = store.book(bookID)?.status.hardcover {
            Task { await hardcover.setStatus(bookID: remote.id, status: status) }
        }
        dismiss()
    }
}
