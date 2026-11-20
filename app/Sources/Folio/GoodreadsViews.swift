import SwiftUI
import UniformTypeIdentifiers

struct CSVDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(data: configuration.file.regularFileContents ?? Data(), encoding: .utf8) ?? ""
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct TrackedCell: View {
    let book: TrackedBook
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            CoverArt(title: book.title, author: book.author, remote: book.coverURL.flatMap(URL.init(string:)))
                .onTapGesture { PopupCenter.shared.show(AnyView(GoodreadsBookDetail(book: book))) {} }
            Text(book.title).font(.callout.weight(.semibold)).lineLimit(2)
                .onTapGesture { PopupCenter.shared.show(AnyView(GoodreadsBookDetail(book: book))) {} }
            AuthorLinks(line: book.author).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if book.rating > 0 { StarRating(rating: Double(book.rating), size: 9) }
                if book.sentToHardcover {
                    Image(systemName: "checkmark.icloud").foregroundStyle(.green).help("On Hardcover")
                }
            }
            .font(.caption2)
        }
        .contextMenu {
            Button("Read") {
                readBook(title: book.title, author: book.author, hardcoverBookID: book.hardcoverBookID, hardcoverPages: book.pages,
                         cover: book.coverURL.flatMap(URL.init(string:)), openWindow: openWindow)
            }
            Divider()
            if let link = book.link, let url = URL(string: link) { Button("Open on Goodreads") { NSWorkspace.shared.open(url) } }
            ForEach(Names.split(book.author).prefix(4), id: \.self) { n in
                Button("Go to \(n)") { Router.shared.open(.author(n)) }
            }
            Divider()
            Button("Copy Title") { copy(book.title) }
            if let isbn = book.isbn13 ?? book.isbn { Button("Copy ISBN") { copy(isbn) } }
        }
    }
}
