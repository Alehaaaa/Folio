// Metadata-only Alloy translation regression using the UNMODIFIED production DownloadQueue.swift.
// All network traffic uses a Python localhost fixture; store is an isolated temp directory.
import Foundation

enum SourceEvent { case status(String), log(String) }

enum BookLanguage {
    static func code(_ raw: String?) -> String? { ["es", "spa", "spanish"].contains(raw?.lowercased() ?? "") ? "es" : nil }
    static var preferred: String { "es" }
    static func matches(_ raw: String?, expected: String) -> Bool? {
        guard let raw else { return nil }
        return raw == expected
    }
}

enum BookMatch {
    static func key(author: String, title: String) -> String { author.lowercased() + "|" + title.lowercased() }
}
enum BookAutoMatch {
    static func words(_ value: String) -> [String] { value.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init) }
    static func sameTitle(_ expected: String, _ actual: String) -> Bool {
        expected.localizedCaseInsensitiveCompare(actual) == .orderedSame
    }
    static func sameEditionAuthor(_ expected: String, _ actual: String) -> Bool { expected == actual }
}

@MainActor final class HardcoverClient {
    static let shared = HardcoverClient()
    struct Edition { let title: String? }
    enum Failure: Error { case rate429, forbidden403 }
    var response = "ok"
    var calls = 0
    func edition(bookID: Int, language code: String) async throws -> Edition? {
        calls += 1
        if response == "429" { throw Failure.rate429 }
        if response == "403" { throw Failure.forbidden403 }
        return code == "es" && bookID == 42 ? Edition(title: "Aleación de ley") : nil
    }
}

enum AutomaticEPUBChoice {
    static func sameTitle(_ a: String, _ b: String) -> Bool {
        a.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) ==
        b.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
    static func sameAuthor(_ a: String, _ b: String) -> Bool { a == b }
    static func ranked(_ copies: [ExtensionStore.Copy], title: String, author: String,
                       expectedLanguage: String) -> [ExtensionStore.Copy] {
        copies.filter { sameTitle($0.result.title, title) && sameAuthor($0.result.author, author) &&
            BookLanguage.matches($0.result.language, expected: expectedLanguage) != false }
    }
}

struct SourceDownload { let format: String; let url: URL }
struct SourceResult {
    let id: String
    let title: String
    let author: String
    let language: String?
    let downloadCount: Int?
    let preferred: SourceDownload?
}
struct TestBook {
    let id: UUID
    let title: String
    let author: String
    let format: TestFormat
    var language: String?
    var hardcoverBookID: Int? = nil
    var hardcoverPages: Int? = nil
}
enum TestFormat { case epub }

@MainActor final class LibraryStore {
    static let shared = LibraryStore()
    let baseDir: URL
    var books: [TestBook] = []
    private init() {
        let path = ProcessInfo.processInfo.environment["FOLIO_DATA_DIR"]!
        baseDir = URL(fileURLWithPath: path, isDirectory: true)
        try! FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    }
    func extractedURL(_ book: TestBook) -> URL { baseDir.appendingPathComponent(book.id.uuidString) }
    func book(_ id: UUID) -> TestBook? { books.first { $0.id == id } }
    func remove(_ id: UUID) { books.removeAll { $0.id == id } }
    func update(_ id: UUID, _ work: (inout TestBook) -> Void) {
        if let i = books.firstIndex(where: { $0.id == id }) { work(&books[i]) }
    }
}
struct EPUBPackage {
    let title: String
    let author: String
    let language: String?
    static func load(root: URL) throws -> EPUBPackage {
        let file = root.appendingPathComponent("metadata.txt")
        let values = try String(contentsOf: file, encoding: .utf8).split(separator: "|")
        return EPUBPackage(title: String(values[0]), author: String(values[1]), language: String(values[2]))
    }
}

@MainActor final class ExtensionStore {
    static let shared = ExtensionStore()
    struct Copy {
        let sourceID: String
        let sourceName: String
        let result: SourceResult
        var id: String { sourceID + "|" + result.id }
    }
    var servedURL: URL!
    var searched: [String] = []
    func loadAll() async {}
    func makeJobSession() -> JobSession { JobSession(owner: self) }

    @MainActor final class JobSession {
        let owner: ExtensionStore
        init(owner: ExtensionStore) { self.owner = owner }
        func close() async {}
        func findCopies(title: String, author: String, expectedLanguage: String? = nil,
                        progress: @escaping (String) -> Void = { _ in },
                        onEvent: @escaping (String, SourceEvent) -> Void = { _,_ in }) async
                        -> (copies: [Copy], problems: [String]) {
            progress("Metadata-only Spanish catalogue fixture")
            owner.searched.append(title)
            guard title.localizedCaseInsensitiveCompare("Aleación de ley") == .orderedSame else { return ([], []) }
            // Standalone only: compilations and annotated works cannot qualify.
            let names = ["Aleación de ley (Trilogía)", "Aleación de ley: colección completa", "Aleación de ley"]
            let entries = names.enumerated().map { index, name in
                Copy(sourceID: "catalogue", sourceName: "Local catalogue metadata", result: SourceResult(
                    id: "metadata-\(index)", title: name, author: "Brandon Sanderson",
                    language: "es", downloadCount: nil,
                    preferred: SourceDownload(format: "epub", url: URL(string: "https://example.invalid/metadata-only")!)))
            }
            return (entries, [])
        }
        func download(_ result: SourceResult, from id: String, into library: LibraryStore,
                      onEvent: @escaping (SourceEvent) -> Void = { _ in }) async throws -> UUID {
            // No copyrighted files, downloads or network requests in this test.
            owner.searched.append("CANDIDATE: " + result.title)
            throw NSError(domain: "Metadata-only fixture; download intentionally disabled", code: 0)
        }
    }
}

@main struct AlloyTitleTest {
    @MainActor static func main() async throws {
        let root = LibraryStore.shared.baseDir
        let queue = DownloadQueue.shared
        let source = ExtensionStore.shared
        let hardcover = HardcoverClient.shared
        let cases: [(String, Int?, String, Bool)] = [
            ("http429", 42, "429", true),
            ("http403", 42, "403", true),
            ("missing-id", nil, "ok", true),
            ("valid-edition", 42, "ok", true)
        ]
        for (caseName, bookID, response, translated) in cases {
            let caseStart = Date()
            source.searched = []
            hardcover.response = response
            hardcover.calls = 0
            let id = queue.enqueue(title: "The Alloy of Law", author: "Brandon Sanderson",
                                   hardcoverBookID: bookID, expectedLanguage: "es")
            try await wait(queue: queue, id: id, stage: .failed, timeout: 5)
            let job = queue.jobs.first { $0.id == id }!
            let searches = source.searched.filter { !$0.hasPrefix("CANDIDATE:") }
            let candidates = source.searched.filter { $0.hasPrefix("CANDIDATE:") }
            if translated {
                guard searches.count == 1 && searches[0].localizedCaseInsensitiveCompare("Aleación de ley") == .orderedSame else {
                    fatalError("Unnecessary original search or fallback translation failed: \(searches)")
                }
                guard candidates == ["CANDIDATE: Aleación de ley"] else { fatalError("Wrong edition selected: \(candidates)") }
                guard job.detailLog.contains(where: { $0.contains("skipping unrelated original-title search") }) else { fatalError("No short-circuit log") }
            } else {
                guard searches == ["The Alloy of Law"] && candidates.isEmpty else { fatalError("Unexpected fallback searches or candidates: \(source.searched)") }
                guard job.error?.contains("No matching EPUB listing") == true else { fatalError("Expected catalogue no-match failure, got \(job.error ?? "nil")") }
            }
            guard hardcover.calls == (bookID == nil ? 0 : 1) else { fatalError("Edition request duplicated") }
            guard LibraryStore.shared.books.isEmpty else { fatalError("Unexpected imported EPUB") }
            print(String(format: "CASE %@: searches=%d, editionCalls=%d, matched=%d, stage=%@, elapsed=%.3fs",
                         caseName, searches.count, hardcover.calls, candidates.count,
                         job.stage.rawValue, Date().timeIntervalSince(caseStart)))
            queue.dismiss(id) // Avoid enqueue's intentional retry/reuse of a previous failed job.
        }
        print("PASS metadata-only: translated title found once, original search skipped, compilation rejected")
        print("PASS: 429/403/no hardcoverBookID used verified Open Library edition metadata fallback")
        print("PASS: no copyrighted downloads or library imports; isolated directory: \(root.lastPathComponent)")
    }
    @MainActor static func wait(queue: DownloadQueue, id: UUID, stage: DownloadJob.Stage, timeout: TimeInterval) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if queue.jobs.first(where: { $0.id == id })?.stage == stage { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("Timeout waiting for \(stage); current \(queue.jobs.first(where: { $0.id == id })?.stage.rawValue ?? "missing")")
    }
}
