#!/bin/zsh
# Live check of Folio's keyless discovery sources (Open Library + Wikidata), using
# the production FolioOpenLibrary / FolioWikidataSeries code. About 15 requests,
# paced by the app's own client and then served from its disk cache; no account needed.
set -euo pipefail
cd "${0:A:h}/.."
scratch=$(mktemp -d "${TMPDIR:-/tmp/}folio-open-discovery.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
python3 - "$scratch" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
hc = Path('app/Sources/Folio/Hardcover.swift').read_text()
models = hc[hc.index('// MARK: - Loose JSON'):hc.index('// MARK: - Models')] + hc[hc.index('struct HCBook: '):hc.index('struct HCBookStats')] + hc[hc.index('struct HCBookSeries'):hc.index('struct HCBookPage')] + hc[hc.index('struct HCSeriesRef'):hc.index('struct HCUserBook')]
error = hc[hc.index('struct HCError'):hc.index('/// Keeps requests under Hardcover')]
feed = Path('app/iOS/Sources/FolioMobileDiscoverFeed.swift').read_text()
topics = feed[feed.index('// MARK: - Topics'):feed.index('// MARK: - Discover page feed')]
(out / 'Models.swift').write_text('import Foundation\n' + models + error + topics + '''
enum BookLanguage { nonisolated(unsafe) static var reading = "en" }
enum BookAutoMatch {
  static func sameAuthor(_ a: String, _ b: String) -> Bool { sameTitle(a, b) }
  static func sameTitle(_ a: String, _ b: String) -> Bool {
    a.lowercased().filter(\\.isLetter) == b.lowercased().filter(\\.isLetter)
  }
}
''')
(out / 'OpenLibrary.swift').write_text(Path('app/Sources/Folio/OpenLibrary.swift').read_text())
(out / 'main.swift').write_text('''
import Foundation
setvbuf(stdout, nil, _IONBF, 0)
func check(_ ok: Bool, _ what: String) { if !ok { fatalError("FAIL " + what) }; print("PASS " + what) }
let t0 = Date()
let fantasy = try await FolioOpenLibrary.discoverBooks(FolioDiscoverTopic(kind: .genre("Fantasy"), title: "Fantasy"), limit: 12)
check(fantasy.count >= 8 && fantasy.allSatisfy { $0.id < 0 && $0.imageURL != nil }, "Fantasy row: \\(fantasy.count) books with covers, first \\(fantasy.first?.title ?? "-")")
let trending = try await FolioOpenLibrary.discoverBooks(FolioDiscoverTopic(kind: .trending, title: "Trending now"))
check(trending.count >= 10, "Trending: \\(trending.count) books, first \\(trending.first?.title ?? "-")")
let acclaimed = try await FolioOpenLibrary.discoverBooks(FolioDiscoverTopic(kind: .acclaimed, title: "Acclaimed"), limit: 10)
check(acclaimed.count >= 5 && (acclaimed.first?.rating ?? 0) >= 4, "Acclaimed: top rated first (\\(acclaimed.first?.title ?? "-") \\(acclaimed.first?.rating ?? 0))")
let work = await FolioOpenLibrary.work(title: "The Final Empire", author: "Brandon Sanderson")
check(work.flatMap { FolioOpenLibrary.workKey($0.id) } == "OL5738148W", "Hardcover book matched to its Open Library work")
let series = try await FolioWikidataSeries.series(ofWork: "OL5738150W")
check(series.first?.name == "Mistborn" && series.first?.position == 2, "Well of Ascension is Mistborn #2 on Wikidata")
let books = try await FolioWikidataSeries.books(series[0].id)
let main = books.filter { ($0.position ?? 0) >= 1 }
check(main.count >= 7 && main.first?.position == 1, "Mistborn series: \\(books.count) books in order: " + main.prefix(4).map(\\.book.title).joined(separator: " / "))
let similar = try await FolioOpenLibrary.similar(to: work!, genres: ["Fantasy", "Magic"])
check(similar.count >= 5 && !similar.contains { $0.authors.contains("Sanderson") }, "Similar to The Final Empire: \\(similar.prefix(3).map(\\.title))")
let page = try await FolioOpenLibrary.authorPage(name: "Brandon Sanderson")
check(page?.author.bio != nil && page?.author.imageURL != nil && (page?.books.count ?? 0) >= 20, "Author page: bio, photo and \(page?.books.count ?? 0) books")
check(page?.series.contains { $0.name == "The Stormlight Archive" } ?? false, "Author series from Wikidata: " + (page?.series.prefix(4).map(\.name).joined(separator: ", ") ?? ""))
let blurb = await FolioOpenLibrary.description(of: work!)
check((blurb?.count ?? 0) > 80, "Work description for books opened from Open Library")
BookLanguage.reading = "es"
let spanish = try await FolioWikidataSeries.books(series[0].id)
check(spanish.first.map { $0.book.title != books.first?.book.title } ?? false, "Spanish reader sees Spanish titles: \\(spanish.first?.book.title ?? "-")")
let cold = Date().timeIntervalSince(t0)
BookLanguage.reading = "en"
let t1 = Date()
_ = try await FolioOpenLibrary.discoverBooks(FolioDiscoverTopic(kind: .genre("Fantasy"), title: "Fantasy"), limit: 12)
_ = try await FolioWikidataSeries.books(series[0].id)
check(Date().timeIntervalSince(t1) < 1.5, String(format: "second visit served from cache (%.2fs vs %.1fs cold)", Date().timeIntervalSince(t1), cold))
''')
PY
swiftc -swift-version 5 "$scratch/Models.swift" "$scratch/OpenLibrary.swift" "$scratch/main.swift" -o "$scratch/test"
"$scratch/test"
