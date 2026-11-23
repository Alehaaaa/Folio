import SwiftUI
import UIKit

/// iOS equivalent of macOS's dictionary lookup for the selected word or phrase.
struct FolioMobileDictionaryView: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}

/// An encyclopedia lookup uses the same Wikipedia query as the macOS reader.
/// The query is sent only after the user explicitly requests a fun fact.
struct FolioMobileFactView: View {
    let selection: String

    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var extract = ""
    @State private var article: URL?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if loading {
                        ProgressView("Looking up a reference…")
                            .frame(maxWidth: .infinity, minHeight: 130)
                    } else {
                        Text(title).font(.folioDisplay(.title))
                        Text(extract).textSelection(.enabled)
                        if let article {
                            Link(destination: article) {
                                Label("Read on Wikipedia", systemImage: "arrow.up.right.square")
                                    .frame(maxWidth: .infinity, minHeight: 42)
                            }
                            .folioGlassPill(prominent: true)
                        }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Fun Fact")
            .folioScreen()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.folioGlassPill()
                }
            }
        }
        .task(id: selection) { await load() }
    }

    private func load() async {
        let topic = String(selection.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !topic.isEmpty else { return }
        title = topic
        loading = true
        defer { loading = false }
        do {
            var components = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
            components.queryItems = [
                URLQueryItem(name: "action", value: "query"),
                URLQueryItem(name: "prop", value: "extracts"),
                URLQueryItem(name: "exintro", value: "1"),
                URLQueryItem(name: "explaintext", value: "1"),
                URLQueryItem(name: "redirects", value: "1"),
                URLQueryItem(name: "format", value: "json"),
                URLQueryItem(name: "titles", value: topic)
            ]
            var request = URLRequest(url: components.url!)
            request.timeoutInterval = 20
            request.setValue("Folio Reader/1.0 (reading reference)", forHTTPHeaderField: "User-Agent")
            let (bytes, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let json = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
            let query = json?["query"] as? [String: Any]
            let pages = query?["pages"] as? [String: [String: Any]]
            if let page = pages?.values.first, page["missing"] == nil,
               let value = page["extract"] as? String, !value.isEmpty {
                title = page["title"] as? String ?? topic
                extract = String(value.prefix(2000))
                if let id = page["pageid"] as? Int {
                    article = URL(string: "https://en.wikipedia.org/?curid=\(id)")
                }
            } else {
                extract = "No verified reference article was found. Select a name, place, or subject."
            }
        } catch {
            extract = "Couldn't retrieve a reference: \(error.localizedDescription)"
        }
    }
}

struct FolioMobileTranslationView: View {
    let original: String
    let translated: String
    let error: String?
    let loading: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Original").font(.headline)
                    Text(original).foregroundStyle(.secondary).textSelection(.enabled)
                    Divider()
                    Text("Translation").font(.headline)
                    if loading {
                        ProgressView("Translating…")
                    } else if let error {
                        Text(error).foregroundStyle(.secondary)
                    } else {
                        Text(translated).textSelection(.enabled)
                    }
                    if !translated.isEmpty {
                        FolioGlassButton(title: "Copy Translation", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = translated
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(22)
            }
            .navigationTitle("Translate Selection")
            .folioScreen()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.folioGlassPill()
                }
            }
        }
    }
}
