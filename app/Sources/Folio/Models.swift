import Foundation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Formats

enum BookFormat: String, Codable, CaseIterable {
    case epub, pdf, text, markdown, html, rtf, comic

    var label: String {
        switch self {
        case .epub: "EPUB"
        case .pdf: "PDF"
        case .text: "Text"
        case .markdown: "Markdown"
        case .html: "Web page"
        case .rtf: "Rich text"
        case .comic: "Comic"
        }
    }

    var symbol: String {
        switch self {
        case .epub: "book.closed"
        case .pdf: "doc.richtext"
        case .text, .markdown, .rtf: "doc.plaintext"
        case .html: "globe"
        case .comic: "photo.on.rectangle"
        }
    }

    static func from(url: URL) -> BookFormat? {
        switch url.pathExtension.lowercased() {
        case "epub": return .epub
        case "pdf": return .pdf
        case "txt", "text": return .text
        case "md", "markdown", "textbundle": return .markdown
        case "html", "htm", "xhtml": return .html
        case "rtf", "rtfd": return .rtf
        case "cbz": return .comic
        default:
            // Expanded packages may also arrive without a file extension.
            var isDirectory: ObjCBool = false
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
            if fm.fileExists(atPath: url.appendingPathComponent("META-INF/container.xml").path) { return .epub }
            if fm.fileExists(atPath: url.appendingPathComponent("TXT.rtf").path) { return .rtf }
            if fm.fileExists(atPath: url.appendingPathComponent("text.md").path) { return .markdown }
            return nil
        }
    }

    static var importTypes: [UTType] {
        var types: [UTType] = [.epub, .pdf, .plainText, .rtf, .html, .package, .folder]
        for ext in ["md", "markdown", "cbz", "xhtml", "rtfd", "textbundle"] {
            if let t = UTType(filenameExtension: ext) { types.append(t) }
        }
        return types
    }
}

// MARK: - Local reading status (mirrors Books' Want to Read / Finished collections)

enum ReadingStatus: String, Codable, CaseIterable, Identifiable {
    case none, wantToRead, reading, finished
    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: "No Status"
        case .wantToRead: "Want to Read"
        case .reading: "Reading"
        case .finished: "Finished"
        }
    }

    var symbol: String {
        switch self {
        case .none: "circle.dashed"
        case .wantToRead: "bookmark"
        case .reading: "book"
        case .finished: "checkmark.circle"
        }
    }

    var hardcover: HCStatus? {
        switch self {
        case .none: nil
        case .wantToRead: .wantToRead
        case .reading: .reading
        case .finished: .read
        }
    }
}

struct ReadingPosition: Codable, Hashable {
    var chapter: Int = 0
    var fraction: Double = 0
    var pdfPage: Int = 0
}

struct LocalBook: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var author: String
    var format: BookFormat
    var fileName: String
    var addedAt = Date()
    var lastOpenedAt: Date?
    var progress: Double = 0
    var position = ReadingPosition()
    var status: ReadingStatus = .none
    var finishedAt: Date?
    var collections: Set<UUID> = []
    var coverFileName: String?
    var hardcoverBookID: Int?
    var hardcoverPages: Int?
    var hardcoverSlug: String?
    var isbn: String?
    /// Library-only descriptive fields; optional for backwards-compatible saved libraries.
    var summary: String?
    var publishedYear: Int?
    var publisher: String?
    var language: String?
    /// Prevents re-linking after a manual unlink or a completed, inconclusive lookup.
    var hardcoverAutoLinkChecked: Bool?
    /// Set when the reader removed the Hardcover link, so pages never re-link it.
    var hardcoverManuallyUnlinked: Bool?
    /// The Hardcover edition in the file's language (e.g. the Spanish edition),
    /// while hardcoverBookID stays the work for ratings, reviews and series.
    var hardcoverEditionID: Int?
    /// Genres chosen in Edit Details.
    var genres: [String]?
    var syncedProgressPages: Int?
    var series: String?
    var seriesIndex: Double?
    var seriesChecked: Bool?
    /// Set once Hardcover was asked for the series of a linked book that had none.
    var seriesHardcoverChecked: Bool?

    var progressLabel: String {
        if status == .finished { return "Finished" }
        if progress <= 0.001 { return lastOpenedAt == nil ? "New" : "0%" }
        return "\(Int((progress * 100).rounded()))%"
    }
}

struct BookCollection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

struct ReadingGoals: Codable, Hashable {
    var dailyMinutes: Int = 5      // estimated: see MECHANICS.md
    var booksPerYear: Int = 3      // estimated: see MECHANICS.md
}

/// A book brought in from a Goodreads export (no file attached).
struct TrackedBook: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var author: String
    var isbn: String?
    var isbn13: String?
    var shelf: String          // to-read, currently-reading, read, or a custom exclusive shelf
    var rating: Int            // 0 = unrated, 1-5
    var dateRead: String?
    var dateAdded: String?
    var pages: Int?
    var year: Int?
    var goodreadsID: String?
    var hardcoverBookID: Int?
    var sentToHardcover = false
    var coverURL: String?
    var averageRating: Double?
    var link: String?

    var status: HCStatus? {
        switch shelf {
        case "to-read": .wantToRead
        case "currently-reading": .reading
        case "read": .read
        case "did-not-finish", "dnf", "abandoned": .dnf
        case "paused", "on-hold": .paused
        default: nil
        }
    }
}

struct LibraryData: Codable {
    var books: [LocalBook] = []
    var collections: [BookCollection] = []
    var secondsByDay: [String: Double] = [:]
    var goals = ReadingGoals()
    var tracked: [TrackedBook] = []
}

enum LibraryFilter: String, CaseIterable, Hashable, Identifiable {
    case all, wantToRead, reading, finished, books, pdfs, documents
    var id: String { rawValue }

    /// Reading statuses live in the unified My Shelves section instead of appearing twice.
    static let libraryCategories: [LibraryFilter] = [.all, .books, .pdfs, .documents]

    var unifiedShelf: HCStatus? {
        switch self {
        case .wantToRead: .wantToRead
        case .reading: .reading
        case .finished: .read
        case .all, .books, .pdfs, .documents: nil
        }
    }

    var label: String {
        switch self {
        case .all: "All"
        case .wantToRead: "Want to Read"
        case .reading: "Reading Now"
        case .finished: "Finished"
        case .books: "Books"
        case .pdfs: "PDFs"
        case .documents: "Documents & Comics"
        }
    }

    var symbol: String {
        switch self {
        case .all: "books.vertical"
        case .wantToRead: "bookmark"
        case .reading: "book"
        case .finished: "checkmark.circle"
        case .books: "book.closed"
        case .pdfs: "doc.richtext"
        case .documents: "doc.on.doc"
        }
    }

    func includes(_ b: LocalBook) -> Bool {
        switch self {
        case .all: true
        case .wantToRead: b.status == .wantToRead
        case .reading: b.status == .reading || (b.status == .none && b.progress > 0.001)
        case .finished: b.status == .finished
        case .books: b.format == .epub
        case .pdfs: b.format == .pdf
        case .documents: ![.epub, .pdf].contains(b.format)
        }
    }
}

extension Date {
    var dayKey: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: self)
    }

    var isoDay: String { dayKey }
}
