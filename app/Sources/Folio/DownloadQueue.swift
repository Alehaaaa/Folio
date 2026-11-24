import Foundation
import Observation

extension Notification.Name {
    /// A verified book has been added to the local library and can be opened.
    static let folioDownloadReady = Notification.Name("folio.download.ready")
    /// A background source attempt needs action; retain navigation in the user's control.
    static let folioDownloadFailed = Notification.Name("folio.download.failed")
}

/// A durable queue entry is independent of navigation views and extension
/// runtimes. All fields needed to resume are written to disk before work begins.
struct DownloadJob: Identifiable, Codable {
    enum Stage: String, Codable {
        case queued, searching, choosing, downloading, importing, completed, failed, cancelled

        var isActive: Bool {
            switch self {
            case .queued, .searching, .choosing, .downloading, .importing: true
            default: false
            }
        }
    }

    var id: UUID
    var title: String
    var author: String
    var cover: URL?
    var hardcoverBookID: Int?
    var hardcoverPages: Int?
    /// Optional so download-queue.json written by older Folio versions still decodes.
    /// A missing value in a resumed job uses the current preferred app language.
    var expectedLanguage: String?
    var stage: Stage
    var statusText: String
    var detailLog: [String]
    var error: String?
    var importedBookID: UUID?
    var createdAt: Date
    var updatedAt: Date
}

/// Jobs continue through their own Task even when the user leaves the screen.
/// A bounded pool keeps independent jobs moving even when one source is
/// waiting for a published partner countdown. Jobs resume after relaunch.
@Observable
@MainActor
final class DownloadQueue {
    static let shared = DownloadQueue()

    private(set) var jobs: [DownloadJob] = []
    /// Each job owns its cancellation token and source session. A cancelled
    /// book must not interrupt another book or consume its source state.
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var bootstrap: Task<Void, Never>?
    private var didLoadSources = false
    private static let concurrencyKey = "folio.download.maxConcurrent"
    #if os(iOS)
    private static let defaultConcurrency = 3
    #else
    private static let defaultConcurrency = 6
    #endif
    /// Bound concurrent WebKit contexts to avoid memory exhaustion or
    /// overwhelming rate-limited providers. User-adjustable from 1 to 8.
    var maxConcurrentDownloads: Int = DownloadQueue.defaultConcurrency {
        didSet {
            let bounded = min(8, max(1, maxConcurrentDownloads))
            if maxConcurrentDownloads != bounded { maxConcurrentDownloads = bounded }
            UserDefaults.standard.set(bounded, forKey: Self.concurrencyKey)
            startWorker()
        }
    }
    private var saveURL: URL {
        LibraryStore.shared.baseDir.appendingPathComponent("download-queue.json")
    }

    var activeCount: Int { jobs.filter { $0.stage.isActive }.count }
    var errorCount: Int { jobs.filter { $0.stage == .failed }.count }

    private init() {
        if let saved = UserDefaults.standard.object(forKey: Self.concurrencyKey) as? Int {
            maxConcurrentDownloads = min(8, max(1, saved))
        }
        if let bytes = try? Data(contentsOf: saveURL),
           let decoded = try? JSONDecoder().decode([DownloadJob].self, from: bytes) {
            jobs = decoded.map { job in
                var recovered = job
                if recovered.stage != .queued && recovered.stage.isActive {
                    recovered.stage = .queued
                    recovered.statusText = "Resuming after restart…"
                    recovered.detailLog.append("Previous operation interrupted; queued for retry")
                }
                return recovered
            }
        }
        persist()
        // Launch resumes unfinished queue entries even if Downloading is not
        // selected or the user immediately navigates to another section.
        Task { @MainActor [weak self] in self?.startWorker() }
    }

    @discardableResult
    func enqueue(title: String, author: String, hardcoverBookID: Int? = nil,
                 hardcoverPages: Int? = nil, cover: URL? = nil,
                 expectedLanguage: String? = nil) -> UUID {
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedAuthor = author.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = BookLanguage.code(expectedLanguage) ?? BookLanguage.preferred
        let signature = BookMatch.key(author: cleanedAuthor, title: cleanedTitle)
        if let existing = jobs.first(where: {
            $0.stage.isActive && BookMatch.key(author: $0.author, title: $0.title) == signature &&
            (BookLanguage.code($0.expectedLanguage) ?? BookLanguage.preferred) == language
        }) { return existing.id }
        if let previouslyFailed = jobs.first(where: {
            ($0.stage == .failed || $0.stage == .cancelled) &&
            BookMatch.key(author: $0.author, title: $0.title) == signature &&
            (BookLanguage.code($0.expectedLanguage) ?? BookLanguage.preferred) == language
        }) {
            retry(previouslyFailed.id)
            return previouslyFailed.id
        }
        let now = Date()
        let id = UUID()
        jobs.insert(DownloadJob(
            id: id, title: cleanedTitle, author: cleanedAuthor,
            cover: cover, hardcoverBookID: hardcoverBookID,
            hardcoverPages: hardcoverPages, expectedLanguage: language, stage: .queued,
            statusText: "Waiting in the download queue…",
            detailLog: ["\(now.formatted(date: .abbreviated, time: .standard)) · Queued for automatic source search · required language \(language)"],
            error: nil, importedBookID: nil, createdAt: now, updatedAt: now
        ), at: 0)
        persist()
        startWorker()
        return id
    }

    /// Retry in an explicitly selected language without affecting other jobs.
    /// Existing callers retain their previous per-job language choice.
    func retry(_ id: UUID, expectedLanguage: String? = nil) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              !jobs[index].stage.isActive else { return }
        if let expectedLanguage {
            guard let code = BookLanguage.code(expectedLanguage) else { return }
            jobs[index].expectedLanguage = code
            jobs[index].detailLog.append("Language changed to \(code) for the next attempt")
        }
        jobs[index].stage = .queued
        jobs[index].statusText = "Waiting for source search…"
        jobs[index].error = nil
        jobs[index].importedBookID = nil
        jobs[index].updatedAt = Date()
        jobs[index].detailLog.append("Retry requested · current language \(BookLanguage.code(jobs[index].expectedLanguage) ?? "unverified")")
        persist()
        startWorker()
    }

    func cancel(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].stage.isActive else { return }
        mutate(id) {
            $0.stage = .cancelled
            $0.statusText = "Cancelled"
            $0.error = nil
        }
        activeTasks[id]?.cancel()
    }

    func dismiss(_ id: UUID) {
        if jobs.first(where: { $0.id == id })?.stage.isActive == true {
            cancel(id)
        }
        jobs.removeAll { $0.id == id }
        persist()
    }

    /// Clear history while retaining failed jobs that still require action.
    func clearHistory() {
        jobs.removeAll { $0.stage == .completed || $0.stage == .cancelled }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(jobs) else { return }
        try? data.write(to: saveURL, options: .atomic)
    }

    private func mutate(_ id: UUID, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
        jobs[index].updatedAt = Date()
        persist()
    }

    private func append(_ id: UUID, _ line: String) {
        mutate(id) { job in
            let cleaned = String(line.trimmingCharacters(in: .whitespacesAndNewlines).prefix(850))
            guard !cleaned.isEmpty else { return }
            job.detailLog.append("\(Date().formatted(date: .omitted, time: .standard)) · \(cleaned)")
            if job.detailLog.count > 120 { job.detailLog.removeFirst(job.detailLog.count - 120) }
        }
    }

    private func state(_ id: UUID, _ stage: DownloadJob.Stage, _ message: String) {
        guard jobs.first(where: { $0.id == id })?.stage.isActive == true else { return }
        mutate(id) { job in
            job.stage = stage
            job.statusText = message
        }
        append(id, message)
    }

    private func event(_ id: UUID, source: String, value: SourceEvent) {
        guard jobs.first(where: { $0.id == id })?.stage.isActive == true else { return }
        switch value {
        case .status(let message):
            let line = String(message.prefix(180))
            let before = jobs.first(where: { $0.id == id })?.statusText
            mutate(id) { $0.statusText = line }
            if before != line { append(id, "\(source): \(line)") }
        case .log(let details):
            append(id, "\(source): \(details)")
        }
    }

    private func startWorker() {
        guard jobs.contains(where: { $0.stage == .queued }) else { return }
        if !didLoadSources {
            guard bootstrap == nil else { return }
            bootstrap = Task { @MainActor [weak self] in
                guard let self else { return }
                await ExtensionStore.shared.loadAll()
                self.didLoadSources = true
                self.bootstrap = nil
                self.startWorker()
            }
            return
        }
        while activeTasks.count < maxConcurrentDownloads,
              let next = jobs.filter({ $0.stage == .queued && activeTasks[$0.id] == nil })
                .min(by: { $0.createdAt < $1.createdAt })?.id {
            // Mark the slot claimed before starting its Task. Otherwise two
            // enqueues in the same actor turn could schedule the same book.
            state(next, .searching, "Starting background download…")
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                let sourceSession = ExtensionStore.shared.makeJobSession()
                await self.process(next, sourceSession: sourceSession)
                // Explicit async teardown is required for ephemeral WebKit
                // hosts on iOS. Never release a slot until its session closed.
                await sourceSession.close()
                self.finishJob(next)
            }
            activeTasks[next] = task
        }
    }

    private func finishJob(_ id: UUID) {
        activeTasks[id] = nil
        if let job = jobs.first(where: { $0.id == id }), job.stage.isActive {
            if Task.isCancelled {
                mutate(id) { $0.stage = .cancelled; $0.statusText = "Cancelled" }
            } else {
                fail(id, reason: "Download stopped unexpectedly. Retry to resume this book.")
            }
        }
        startWorker()
    }

    private func process(_ id: UUID, sourceSession: ExtensionStore.JobSession) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        let store = LibraryStore.shared
        // Source session is retained from the scheduler through discovery,
        // partner wait and final download, and explicitly closed afterwards.
        let language = BookLanguage.code(job.expectedLanguage) ?? BookLanguage.preferred
        mutate(id) { $0.expectedLanguage = language }
        append(id, "Automatic EPUB language requirement: \(language) (edition metadata must agree)")
        // Editions in another language often carry their own title ("Dune"
        // is "Duna" in Catalan). Search with Hardcover's edition title for the
        // chosen language too, and accept a copy under either title.
        var titles = [job.title]
        if let hcID = job.hardcoverBookID,
           let edition = try? await HardcoverClient.shared.edition(bookID: hcID, language: language),
           let editionTitle = edition.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !editionTitle.isEmpty, !AutomaticEPUBChoice.sameTitle(job.title, editionTitle) {
            titles.insert(editionTitle, at: 0)
            append(id, "Edition title in \(language): \(editionTitle) · searching with it first")
        }
        func knownTitle(_ candidate: String) -> Bool {
            titles.contains { AutomaticEPUBChoice.sameTitle($0, candidate) }
        }
        // A locally imported edition can retain a harmless series subtitle in
        // its own OPF title; don't download a duplicate because of that label.
        for local in store.books where
            knownTitle(local.title) &&
            AutomaticEPUBChoice.sameAuthor(job.author, local.author) {
            let package = local.format == .epub
                ? try? EPUBPackage.load(root: store.extractedURL(local)) : nil
            if BookLanguage.matches(package?.language, expected: language) == true {
                append(id, "Existing local EPUB \(local.id) has verified language \(package?.language ?? "?")")
                complete(id, bookID: local.id, existing: true)
                return
            }
            append(id, "Not reusing local copy \(local.id): EPUB language \(package?.language ?? "unverified") does not verify as \(language); existing copy preserved")
        }

        state(id, .searching, "Searching enabled sources…")
        var names: (copies: [ExtensionStore.Copy], problems: [String]) = ([], [])
        for title in titles {
            let found = await sourceSession.findCopies(title: title, author: job.author,
                expectedLanguage: language,
                progress: { [weak self] name in
                    self?.state(id, .searching, titles.count > 1 ? "Searching \(name) for \(title)…" : "Searching \(name)…")
                },
                onEvent: { [weak self] name, value in
                    Task { @MainActor in self?.event(id, source: name, value: value) }
                })
            let seen = Set(names.copies.map(\.id))
            names.copies += found.copies.filter { !seen.contains($0.id) }
            names.problems += found.problems.filter { !names.problems.contains($0) }
        }
        guard !Task.isCancelled,
              jobs.first(where: { $0.id == id })?.stage.isActive == true else { return }
        for problem in names.problems { append(id, problem) }

        state(id, .choosing, "Checking editions for language \(language)…")
        let identityMatches = names.copies.filter {
            $0.result.preferred?.format == "epub" &&
            knownTitle($0.result.title) &&
            AutomaticEPUBChoice.sameAuthor(job.author, $0.result.author)
        }
        for choice in identityMatches where
            BookLanguage.matches(choice.result.language, expected: language) == false {
            append(id, "Rejected \(choice.sourceName) record \(choice.result.id): source language \(choice.result.language ?? "unknown") differs from requested \(language)")
        }
        // Copies under the edition title first, then under the original title.
        var ranked: [ExtensionStore.Copy] = []
        for title in titles {
            for copy in AutomaticEPUBChoice.ranked(names.copies, title: title, author: job.author,
                                                   expectedLanguage: language)
            where !ranked.contains(where: { $0.id == copy.id }) {
                ranked.append(copy)
            }
        }
        append(id, "Found \(names.copies.count) nearby records, \(identityMatches.count) exact identity EPUBs, \(ranked.count) language-eligible candidate(s) for \(language)")
        guard !ranked.isEmpty else {
            for choice in names.copies.prefix(8) {
                append(id, "Nearby but not verified: \(choice.sourceName) record \(choice.result.id) · \(choice.result.title) — \(choice.result.author) · language \(choice.result.language ?? "unknown")")
            }
            let noLanguage = !identityMatches.isEmpty && identityMatches.allSatisfy {
                BookLanguage.matches($0.result.language, expected: language) == false
            }
            let inaccessible = names.problems.contains {
                $0.localizedCaseInsensitiveContains("free EPUB partner links could not be resolved") ||
                $0.localizedCaseInsensitiveContains("no accessible published") ||
                $0.localizedCaseInsensitiveContains("no downloadable links")
            }
            // A DNS/TLS failure happens before the catalogue can be searched.
            // Do not report it as a missing title, wrong language or absent EPUB.
            let connectionFailure = names.copies.isEmpty && names.problems.contains { problem in
                let descriptions = [
                    "hostname could not be found", "could not resolve host", "dns lookup",
                    "a tls error", "secure connection to fail", "certificate verification",
                    "network connection was lost", "network is unreachable",
                    "could not connect to the server", "connection reset",
                    "connection timed out", "request timed out", "timed out"
                ]
                return descriptions.contains { problem.localizedCaseInsensitiveContains($0) }
            }
            if inaccessible {
                append(id, "Matching catalogue entries were located but no source published a usable free EPUB link. This is source availability, not a title or language mismatch.")
                for problem in names.problems { append(id, "Source detail: \(problem)") }
            }
            if connectionFailure {
                append(id, "Source network failure: DNS, TLS, lost connection or timeout occurred before an EPUB edition could be verified. Check the source in Safari on this device; review network and DNS/VPN settings if it fails there too.")
            }
            fail(id, reason: noLanguage
                ? "No EPUB confirmed in \(language) was found. Other-language editions will not be imported automatically; select a different language and retry if desired."
                : (inaccessible
                   ? "Matching book listings exist, but the enabled sources have no accessible free EPUB link for the requested language (\(language)). Retry later or choose a source; Folio will not bypass site restrictions."
                   : (connectionFailure
                      ? "Cannot reach the book sources (DNS, TLS or network connection failure). No EPUB availability or language could be verified. Check the source websites in Safari on this device and try another network or retry later."
                      : (names.problems.isEmpty
                         ? "No matching EPUB listing in \(language). Try refining the book title, or select a different language if you want another edition."
                         : "Sources could not complete a search for an EPUB in \(language). Check the activity log, then retry."))))
            return
        }

        var reasons: [String] = []
        for (index, choice) in ranked.enumerated() {
            guard !Task.isCancelled,
                  jobs.first(where: { $0.id == id })?.stage.isActive == true else { return }
            let detail = "Copy \(index + 1) of \(ranked.count) · \(choice.sourceName)"
            state(id, .downloading, "Downloading \(detail)…")
            append(id, "Trying \(choice.sourceName) record \(choice.result.id): \(choice.result.title) — \(choice.result.author); listed language \(choice.result.language ?? "unknown"), required \(language)")
            if BookLanguage.matches(choice.result.language, expected: language) == nil {
                append(id, "Source did not verify edition language; the EPUB's own package metadata must confirm \(language) after download")
            }
            if let count = choice.result.downloadCount {
                append(id, "Selected provider-reported popularity: \(count) downloads")
            } else {
                append(id, "Provider has no verified download count; using exact metadata and stable ranking")
            }
            do {
                let imported = try await sourceSession.download(choice.result, from: choice.sourceID, into: store,
                    onEvent: { [weak self] value in
                        Task { @MainActor in
                            guard let self else { return }
                            if case .status(let message) = value,
                               message.localizedCaseInsensitiveContains("import") {
                                self.state(id, .importing, message)
                            } else {
                                self.event(id, source: choice.sourceName, value: value)
                            }
                        }
                    })
                if Task.isCancelled ||
                    jobs.first(where: { $0.id == id })?.stage.isActive != true {
                    store.remove(imported)
                    return
                }
                state(id, .importing, "Verifying the imported EPUB metadata…")
                let package = store.book(imported).flatMap { try? EPUBPackage.load(root: store.extractedURL($0)) }
                guard let package,
                      knownTitle(package.title),
                      AutomaticEPUBChoice.sameAuthor(job.author, package.author) else {
                    store.remove(imported)
                    let error = "Imported EPUB metadata did not match \(job.title) — \(job.author)"
                    reasons.append(error)
                    append(id, "\(choice.sourceName): \(error)")
                    continue
                }
                guard BookLanguage.matches(package.language, expected: language) == true else {
                    store.remove(imported) // only the newly imported candidate, never the user's previous copy
                    let reason = "Rejected record \(choice.result.id): downloaded EPUB declares \(package.language ?? "no verifiable language"), requested \(language)"
                    reasons.append(reason)
                    append(id, "\(choice.sourceName): \(reason); temporary import removed, trying next edition")
                    continue
                }
                append(id, "Verified EPUB package language \(package.language ?? "?") matches requested \(language) · record \(choice.result.id)")
                store.update(imported) { book in
                    book.language = BookLanguage.code(package.language)
                    if let hcID = job.hardcoverBookID {
                        book.hardcoverBookID = hcID
                        book.hardcoverPages = job.hardcoverPages ?? book.hardcoverPages
                    }
                }
                complete(id, bookID: imported, existing: false)
                return
            } catch {
                if Task.isCancelled { return }
                let reason = "\(choice.sourceName), \(choice.result.title): \(error.localizedDescription)"
                reasons.append(reason)
                append(id, reason)
            }
        }
        fail(id, reason: "No matching EPUB could be downloaded. \(reasons.last ?? "All available source links failed.")")
    }

    private func complete(_ id: UUID, bookID: UUID, existing: Bool) {
        guard jobs.first(where: { $0.id == id })?.stage.isActive == true else { return }
        mutate(id) { job in
            job.importedBookID = bookID
            job.stage = .completed
            job.statusText = existing ? "Already in your library · ready to read" : "Download complete · ready to read"
            job.error = nil
        }
        append(id, existing ? "Found existing local copy" : "EPUB verified and added to the library")
        if let job = jobs.first(where: { $0.id == id }) {
            NotificationCenter.default.post(name: .folioDownloadReady, object: nil,
                                            userInfo: ["jobID": id, "bookID": bookID, "title": job.title])
        }
    }

    private func fail(_ id: UUID, reason: String) {
        guard jobs.first(where: { $0.id == id })?.stage.isActive == true else { return }
        mutate(id) { job in
            job.stage = .failed
            job.statusText = "Could not download this book"
            job.error = reason
        }
        append(id, "ERROR: \(reason)")
        if let job = jobs.first(where: { $0.id == id }) {
            NotificationCenter.default.post(name: .folioDownloadFailed, object: nil,
                                            userInfo: ["jobID": id, "title": job.title])
        }
    }
}
