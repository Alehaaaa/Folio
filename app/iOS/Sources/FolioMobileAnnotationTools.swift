import Foundation
import SwiftUI
import WebKit
import PDFKit

/// Live PDF selection is held outside SwiftUI so the same PDFView can
/// remain mounted while an annotation sheet is presented.
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
            .folioScreen()
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
                    .folioRow()
                }
                Section("Your Note") {
                    TextEditor(text: $note).frame(minHeight: 180)
                }
                .folioRow()
            }
            .navigationTitle("Reading Note")
            .folioScreen()
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
