// Run: swiftc -swift-version 5 -o /tmp/folio-pdf-check checks/pdf-annotations-smoke.swift Sources/Folio/PDFAnnotationSupport.swift && /tmp/folio-pdf-check
import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

// Standalone compatible model types let this exercise the production PDF helper
// without starting Folio or disturbing a running reader.
enum ReadingAnnotationKind { case bookmark, highlight, note, quote }
struct ReadingAnnotation {
    let id: UUID
    let chapter: Int
    let kind: ReadingAnnotationKind
    let text: String
    let note: String
}
@MainActor final class PDFReaderModel {
    let document: PDFDocument
    init(document: PDFDocument) { self.document = document }
}

@main struct PDFAnnotationSmoke {
    @MainActor static func main() {
        let data = NSMutableData()
        var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &rect, nil) else {
            fatalError("Unable to create sample PDF")
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "Barcelona is a city in Spain.",
                               attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        )
        context.textPosition = CGPoint(x: 60, y: 700)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data),
              let page = document.page(at: 0) else { fatalError("Could not read generated PDF") }
        let reader = PDFReaderModel(document: document)
        let example = ReadingAnnotation(id: UUID(), chapter: 0, kind: .highlight,
                                        text: "Barcelona", note: "")
        reader.showHighlights([example])
        let marks = page.annotations.filter { $0.userName?.hasPrefix("folio-reading-annotation:") == true }
        precondition(!marks.isEmpty, "Saved PDF highlights should appear in the viewer")
        reader.showHighlights([])
        precondition(!page.annotations.contains { $0.userName?.hasPrefix("folio-reading-annotation:") == true },
                     "Removed highlights should disappear from the viewer")
        precondition(document.dataRepresentation() != nil, "PDF document remains readable")
        print("PDF annotation smoke passed (apply, remove, preserve document).")
    }
}
