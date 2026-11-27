// Metadata-only Alloy translation regression using the UNMODIFIED production DownloadQueue.swift.
// All network traffic uses a Python localhost fixture; store is an isolated temp directory.
import Foundation
import Darwin

func report(_ value: String) { print(value); fflush(stdout) }

enum FolioLog { static func log(_ message: String, _ category: String = "app") {} }
enum SourceEvent { case status(String), log(String), transfer(received: Int64, expected: Int64) }

// Register a deterministic URL loading protocol for the *actual* Open Library
// URLSession.shared request inside production DownloadQueue.swift.
// No public provider traffic is needed or permitted for these scenarios.
final class OpenLibraryFixture: URLProtocol {
    static var requests: [String] = []
    static var original = ""
    static var author = ""
    static var translation = ""
    static var language = "spa"
    static var mode = "canonical"
    static let canonical = "/works/OL424242W"
    static let unrelated = "/works/OL999999W"

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "openlibrary.org" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.path
        Self.requests.append(path)
        let payload: [String: Any]
        if path == "/search.json" {
            // The exact same sparse shape returned by Open Library: numFound
            // exists, editions.docs is absent. Only canonical key + verified
            // title and author establish the work's identity.
            payload = ["docs": [
                ["key": Self.unrelated, "title": "Unrelated Work", "author_name": [Self.author],
                 "editions": ["numFound": 2]],
                ["key": Self.canonical, "title": Self.original, "author_name": [Self.author],
                 "editions": ["numFound": 4]],
                ["key": "/works/OL777777W", "title": Self.original,
                 "author_name": ["Wrong Author"], "editions": ["numFound": 1]]
            ]]
        } else if path == Self.canonical + "/editions.json" {
            let editions: [[String: Any]] = [
                ["title": "Collection Omnibus: " + Self.translation,
                 "languages": [["key": "/languages/" + Self.language]]],
                ["title": Self.translation, "languages": [["key": "/languages/eng"]]],
                ["title": Self.translation, "languages": [["key": "/languages/" + Self.language]]]
            ]
            payload = ["size": 3, "entries": Self.mode == "collection-only" ? [editions[0]] : editions]
        } else if path == Self.unrelated + "/editions.json" {
            payload = ["size": 1, "entries": [["title": "Unrelated translation",
                       "languages": [["key": "/languages/" + Self.language]]]]]
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let bytes = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


enum BookLanguage {
    static func code(_ raw: String?) -> String? {
        let aliases = ["spa":"es", "fre":"fr", "ger":"de", "ita":"it", "cat":"ca"]
        let value = raw?.lowercased() ?? ""
        return aliases[value] ?? (["es", "fr", "de", "it", "ca"].contains(value) ? value : nil)
    }
    static var preferred: String { "es" }
    static var reading: String { "es" }
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
    var translatedTitle: String? = nil
    var calls = 0
    func edition(bookID: Int, language code: String) async throws -> Edition? {
        calls += 1
        if response == "429" { throw Failure.rate429 }
        if response == "403" { throw Failure.forbidden403 }
        return bookID > 0 ? translatedTitle.map { Edition(title: $0) } : nil
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
    var translatedTitle = ""
    var author = ""
    var language = "es"
    func loadAll() async {}
    func ensureLoaded() async {}
    func makeJobSession() -> JobSession { JobSession(owner: self) }

    @MainActor final class JobSession {
        let owner: ExtensionStore
        init(owner: ExtensionStore) { self.owner = owner }
        func close() async {}
        func findCopies(title: String, author: String, expectedLanguage: String? = nil,
                        progress: @escaping (String) -> Void = { _ in },
                        onEvent: @escaping (String, SourceEvent) -> Void = { _,_ in }) async
                        -> (copies: [Copy], problems: [String], searched: [String]) {
            progress("Metadata-only multilingual catalogue fixture")
            owner.searched.append(title)
            guard title.localizedCaseInsensitiveCompare(owner.translatedTitle) == .orderedSame else { return ([], [], ["Local catalogue metadata"]) }
            let names = [owner.translatedTitle + " (Omnibus)", owner.translatedTitle]
            let entries = names.enumerated().map { index, name in
                Copy(sourceID: "catalogue", sourceName: "Local catalogue metadata", result: SourceResult(
                    id: "metadata-\(index)", title: name, author: owner.author,
                    language: owner.language, downloadCount: nil,
                    preferred: SourceDownload(format: "epub", url: URL(string: "https://example.invalid/metadata-only")!)))
            }
            return (entries, [], ["Local catalogue metadata"])
        }
        func download(_ result: SourceResult, from id: String, into library: LibraryStore,
                      onEvent: @escaping (SourceEvent) -> Void = { _ in }) async throws -> UUID {
            // No copyrighted files, downloads or network requests in this test.
            owner.searched.append("CANDIDATE: " + result.title)
            throw NSError(domain: "Metadata-only fixture; download intentionally disabled", code: 0)
        }
    }
}

@main struct SparseEditionFallbackTest {
    struct Example {
        let title: String
        let translated: String
        let author: String
        let language: String
        let marc: String
    }
    @MainActor static func main() async throws {
        let _ = LibraryStore.shared.baseDir
        guard URLProtocol.registerClass(OpenLibraryFixture.self) else { fatalError("Unable to intercept Open Library") }
        let queue = DownloadQueue.shared
        let source = ExtensionStore.shared
        let hardcover = HardcoverClient.shared
        let scenarios: [Example] = [
            Example(title: "The Alloy of Law", translated: "Aleación de ley", author: "Brandon Sanderson", language: "es", marc: "spa"),
            Example(title: "The Little Prince", translated: "Le Petit Prince", author: "Antoine de Saint-Exupéry", language: "fr", marc: "fre"),
            Example(title: "The Little Prince", translated: "Der kleine Prinz", author: "Antoine de Saint-Exupéry", language: "de", marc: "ger")
        ]
        if CommandLine.arguments.contains("--fixture-contract") {
            // Specify acceptance independently of the queue under test. This
            // fixture must never select an unrelated work, a compilation, or
            // an edition with the wrong declared language.
            for scenario in scenarios {
                let workRecords: [(key: String, title: String, author: String)] = [
                    (OpenLibraryFixture.unrelated, "Unrelated Work", scenario.author),
                    (OpenLibraryFixture.canonical, scenario.title, scenario.author),
                    ("/works/OL777777W", scenario.title, "Wrong Author")
                ]
                let verified = workRecords.filter {
                    BookAutoMatch.sameTitle($0.title, scenario.title) &&
                    BookAutoMatch.sameEditionAuthor(scenario.author, $0.author)
                }
                guard verified.count == 1, verified[0].key == OpenLibraryFixture.canonical else {
                    fatalError("Incorrect canonical work identity")
                }
                let editions: [(title: String, language: String)] = [
                    ("Collection Omnibus: " + scenario.translated, scenario.marc),
                    (scenario.translated, "eng"),
                    (scenario.translated, scenario.marc)
                ]
                let safe = editions.filter {
                    $0.language == scenario.marc && DownloadQueue.isStandaloneEditionTitle($0.title)
                }
                guard safe.count == 1, safe[0].title == scenario.translated else {
                    fatalError("Unsafe or wrong-language edition accepted")
                }
                report("PASS CONTRACT: \(scenario.language) canonical work verified; unrelated work, omnibus, wrong language rejected")
            }
            return
        }
        var successes = 0
        for (index, scenario) in scenarios.enumerated() {
            source.searched = []
            source.translatedTitle = scenario.translated
            source.author = scenario.author
            source.language = scenario.language
            hardcover.response = "429"
            hardcover.translatedTitle = nil
            OpenLibraryFixture.original = scenario.title
            OpenLibraryFixture.author = scenario.author
            OpenLibraryFixture.translation = scenario.translated
            OpenLibraryFixture.language = scenario.marc
            OpenLibraryFixture.mode = "canonical"
            OpenLibraryFixture.requests = []
            let start = Date()
            let id = queue.enqueue(title: scenario.title, author: scenario.author,
                                   hardcoverBookID: 1000 + index, expectedLanguage: scenario.language)
            try await wait(queue: queue, id: id)
            let searched = source.searched.filter { !$0.hasPrefix("CANDIDATE:") }
            let candidates = source.searched.filter { $0.hasPrefix("CANDIDATE:") }
            let queriedCanonical = OpenLibraryFixture.requests.contains(OpenLibraryFixture.canonical + "/editions.json")
            let queriedUnrelated = OpenLibraryFixture.requests.contains(OpenLibraryFixture.unrelated + "/editions.json")
            let correct = searched.count == 1 && searched.first == scenario.translated &&
                          candidates == ["CANDIDATE: " + scenario.translated] && queriedCanonical && !queriedUnrelated
            if correct { successes += 1 }
            report("\(correct ? "PASS" : "EXPECTED RED") \(scenario.language) \(scenario.title) search=\(searched) candidates=\(candidates) requests=\(OpenLibraryFixture.requests) elapsed=\(String(format: "%.3f", Date().timeIntervalSince(start)))s")
            queue.dismiss(id)
        }
        // This is a regression specification: RED on pre-fallback production;
        // it must become green once canonical work editions.json is supported.
        report("CANONICAL WORK SPARSE-EDITION FALLBACK: \(successes)/\(scenarios.count) successful")
        guard successes == scenarios.count else {
            fputs("FAIL: sparse canonical work editions.json fallback missing or incorrect\n", stderr)
            exit(1)
        }
    }
    @MainActor static func wait(queue: DownloadQueue, id: UUID) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < 5 {
            if queue.jobs.first(where: { $0.id == id })?.stage == .failed { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        fatalError("Metadata-only queue did not settle")
    }
}
