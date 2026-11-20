import AppKit
import PDFKit

/// Folio's PDF highlights live in the viewer document. The underlying PDF file is
/// never rewritten; the authoritative annotations are in ReadingAnnotationsStore.
@MainActor
extension PDFReaderModel {
    func showHighlights(_ entries: [ReadingAnnotation]) {
        let prefix = "folio-reading-annotation:"
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.userName?.hasPrefix(prefix) == true {
                page.removeAnnotation(annotation)
            }
        }

        for entry in entries where (entry.kind == .highlight || entry.kind == .note) && !entry.text.isEmpty {
            // Match the saved text on its original page, so the same sentence in
            // another chapter does not move the highlight.
            let candidates = document.findString(entry.text, withOptions: .caseInsensitive)
            guard let found = candidates.first(where: { selection in
                selection.pages.contains(where: { document.index(for: $0) == entry.chapter })
            }) else { continue }

            for line in found.selectionsByLine() {
                guard let page = line.pages.first,
                      document.index(for: page) == entry.chapter else { continue }
                let bounds = line.bounds(for: page).insetBy(dx: -1.5, dy: -1)
                guard bounds.width > 0, bounds.height > 0 else { continue }
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.40)
                annotation.userName = prefix + entry.id.uuidString
                annotation.contents = entry.note.isEmpty ? entry.text : entry.note
                page.addAnnotation(annotation)
            }
        }
    }
}
