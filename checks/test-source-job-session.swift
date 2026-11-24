// Standalone test harness for the real ExtensionStore implementation.
// Run with `sh checks/test-source-job-session.sh` from /books.
// All fixture source files live in a fresh temporary directory; no Folio
// installation, user library, real server, browser, or app is accessed.
import Foundation

// Keep the standalone harness aligned with the production SourceManifest's
// language metadata without pulling in the rest of Folio's book model.
enum BookLanguage {
    static func code(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return String(raw.lowercased().prefix(2))
    }
    static func displayName(_ code: String) -> String { code == "es" ? "Spanish" : "English" }
}

@MainActor
final class HardcoverClient {
    static let shared = HardcoverClient()
    var isConnected: Bool { false }
    func query(_ query: String, _ variables: [String: Any]) async throws -> DummyQuery? { nil }
    struct DummyQuery { let anyValue: [String: Any] = [:] }
}

@MainActor
final class LibraryStore {
    static let shared = LibraryStore()
    let baseDir: URL

    private init() {
        baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folio-job-session-test-\(UUID().uuidString)", isDirectory: true)
    }

    func importBook(_ file: URL, author: String? = nil) async throws -> UUID {
        throw ExtensionError(message: "An offline runtime-isolation test must not import books.")
    }
}

enum Names {
    static func split(_ value: String) -> [String] { [value] }
}

enum DefaultSources {
    static let builtIn: [(id: String, script: String)] = [
        (id: "session-fixture", script: #"""
        var source = {
          id: 'session-fixture', name: 'Isolated JS fixture', version: '1',
          allowedHosts: ['https://approved.fixture.invalid'], settings: [],
          search: function(query, page, language, title, author) {
            this.counter = (this.counter || 0) + 1;
            return [{
              id: String(this.counter), title: title || query,
              authors: [author || 'Jane Doe'], language: language || null,
              downloads: [{format: 'epub', url: 'https://approved.fixture.invalid/book.epub'}]
            }];
          }
        };
        """#)
    ]
}

@main
struct JobSessionChecks {
    @MainActor
    static func main() async throws {
        let root = LibraryStore.shared.baseDir
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ExtensionStore.shared
        await store.loadAll()
        guard store.enabled.count == 1 else { fatalError("Fixture source was not loaded") }

        let manual = try await store.search("session-fixture", query: "Pride and Prejudice", page: 0,
                                            expectedLanguage: "en", expectedTitle: "Pride and Prejudice",
                                            expectedAuthor: "Jane Doe")
        guard manual.map(\.id) == ["1"] else { fatalError("Manual runtime failed to load") }

        let first = store.makeJobSession()
        let second = store.makeJobSession()
        let firstFound = await first.findCopies(title: "Pride and Prejudice", author: "Jane Doe", expectedLanguage: "en")
        let secondFound = await second.findCopies(title: "Pride and Prejudice", author: "Jane Doe", expectedLanguage: "en")
        guard firstFound.problems.isEmpty, secondFound.problems.isEmpty,
              firstFound.copies.first?.result.id == "1",
              secondFound.copies.first?.result.id == "1" else {
            fatalError("Independent jobs should begin with fresh JS counter state")
        }
        print("PASS separate jobs start with independent JavaScript heaps")

        let firstNext = try await first.search("session-fixture", query: "Pride and Prejudice",
                                              expectedTitle: "Pride and Prejudice", expectedAuthor: "Jane Doe")
        guard firstNext.first?.id == "2" else {
            fatalError("Search and subsequent work must retain the same runtime within a job")
        }
        let secondNext = try await second.search("session-fixture", query: "Pride and Prejudice",
                                                expectedTitle: "Pride and Prejudice", expectedAuthor: "Jane Doe")
        guard secondNext.first?.id == "2" else { fatalError("Second job was affected by first job") }
        print("PASS search state persists within each job but is isolated between jobs")

        // Start requests simultaneously rather than artificially serializing
        // both jobs in the UI. Both independently increment their own JS heap.
        async let parallelFirst = first.search("session-fixture", query: "Pride and Prejudice")
        async let parallelSecond = second.search("session-fixture", query: "Pride and Prejudice")
        let (firstConcurrent, secondConcurrent) = try await (parallelFirst, parallelSecond)
        guard firstConcurrent.first?.id == "3", secondConcurrent.first?.id == "3" else {
            fatalError("Concurrent job sessions mixed JavaScript execution state")
        }
        print("PASS independently scoped jobs accept simultaneous async searches")

        let manualNext = try await store.search("session-fixture", query: "Pride and Prejudice")
        let manualFollowing = try await store.search("session-fixture", query: "Pride and Prejudice")
        guard let previous = manualNext.first.flatMap({ Int($0.id) }),
              let following = manualFollowing.first.flatMap({ Int($0.id) }), following == previous + 1 else {
            fatalError("Manual runtime must remain separate and preserve its own search state")
        }
        print("PASS existing manual search API retains its original independent runtime")

        guard let src = store.ext("session-fixture") else { fatalError("Missing installed fixture") }
        let safe = URL(string: "https://approved.fixture.invalid/book.epub")!
        let hostile = URL(string: "https://not-approved.fixture.invalid/book.epub")!
        guard src.runtime.isAllowed(safe), !src.runtime.isAllowed(hostile) else {
            fatalError("Source runtime host allowlist is no longer exact")
        }
        print("PASS source host allowlist remains limited to explicitly approved origin")

        let third = store.makeJobSession()
        let thirdFound = await third.findCopies(title: "Pride and Prejudice", author: "Jane Doe")
        guard thirdFound.problems.isEmpty, thirdFound.copies.first?.result.id == "1" else {
            fatalError("Fresh jobs must not retain counters from completed sessions")
        }
        print("PASS a new job does not inherit runtime state from earlier jobs")

        await first.close()
        await first.close() // Idempotent; no browser/window created by cleanup.
        do {
            _ = try await first.search("session-fixture", query: "Pride and Prejudice")
            fatalError("Closing a job must prevent any further calls on its runtime")
        } catch let error as ExtensionError {
            guard error.localizedDescription.contains("already closed") else { throw error }
        }
        let afterFirstClosed = try await second.search("session-fixture", query: "Pride and Prejudice")
        guard afterFirstClosed.first?.id == "4" else {
            fatalError("Closing one job must not interfere with a concurrent job")
        }
        print("PASS job cleanup is idempotent and isolated from other active jobs")

        await second.close()
        await third.close()
        print("PASS all ephemeral job sessions clean up without launching WebKit")

        // A single job can ask more than one independent provider. Two JS
        // heaps each perform ~1.2s of synthetic CPU work; the discovery
        // wall time must be close to one search, rather than their sum.
        // This is deliberately network-free to isolate scheduler behavior.
        store.update("session-fixture") { $0.enabled = false }
        for id in ["parallel-a", "parallel-b"] {
            let source = """
            var source = {
              id: '\(id)', name: '\(id)', version: '1', languages: ['es'],
              allowedHosts: ['https://approved.fixture.invalid'], settings: [],
              search: function(query, page, language, title, author) {
                var start = Date.now(); while (Date.now() - start < 1200) {}
                return [{id:'\(id)',title:title,authors:[author],language:'es',
                  downloads:[{format:'epub',url:'https://approved.fixture.invalid/book.epub'}]}];
              }
            };
            """
            let file = root.appendingPathComponent("\(id).js")
            try source.write(to: file, atomically: true, encoding: .utf8)
            await store.install(from: file)
            guard store.ext(id) != nil else { fatalError("Provider fixture did not install: \(id)") }
        }
        let multiSource = store.makeJobSession()
        let start = ContinuousClock.now
        let parallel = await multiSource.findCopies(title: "Don Quijote de la Mancha",
                                                    author: "Miguel de Cervantes", expectedLanguage: "es")
        let elapsed = start.duration(to: ContinuousClock.now)
        guard parallel.problems.isEmpty, parallel.copies.count == 2,
              elapsed < .seconds(2.1) else {
            fatalError("Independent providers ran serially or failed: \(elapsed), \(parallel.problems)")
        }
        print("PASS two 1.2-second source searches overlap within the same job: \(elapsed)")
        await multiSource.close()

        // Approved partner origins do not inherit browser cookies, credentials
        // or the referring page from a different host.
        let firstURL = URL(string: "https://approved.fixture.invalid/partner")!
        let secondURL = URL(string: "https://other-approved.fixture.invalid/file.epub")!
        let redirectGuard = RedirectGuard { url in
            ["https://approved.fixture.invalid", "https://other-approved.fixture.invalid"]
                .contains("\(url.scheme ?? "")://\(url.host ?? "")")
        }
        let testingSession = URLSession(configuration: .ephemeral)
        defer { testingSession.invalidateAndCancel() }
        let task = testingSession.dataTask(with: firstURL)
        let response = HTTPURLResponse(url: firstURL, statusCode: 302,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        var target = URLRequest(url: secondURL)
        for name in ["Cookie", "Authorization", "Proxy-Authorization", "Referer", "Origin"] {
            target.setValue("session-sensitive-value", forHTTPHeaderField: name)
        }
        target.setValue("Folio", forHTTPHeaderField: "User-Agent")
        var accepted: URLRequest?
        redirectGuard.urlSession(testingSession, task: task,
                                 willPerformHTTPRedirection: response,
                                 newRequest: target) { accepted = $0 }
        guard let accepted, accepted.value(forHTTPHeaderField: "User-Agent") == "Folio" else {
            fatalError("Approved HTTPS partner redirect was unexpectedly blocked")
        }
        for name in ["Cookie", "Authorization", "Proxy-Authorization", "Referer", "Origin"] {
            guard accepted.value(forHTTPHeaderField: name) == nil else {
                fatalError("Cross-origin redirect leaked \(name)")
            }
        }
        var rejected: URLRequest?
        redirectGuard.urlSession(testingSession, task: task,
                                 willPerformHTTPRedirection: response,
                                 newRequest: URLRequest(url: URL(string: "https://unapproved.fixture.invalid/book.epub")!)) { rejected = $0 }
        guard rejected == nil else { fatalError("Unapproved cross-server redirect was followed") }
        print("PASS approved cross-origin redirect strips browser headers; unapproved origin blocked")
    }
}
