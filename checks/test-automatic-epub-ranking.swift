import Foundation

// Build only with the actual production BookAutoMatch and AutomaticEPUBChoice
// implementations. The lightweight copies are original, synthetic records.
struct SourceDownload {
    let format: String
    let url: URL
}
struct SourceResult {
    let id: String
    let title: String
    let author: String
    let language: String?
    let downloadCount: Int?
    let preferred: SourceDownload?
}
enum ExtensionStore {
    struct Copy {
        let sourceID: String
        let result: SourceResult
    }
}

@main
struct AutomaticRankingRegression {
    static func copy(_ id: String, _ title: String, _ author: String,
                     language: String? = "es", count: Int? = nil) -> ExtensionStore.Copy {
        .init(sourceID: "spanish-fixture", result: SourceResult(
            id: id, title: title, author: author, language: language,
            downloadCount: count,
            preferred: SourceDownload(format: "epub", url: URL(string: "https://example.invalid/\(id).epub")!)
        ))
    }

    static func main() {
        let compilation = copy("a-compilation", "Dune: La saga completa",
                               "Brian Herbert, Frank Herbert, Kevin J. Anderson", count: 99999)
        let exact = copy("z-exact", "Dune", "Frank Herbert", count: 1)
        let ranked = AutomaticEPUBChoice.ranked([compilation, exact], title: "Dune",
                                                author: "Frank Herbert", expectedLanguage: "es")
        precondition(ranked.map(\.result.id) == ["z-exact"],
                     "An anthology cannot be selected as the target book")

        let legitimateSubtitle = copy("a-subtitle", "Iron Gold: Book 4 of the Red Rising Saga",
                                      "Pierce Brown", language: "en", count: 99999)
        let trueExact = copy("z-original", "Iron Gold", "Pierce Brown", language: "en", count: 1)
        let rankedEnglish = AutomaticEPUBChoice.ranked([legitimateSubtitle, trueExact],
            title: "Iron Gold", author: "Pierce Brown", expectedLanguage: "en")
        precondition(rankedEnglish.map(\.result.id) == ["z-original", "a-subtitle"],
                     "Exact-title books must be ranked ahead of legitimate descriptive subtitles")

        let coauthored = copy("a-coauthored", "Don Quijote de la Mancha",
                              "Miguel de Cervantes, Otro autor", count: 99999)
        let single = copy("z-single", "Don Quijote de la Mancha", "Miguel de Cervantes", count: 1)
        let rankedClassic = AutomaticEPUBChoice.ranked([coauthored, single],
            title: "Don Quijote de la Mancha", author: "Miguel de Cervantes", expectedLanguage: "es")
        precondition(rankedClassic.map(\.result.id) == ["z-single"],
                     "Additional credited authors cannot pass as the requested standalone edition")
        print("PASS: complete-series and extra coauthors rejected; exact editions outrank subtitles and popularity")
    }
}
