// Metadata-only Alloy translation regression using the UNMODIFIED production DownloadQueue.swift.
// All network traffic uses a Python localhost fixture; store is an isolated temp directory.
import Foundation

enum SourceEvent { case status(String), log(String) }

// Register a deterministic URL loading protocol for the *actual* Open Library
// URLSession.shared request inside production DownloadQueue.swift.
// No public provider traffic is needed or permitted for these scenarios.
final class OpenLibraryFixture: URLProtocol {
    static var calls = 0
    static var sparse = false
    static var translation = ""
    static var original = ""
    static var author = ""
    static var language = "spa"
    static var requestedLanguages: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "openlibrary.org" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        let queryLanguage = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "language" })?.value ?? ""
        Self.requestedLanguages.append(queryLanguage)
        let editions: [[String: Any]] = [["title": Self.translation + " / " + Self.original,
                                          "language": [Self.language]]]
        let payload: [String: Any] = ["docs": [["title": Self.original,
            "author_name": [Self.author], "editions": Self.sparse ? ["numFound": 3] : ["docs": editions]]]]
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
                        -> (copies: [Copy], problems: [String]) {
            progress("Metadata-only multilingual catalogue fixture")
            owner.searched.append(title)
            guard title.localizedCaseInsensitiveCompare(owner.translatedTitle) == .orderedSame else { return ([], []) }
            let names = [owner.translatedTitle + " (Omnibus)", owner.translatedTitle]
            let entries = names.enumerated().map { index, name in
                Copy(sourceID: "catalogue", sourceName: "Local catalogue metadata", result: SourceResult(
                    id: "metadata-\(index)", title: name, author: owner.author,
                    language: owner.language, downloadCount: nil,
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

@main struct MultilingualTitleTest {
    struct Case {
        let original: String
        let translated: String
        let author: String
        let language: String
        let alpha3: String
    }
    @MainActor static func main() async throws {
        let _ = LibraryStore.shared.baseDir
        guard URLProtocol.registerClass(OpenLibraryFixture.self) else { fatalError("URLProtocol not installed") }
        let sparse = CommandLine.arguments.contains("--sparse-metadata")
        OpenLibraryFixture.sparse = sparse
        let queue = DownloadQueue.shared
        let source = ExtensionStore.shared
        let hardcover = HardcoverClient.shared
        let cases = [
            Case(original: "The Alloy of Law", translated: "Aleación de ley", author: "Brandon Sanderson", language: "es", alpha3: "spa"),
            Case(original: "The Name of the Wind", translated: "El nombre del viento", author: "Patrick Rothfuss", language: "es", alpha3: "spa"),
            Case(original: "Dune", translated: "Duna", author: "Frank Herbert", language: "es", alpha3: "spa"),
            Case(original: "The Little Prince", translated: "El principito", author: "Antoine de Saint-Exupéry", language: "es", alpha3: "spa"),
            Case(original: "The Little Prince", translated: "Le Petit Prince", author: "Antoine de Saint-Exupéry", language: "fr", alpha3: "fre"),
            Case(original: "The Little Prince", translated: "Der kleine Prinz", author: "Antoine de Saint-Exupéry", language: "de", alpha3: "ger"),
            Case(original: "The Little Prince", translated: "Il piccolo principe", author: "Antoine de Saint-Exupéry", language: "it", alpha3: "ita"),
            Case(original: "The Little Prince", translated: "El petit príncep", author: "Antoine de Saint-Exupéry", language: "ca", alpha3: "cat")
        ]
        var failures: [String] = []
        for (scenarioIndex, scenario) in (sparse ? ["no-id", "hardcover-429"] : ["no-id", "hardcover-429", "hardcover-available"]).enumerated() {
            for (caseIndex, item) in cases.enumerated() {
                source.searched = []
                source.translatedTitle = item.translated
                source.author = item.author
                source.language = item.language
                hardcover.translatedTitle = item.translated
                hardcover.calls = 0
                hardcover.response = scenario == "hardcover-available" ? "ok" : "429"
                OpenLibraryFixture.original = item.original
                OpenLibraryFixture.translation = item.translated
                OpenLibraryFixture.author = item.author
                OpenLibraryFixture.language = item.alpha3
                let oldCalls = OpenLibraryFixture.calls
                let start = Date()
                let id = queue.enqueue(title: item.original, author: item.author,
                                       hardcoverBookID: scenario == "no-id" ? nil : 1000 + scenarioIndex * 100 + caseIndex,
                                       expectedLanguage: item.language)
                try await wait(queue: queue, id: id, stage: .failed, timeout: 5)
                let searched = source.searched.filter { !$0.hasPrefix("CANDIDATE:") }
                let selected = source.searched.filter { $0.hasPrefix("CANDIDATE:") }
                let exact = searched.count == 1 &&
                    searched[0].localizedCaseInsensitiveCompare(item.translated) == .orderedSame &&
                    selected == ["CANDIDATE: " + item.translated]
                let passed = sparse ? searched == [item.original] && selected.isEmpty : exact
                let delta = OpenLibraryFixture.calls - oldCalls
                let label = "\(scenario) \(item.language) \(item.original)"
                if !passed { failures.append(label) }
                print(String(format: "%@ %@ | %@ | %@ | OL=%d HC=%d searches=%d exact=%d elapsed=%.3fs",
                      passed ? "PASS" : "MISS", scenario, item.language, item.original,
                      delta, hardcover.calls, searched.count, selected.count,
                      Date().timeIntervalSince(start)))
                queue.dismiss(id)
            }
        }
        print("TOTAL cases=\(cases.count * (sparse ? 2 : 3)) unexpectedOutcomes=\(failures.count) openLibraryCalls=\(OpenLibraryFixture.calls) sparseMetadata=\(sparse)")
        let expectedLanguageRequests = cases.map(\.alpha3)
        guard OpenLibraryFixture.requestedLanguages == expectedLanguageRequests else {
            fatalError("Open Library query language mismatch: \(OpenLibraryFixture.requestedLanguages) != \(expectedLanguageRequests)")
        }
        print("PASS metadata language query: \(OpenLibraryFixture.requestedLanguages.joined(separator: ","))")
        print("SYSTEMIC MISSING: \(failures.joined(separator: "; "))")
        guard failures.isEmpty else { fatalError("Unexpected translation selection outcomes") }
        print("NOTE: expected misses characterize current production fallback; fixture never downloads copyrighted bytes")
    }
    @MainActor static func wait(queue: DownloadQueue, id: UUID, stage: DownloadJob.Stage, timeout: TimeInterval) async throws {
        let start = Date()
        while Date().timeIntervalSince(start) < timeout {
            if queue.jobs.first(where: { $0.id == id })?.stage == stage { return }
            try await Task.sleep(for: .milliseconds(15))
        }
        fatalError("Timed out waiting for metadata-only job")
    }
}
