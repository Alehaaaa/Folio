import Foundation
import Observation

enum ReadingAnnotationKind: String, Codable, CaseIterable, Identifiable {
    case bookmark, highlight, note, quote

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bookmark: "Bookmark"
        case .highlight: "Highlight"
        case .note: "Note"
        case .quote: "Quote"
        }
    }

    var symbol: String {
        switch self {
        case .bookmark: "bookmark.fill"
        case .highlight: "highlighter"
        case .note: "note.text"
        case .quote: "quote.bubble"
        }
    }
}

struct ReadingAnnotation: Codable, Identifiable, Hashable {
    var id: UUID
    var bookID: UUID
    var chapter: Int
    /// Position within the chapter, in the range 0...1.
    var fraction: Double
    var kind: ReadingAnnotationKind
    var text: String
    /// Surrounding text helps relocate a selection after repagination.
    var prefix: String
    var suffix: String
    var note: String
    var createdAt: Date
    /// Stored corner of a folded page: topLeft, topRight, bottomLeft, or bottomRight.
    /// Nil in older saved bookmarks is displayed as topRight.
    var corner: String?

    var displayCorner: String { Self.normalizedCorner(corner) }

    static func normalizedCorner(_ value: String?) -> String {
        switch value {
        case "topLeft", "topRight", "bottomLeft", "bottomRight": value!
        default: "topRight"
        }
    }

    init(
        id: UUID = UUID(),
        bookID: UUID,
        chapter: Int,
        fraction: Double,
        kind: ReadingAnnotationKind,
        text: String = "",
        prefix: String = "",
        suffix: String = "",
        note: String = "",
        createdAt: Date = Date(),
        corner: String? = nil
    ) {
        self.id = id
        self.bookID = bookID
        self.chapter = max(0, chapter)
        self.fraction = fraction.isFinite ? min(1, max(0, fraction)) : 0
        self.kind = kind
        self.text = text
        self.prefix = prefix
        self.suffix = suffix
        self.note = note
        self.createdAt = createdAt
        self.corner = corner
    }

    private enum CodingKeys: String, CodingKey {
        case id, bookID, chapter, fraction, kind, text, prefix, suffix, note, createdAt, corner
    }

    /// Keep IDs and positions strict while accepting missing older text fields.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        bookID = try values.decode(UUID.self, forKey: .bookID)
        chapter = try values.decode(Int.self, forKey: .chapter)
        fraction = try values.decode(Double.self, forKey: .fraction)
        kind = try values.decode(ReadingAnnotationKind.self, forKey: .kind)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        text = (try? values.decode(String.self, forKey: .text)) ?? ""
        prefix = (try? values.decode(String.self, forKey: .prefix)) ?? ""
        suffix = (try? values.decode(String.self, forKey: .suffix)) ?? ""
        note = (try? values.decode(String.self, forKey: .note)) ?? ""
        corner = try? values.decodeIfPresent(String.self, forKey: .corner)
        guard chapter >= 0, fraction.isFinite, (0...1).contains(fraction) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid reading position")
            )
        }
    }
}

/// Persisted, observable annotations keyed by the stable LocalBook.id.
@MainActor
@Observable
final class ReadingAnnotationsStore {
    static let shared = ReadingAnnotationsStore()

    /// Fallback match distance, approximately a page in a short chapter.
    private static let defaultBookmarkTolerance = 0.02

    private(set) var entries: [ReadingAnnotation] = []
    private let dataURL: URL
    private var needsCorruptBackup = false
    private(set) var lastError: String?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory: URL
        if let custom = ProcessInfo.processInfo.environment["FOLIO_DATA_DIR"], !custom.isEmpty {
            directory = URL(fileURLWithPath: custom, isDirectory: true)
        } else {
            directory = support.appendingPathComponent("Folio", isDirectory: true)
        }
        dataURL = directory.appendingPathComponent("reading-annotations.json")
        load()
    }

    /// Annotations sorted by their location in the book.
    func items(for bookID: UUID) -> [ReadingAnnotation] {
        entries.filter { $0.bookID == bookID }.sorted {
            if $0.chapter != $1.chapter { return $0.chapter < $1.chapter }
            if $0.fraction != $1.fraction { return $0.fraction < $1.fraction }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    @discardableResult
    func add(
        bookID: UUID,
        chapter: Int,
        fraction: Double,
        kind: ReadingAnnotationKind,
        text: String,
        prefix: String,
        suffix: String,
        note: String
    ) -> ReadingAnnotation {
        let annotation = ReadingAnnotation(
            bookID: bookID, chapter: chapter, fraction: fraction, kind: kind,
            text: text, prefix: prefix, suffix: suffix, note: note
        )
        entries.append(annotation)
        save()
        return annotation
    }

    func updateNote(id: UUID, note: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].note != note else { return }
        entries[index].note = note
        save()
    }

    func remove(id: UUID) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        save()
    }

    /// Returns the nearest page-fold bookmark for this position.
    /// Passing pageCount compares actual paginated pages; without it a small chapter
    /// fraction tolerance is used for older callers and scrolling layouts.
    func bookmark(
        bookID: UUID, chapter: Int, fraction: Double, pageCount: Int? = nil
    ) -> ReadingAnnotation? {
        let location = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return entries
            .filter {
                $0.bookID == bookID && $0.chapter == chapter && $0.kind == .bookmark
                    && Self.isSamePage($0.fraction, location, pageCount: pageCount)
            }
            .min { abs($0.fraction - location) < abs($1.fraction - location) }
    }

    private static func isSamePage(
        _ storedFraction: Double, _ currentFraction: Double, pageCount: Int?
    ) -> Bool {
        guard let pageCount, pageCount > 0 else {
            return abs(storedFraction - currentFraction) <= defaultBookmarkTolerance
        }
        func page(_ fraction: Double) -> Double {
            min(Double(pageCount - 1), floor(min(1, max(0, fraction)) * Double(pageCount)))
        }
        return page(storedFraction) == page(currentFraction)
    }

    /// Folding the same corner again clears the bookmark; folding another corner moves it.
    /// Exactly one bookmark is retained for the matched page.
    func toggleBookmark(
        bookID: UUID, chapter: Int, fraction: Double, pageCount: Int? = nil,
        corner: String = "topRight"
    ) {
        let requestedCorner = ReadingAnnotation.normalizedCorner(corner)
        if let existing = bookmark(
            bookID: bookID, chapter: chapter, fraction: fraction, pageCount: pageCount
        ) {
            let position = fraction.isFinite ? min(1, max(0, fraction)) : 0
            let samePageIDs = Set(entries.filter {
                $0.kind == .bookmark && $0.bookID == bookID && $0.chapter == chapter
                    && Self.isSamePage($0.fraction, position, pageCount: pageCount)
            }.map(\.id))
            if existing.displayCorner == requestedCorner {
                entries.removeAll { samePageIDs.contains($0.id) }
            } else {
                entries.removeAll { $0.id != existing.id && samePageIDs.contains($0.id) }
                if let index = entries.firstIndex(where: { $0.id == existing.id }) {
                    entries[index].corner = requestedCorner
                }
            }
            save()
        } else {
            let annotation = ReadingAnnotation(
                bookID: bookID, chapter: chapter, fraction: fraction,
                kind: .bookmark, corner: requestedCorner
            )
            entries.append(annotation)
            save()
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: dataURL.path) else { return }
        do {
            let contents = try Data(contentsOf: dataURL)
            let decoder = JSONDecoder()
            let loaded: [ReadingAnnotation]
            if let archive = try? decoder.decode(AnnotationsArchive.self, from: contents) {
                loaded = archive.items
            } else {
                loaded = try decoder.decode(LossyAnnotations.self, from: contents).items
            }
            var seen = Set<UUID>()
            entries = loaded.filter { seen.insert($0.id).inserted }
        } catch {
            needsCorruptBackup = true
            lastError = "Could not read saved annotations: \(error.localizedDescription)"
        }
    }

    private func save() {
        do {
            let directory = dataURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if needsCorruptBackup && FileManager.default.fileExists(atPath: dataURL.path) {
                let backup = directory.appendingPathComponent(
                    "reading-annotations-corrupt-\(UUID().uuidString).json"
                )
                try FileManager.default.copyItem(at: dataURL, to: backup)
                needsCorruptBackup = false
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let encoded = try encoder.encode(AnnotationsArchive(items: entries))
            try encoded.write(to: dataURL, options: .atomic)
            lastError = nil
        } catch {
            lastError = "Could not save annotations: \(error.localizedDescription)"
        }
    }
}

/// Versioned envelope with graceful recovery of valid entries in a damaged list.
private struct AnnotationsArchive: Codable {
    var version = 1
    var items: [ReadingAnnotation]

    private enum CodingKeys: String, CodingKey { case version, items }

    init(items: [ReadingAnnotation]) { self.items = items }

    init(from decoder: Decoder) throws {
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? keyed.decode(Int.self, forKey: .version)) ?? 1
        items = try keyed.decode(LossyAnnotations.self, forKey: .items).items
    }
}

private struct LossyAnnotations: Decodable {
    var items: [ReadingAnnotation]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        items = []
        while !container.isAtEnd {
            let itemDecoder = try container.superDecoder()
            if let annotation = try? ReadingAnnotation(from: itemDecoder) {
                items.append(annotation)
            }
        }
    }
}
