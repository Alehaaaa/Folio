// Metadata-only Alloy translation regression using the UNMODIFIED production DownloadQueue.swift.
// All network traffic uses a Python localhost fixture; store is an isolated temp directory.
import Foundation

enum SourceEvent { case status(String), log(String), transfer(received: Int64, expected: Int64) }

// Register a deterministic URL loading protocol for the *actual* Open Library
// URLSession.shared request inside production DownloadQueue.swift.
// No public provider traffic is needed or permitted for these scenarios.
final class OpenLibraryFixture: URLProtocol {
    static var calls = 0
    static var mode = "valid"
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "openlibrary.org"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        if Self.mode == "outage" {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let titles: [String] = Self.mode == "unsafe-bilingual"
            ? ["Mistborn Omnibus / The Alloy of Law", "Aleación de Ley / The Alloy of Law"]
            : Self.mode == "wrong-bilingual"
                ? ["Aleación de Ley / Wrong Book"]
            : Self.mode == "compilation-only"
                ? ["Aleación de Ley: colección completa / The Alloy of Law"]
                : ["Aleación de Ley / The Alloy of Law"]
        let editions: [[String: Any]] = titles.map { ["title": $0, "language": ["spa"]] }
        let payload: [String: Any] = ["docs": [[
            "title": "The Alloy of Law", "author_name": ["Brandon Sanderson"],
            "editions": ["docs": editions]
        ]]]
        let bytes = try! JSONSerialization.data(withJSONObject: payload)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                             httpVersion: nil, headerFields: ["Content-Type":"application/json"])!,
                             cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: bytes)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


enum BookLanguage {
    static func code(_ raw: String?) -> String? {
        let value = raw?.lowercased() ?? ""
        if ["es", "spa", "spanish"].contains(value) { return "es" }
        if ["fr", "fre", "french"].contains(value) { return "fr" }
        return nil
    }
    static var preferred: String { "es" }
    static var reading: String { preferred }
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
        guard URLProtocol.registerClass(OpenLibraryFixture.self) else { fatalError("Unable to intercept metadata requests") }
        let mode = CommandLine.arguments.dropFirst().first ?? "valid"
        OpenLibraryFixture.mode = mode
        let queue = DownloadQueue.shared
        let source = ExtensionStore.shared
        let hardcover = HardcoverClient.shared
        let cases: [(String, Int?, String, Bool)] = mode == "outage"
            ? [("outage-429",42,"429",false),("outage-403",42,"403",false),
               ("outage-no-id",nil,"ok",false)]
            : mode == "unsafe-bilingual"
                ? [("unsafe-prefix",42,"429",false)]
                : mode == "wrong-bilingual"
                    ? [("wrong-work",42,"429",false)]
                : mode == "compilation-only"
                    ? [("compilation-only",42,"429",false)]
                    : [("http429",42,"429",true),("http403",42,"403",true),
                       ("missing-id",nil,"ok",true),("valid-edition",42,"ok",true)]
        if mode == "chosen-edition" {
            // The edition picked on a book page is searched first, with no
            // metadata lookups, even while Hardcover is rate-limited.
            source.searched = []
            hardcover.response = "429"
            hardcover.calls = 0
            let id = queue.enqueue(title: "The Alloy of Law", author: "Brandon Sanderson",
                                   hardcoverBookID: 42, expectedLanguage: "es",
                                   editionTitle: "Aleación de ley")
            try await wait(queue: queue, id: id, stage: .failed, timeout: 5)
            let job = queue.jobs.first { $0.id == id }!
            let searches = source.searched.filter { !$0.hasPrefix("CANDIDATE:") }
            guard job.title == "The Alloy of Law", job.editionTitle == "Aleación de ley",
                  searches.first == "Aleación de ley",
                  hardcover.calls == 0, OpenLibraryFixture.calls == 0 else {
                fatalError("Chosen edition not used first: \(searches) hc=\(hardcover.calls) ol=\(OpenLibraryFixture.calls)")
            }
            queue.retry(id, expectedLanguage: "fr")
            guard queue.jobs.first(where: { $0.id == id })?.editionTitle == nil else {
                fatalError("Edition title survived a language change")
            }
            print("PASS: chosen edition searched first without lookups; cleared when the language changes")
            return
        }
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
            } else if mode == "unsafe-bilingual" {
                guard searches == ["Aleación de Ley"] else {
                    fatalError("Unexpected unsafe bilingual result: \(source.searched)")
                }
                print("PASS: omnibus edition title skipped; the standalone translation is searched")
            } else if mode == "compilation-only" {
                guard !searches.contains("Aleación de Ley: colección completa"), candidates.isEmpty else {
                    fatalError("Unexpected compilation metadata handling: \(source.searched)")
                }
                print("PASS: compilation title is not used as a translated title")
            } else if mode == "wrong-bilingual" {
                guard searches == ["The Alloy of Law"] && candidates.isEmpty else {
                    fatalError("Unrelated bilingual work was accepted: \(source.searched)")
                }
                print("PASS: bilingual edition suffix for a different work rejected")
            } else {
                guard searches == ["The Alloy of Law"] && candidates.isEmpty else { fatalError("Unexpected fallback searches or candidates: \(source.searched)") }
                guard job.error?.contains("No matching EPUB") == true else { fatalError("Expected catalogue no-match failure, got \(job.error ?? "nil")") }
            }
            // The queue caches a book's edition lookup briefly, so a repeated case may make none.
            guard hardcover.calls <= (bookID == nil ? 0 : 1) else { fatalError("Edition request duplicated") }
            guard LibraryStore.shared.books.isEmpty else { fatalError("Unexpected imported EPUB") }
            print(String(format: "CASE %@: searches=%d, editionCalls=%d, matched=%d, stage=%@, elapsed=%.3fs",
                         caseName, searches.count, hardcover.calls, candidates.count,
                         job.stage.rawValue, Date().timeIntervalSince(caseStart)))
            if caseName == "http429" || caseName == "outage-429" {
                let priorProviderCalls = OpenLibraryFixture.calls
                source.searched = []
                let retryStart = Date()
                queue.retry(id)
                try await wait(queue: queue, id: id, stage: .failed, timeout: 5)
                let afterRetry = queue.jobs.first { $0.id == id }!
                let retriedSearches = source.searched.filter { !$0.hasPrefix("CANDIDATE:") }
                guard retriedSearches == searches,
                      OpenLibraryFixture.calls == priorProviderCalls,
                      afterRetry.detailLog.contains(where: { $0.contains("Retry requested") }) else {
                    fatalError("Retry caused extra provider lookup or changed title: \(retriedSearches)")
                }
                print(String(format: "RETRY %@: searches=%d, additionalOpenLibraryCalls=%d, elapsed=%.3fs",
                             caseName, retriedSearches.count, OpenLibraryFixture.calls - priorProviderCalls,
                             Date().timeIntervalSince(retryStart)))
            }
            queue.dismiss(id) // Avoid enqueue's intentional retry/reuse of a previous failed job.
        }
        guard OpenLibraryFixture.calls == 1 || (mode == "unsafe-bilingual" || mode == "compilation-only") && OpenLibraryFixture.calls == 1 else {
            fatalError("Repeated metadata provider calls despite cache: \(OpenLibraryFixture.calls)")
        }
        print("CACHE: mode=\(mode) Open Library HTTP requests=\(OpenLibraryFixture.calls) across \(cases.count) jobs")
        if mode == "outage" {
            print("REPRODUCED: Open Library unavailable; negative cache suppresses repeated request but English-only search yields false no-match")
        } else if mode == "valid" {
            print("PASS metadata-only: one translated title search per job, original English search skipped, collection candidates rejected")
        }
        print("PASS: metadata-only test; no copyrighted downloads or library imports; isolated directory: \(root.lastPathComponent)")
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
