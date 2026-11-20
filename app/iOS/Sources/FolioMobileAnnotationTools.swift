import Foundation
import SwiftUI
import WebKit
import PDFKit

/// Live reader interaction is held outside SwiftUI so the same WKWebView can
/// remain mounted while an annotation sheet is presented.
@MainActor
final class FolioMobileWebInteraction {
    weak var view: WKWebView?
    var paginated = false

    /// Flip a viewport-sized page inside the current EPUB chapter. Returning
    /// false means the caller should advance to the adjacent chapter instead.
    func turnPage(_ direction: Int) -> Bool {
        guard paginated, let view else { return false }
        let scroll = view.scrollView
        let span = max(1, scroll.bounds.width)
        let end = max(0, scroll.contentSize.width - span)
        let current = scroll.contentOffset.x
        guard end > 2 else { return false }
        if direction > 0 && current >= end - 5 { return false }
        if direction < 0 && current <= 5 { return false }
        let next = max(0, min(end, current + CGFloat(direction) * span))
        scroll.setContentOffset(CGPoint(x: next, y: 0), animated: true)
        return true
    }

    func selectedText() async -> String? {
        guard let view else { return nil }
        let script = """
            (function () {
                const selection = window.getSelection();
                return selection && !selection.isCollapsed ? selection.toString().trim().slice(0, 3000) : '';
            })()
            """
        guard let response = try? await view.evaluateJavaScript(script) as? String else { return nil }
        let cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    func highlightSelection() async {
        guard let view else { return }
        let script = """
            (function () {
                const s = window.getSelection();
                if (!s || s.isCollapsed) return;
                const r = s.getRangeAt(0).cloneRange();
                const mark = document.createElement('mark');
                mark.className = 'folio-mobile-highlight';
                try { r.surroundContents(mark); } catch (e) {}
                s.removeAllRanges();
            })()
            """
        _ = try? await view.evaluateJavaScript(script)
    }

    func restoreHighlights(_ values: [String]) {
        guard let view, !values.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: values),
              let json = String(data: data, encoding: .utf8) else { return }
        let script = """
            (function () {
                const saved = \(json);
                const texts = saved.filter(s => typeof s === 'string' && s.length && s.length < 3001);
                if (!texts.length || !document.body) return;
                const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
                    acceptNode: node => node.parentElement &&
                      !['SCRIPT', 'STYLE', 'MARK'].includes(node.parentElement.tagName)
                      ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_REJECT
                });
                const nodes = [];
                while (walker.nextNode()) nodes.push(walker.currentNode);
                for (const selected of texts) {
                    for (const node of nodes) {
                        if (!node.isConnected || !node.textContent) continue;
                        const start = node.textContent.indexOf(selected);
                        if (start < 0) continue;
                        try {
                            const range = document.createRange();
                            range.setStart(node, start);
                            range.setEnd(node, start + selected.length);
                            const mark = document.createElement('mark');
                            mark.className = 'folio-mobile-highlight';
                            range.surroundContents(mark);
                        } catch(e) {}
                        break;
                    }
                }
            })()
            """
        view.evaluateJavaScript(script, completionHandler: nil)
    }
}

@MainActor
final class FolioMobilePDFInteraction {
    weak var view: PDFView?

    func selectedText() -> String? {
        guard let selected = view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selected.isEmpty else { return nil }
        return String(selected.prefix(3000))
    }

    func highlightSelection() {
        guard let selection = view?.currentSelection else { return }
        for page in selection.pages {
            let rect = selection.bounds(for: page)
            let annotation = PDFAnnotation(bounds: rect, forType: .highlight, withProperties: nil)
            annotation.color = UIColor.systemYellow.withAlphaComponent(0.4)
            page.addAnnotation(annotation)
        }
        view?.clearSelection()
    }
}

struct FolioMobileAnnotationsSheet: View {
    let bookID: UUID
    let jump: (ReadingAnnotation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var annotations = ReadingAnnotationsStore.shared
    @State private var editing: ReadingAnnotation?
    @State private var note = ""

    var body: some View {
        NavigationStack {
            Group {
                let items = annotations.items(for: bookID)
                if items.isEmpty {
                    ContentUnavailableView(
                        "No Annotations Yet",
                        systemImage: "bookmark",
                        description: Text("Bookmark a page or select text to save a highlight, quote or note.")
                    )
                } else {
                    List {
                        ForEach(items) { entry in
                            Button {
                                jump(entry)
                                dismiss()
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: entry.kind.symbol)
                                        .foregroundStyle(.tint)
                                        .frame(width: 24)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.kind.label)
                                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        if !entry.text.isEmpty {
                                            Text(entry.text).font(.subheadline).lineLimit(4)
                                        } else {
                                            Text("Page \(entry.chapter + 1)")
                                                .font(.subheadline)
                                        }
                                        if !entry.note.isEmpty {
                                            Text(entry.note)
                                                .font(.footnote).foregroundStyle(.secondary)
                                                .lineLimit(4)
                                        }
                                        Text(entry.createdAt.formatted(date: .abbreviated, time: .omitted))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 5)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if entry.kind == .note {
                                    Button("Edit Note", systemImage: "pencil") {
                                        editing = entry
                                        note = entry.note
                                    }
                                }
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    annotations.remove(id: entry.id)
                                }
                            }
                        }
                        .onDelete { indices in
                            let items = annotations.items(for: bookID)
                            for i in indices where items.indices.contains(i) {
                                annotations.remove(id: items[i].id)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Bookmarks & Annotations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.folioGlassPill()
                }
            }
            .sheet(item: $editing) { entry in
                FolioMobileNoteEditor(
                    selectedText: entry.text,
                    note: $note
                ) { value in
                    annotations.updateNote(id: entry.id, note: value)
                    editing = nil
                }
            }
        }
    }
}

struct FolioMobileNoteEditor: View {
    let selectedText: String
    @Binding var note: String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if !selectedText.isEmpty {
                    Section("Selected Text") {
                        Text(selectedText).font(.callout).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section("Your Note") {
                    TextEditor(text: $note).frame(minHeight: 180)
                }
            }
            .navigationTitle("Reading Note")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(note.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .folioGlassPill(prominent: true)
                    .disabled(note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
