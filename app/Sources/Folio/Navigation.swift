import SwiftUI
import Observation
import AppKit

/// Pages pushed inside the main window, like Books' author and series pages.
enum BookRoute: Hashable {
    case author(String)
    case series(name: String, hardcoverID: Int?)
}

@Observable
@MainActor
final class Router {
    static let shared = Router()
    var path: [BookRoute] = []
    /// Bumped when a link is followed, so open sheets close and the page is visible.
    var dismissSheets = 0

    func open(_ r: BookRoute) {
        if path.last != r { path.append(r) }
        dismissSheets += 1
        PopupCenter.shared.close()
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }?.makeKeyAndOrderFront(nil)
    }
}

/// Splits a joined author line ("A, B & C") into names.
enum Names {
    static func split(_ s: String) -> [String] {
        s.replacingOccurrences(of: " & ", with: ", ")
            .replacingOccurrences(of: "; ", with: ", ")
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func matches(_ line: String, _ name: String) -> Bool {
        let n = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        return split(line).contains { $0.lowercased().folding(options: .diacriticInsensitive, locale: nil) == n }
            || line.localizedCaseInsensitiveContains(name)
    }
}

/// A text link that underlines on hover, as names do in Books.
struct LinkText: View {
    let text: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(text).underline(hovering).lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .pointerStyle(.link)
        .help(help)
    }
}

struct AuthorLinks: View {
    var line: String
    var placeholder: String = ""

    var body: some View {
        let names = Names.split(line)
        if names.isEmpty {
            Text(placeholder).lineLimit(1)
        } else {
            HStack(spacing: 0) {
                ForEach(Array(names.prefix(3).enumerated()), id: \.offset) { i, n in
                    if i > 0 { Text(", ") }
                    LinkText(text: n, help: "Show books by \(n)") { Router.shared.open(.author(n)) }
                }
                if names.count > 3 { Text(" +\(names.count - 3)") }
            }
            .lineLimit(1)
        }
    }
}

struct SeriesLink: View {
    var name: String
    var index: Double?
    var hardcoverID: Int? = nil

    var label: String {
        guard let index else { return name }
        let n = index == index.rounded() ? String(Int(index)) : String(format: "%g", index)
        return "\(name) · Book \(n)"
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "books.vertical")
            LinkText(text: label, help: "Show the \(name) series") { Router.shared.open(.series(name: name, hardcoverID: hardcoverID)) }
        }
    }
}

// MARK: - Author page

struct AuthorView: View {
    let name: String
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hc
    @State private var remote: [HCBook] = []
    @State private var loading = false
    @State private var detail: HCBook?

    private var local: [LocalBook] { store.books.filter { Names.matches($0.author, name) }.sorted { ($0.series ?? $0.title, $0.seriesIndex ?? 0) < ($1.series ?? $1.title, $1.seriesIndex ?? 0) } }
    private var tracked: [TrackedBook] { store.data.tracked.filter { Names.matches($0.author, name) } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 16) {
                    Image(systemName: "person.crop.circle.fill").font(.system(size: 52)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.largeTitle.weight(.bold))
                        Text("\(local.count) in your library").foregroundStyle(.secondary)
                    }
                }
                let series = Dictionary(grouping: local.filter { $0.series != nil }, by: { $0.series! }).keys.sorted()
                if !series.isEmpty {
                    HStack(spacing: 14) { ForEach(series, id: \.self) { SeriesLink(name: $0, index: nil) } }
                        .font(.callout).foregroundStyle(.secondary)
                }
                if !local.isEmpty {
                    SectionHeader(title: "In Your Library")
                    coverGrid { ForEach(local) { LocalBookCell(book: $0) } }
                }
                if hc.isConnected {
                    SectionHeader(title: "On Hardcover")
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    else if remote.isEmpty { Text("No books found on Hardcover.").foregroundStyle(.secondary) }
                    coverGrid { ForEach(remote) { b in HCBookCell(book: b) { detail = b } } }
                }
                if !tracked.isEmpty {
                    SectionHeader(title: "On Goodreads")
                    coverGrid { ForEach(tracked) { TrackedCell(book: $0) } }
                }
                if local.isEmpty && tracked.isEmpty && !hc.isConnected {
                    Text("Connect Hardcover in Settings to see more books by \(name).").foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .navigationTitle(name)
        .task(id: name) {
            guard hc.isConnected else { return }
            loading = true
            let found = (try? await hc.search(name)) ?? []
            remote = found.filter { Names.matches($0.authors, name) }
            loading = false
        }
        .bookPopup(item: $detail) { HCBookDetail(book: $0) }
    }
}

// MARK: - Series (saga) page

struct SeriesView: View {
    let name: String
    let hardcoverID: Int?
    @Environment(LibraryStore.self) private var store
    @Environment(HardcoverClient.self) private var hc
    @State private var remote: [(position: Double?, book: HCBook)] = []
    @State private var loading = false
    @State private var detail: HCBook?

    private var local: [LocalBook] {
        store.books.filter { $0.series?.caseInsensitiveCompare(name) == .orderedSame }
            .sorted { ($0.seriesIndex ?? .infinity) < ($1.seriesIndex ?? .infinity) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 16) {
                    Image(systemName: "books.vertical.fill").font(.system(size: 44)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.largeTitle.weight(.bold))
                        Text("Series · \(max(local.count, remote.count)) book\(max(local.count, remote.count) == 1 ? "" : "s")").foregroundStyle(.secondary)
                    }
                }
                if !local.isEmpty {
                    SectionHeader(title: "In Your Library")
                    coverGrid {
                        ForEach(local) { b in
                            VStack(alignment: .leading, spacing: 4) {
                                if let i = b.seriesIndex { Text("Book \(i == i.rounded() ? String(Int(i)) : String(format: "%g", i))").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                                LocalBookCell(book: b)
                            }
                        }
                    }
                }
                if hc.isConnected {
                    SectionHeader(title: "On Hardcover")
                    if loading { ProgressView().frame(maxWidth: .infinity) }
                    else if remote.isEmpty { Text("Hardcover doesn't list this series.").foregroundStyle(.secondary) }
                    coverGrid {
                        ForEach(remote, id: \.book.id) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                if let p = item.position { Text("Book \(p == p.rounded() ? String(Int(p)) : String(format: "%g", p))").font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                                HCBookCell(book: item.book) { detail = item.book }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
        }
        .navigationTitle(name)
        .task(id: "\(name)-\(hardcoverID ?? 0)") {
            guard hc.isConnected else { return }
            loading = true
            var id = hardcoverID
            if id == nil { id = try? await hc.seriesID(named: name) }
            if let id { remote = (try? await hc.seriesBooks(id)) ?? [] }
            loading = false
        }
        .bookPopup(item: $detail) { HCBookDetail(book: $0) }
    }
}

@ViewBuilder
func coverGrid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 26, alignment: .top)], alignment: .leading, spacing: 30) {
        content()
    }
}

struct RouteView: View {
    let route: BookRoute
    var body: some View {
        switch route {
        case .author(let n): AuthorView(name: n)
        case .series(let n, let id): SeriesView(name: n, hardcoverID: id)
        }
    }
}
