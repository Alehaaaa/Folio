import SwiftUI

/// A small handoff between book discovery, background source retrieval and reading.
/// The main screens remain free for browsing while the queue keeps working.
struct BookJourneyCard: View {
    let showDownloads: () -> Void

    @State private var queue = DownloadQueue.shared
    @Environment(LibraryStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    private var ready: DownloadJob? {
        queue.jobs.first { job in
            guard job.stage == .completed, let id = job.importedBookID,
                  let book = store.book(id) else { return false }
            return book.lastOpenedAt == nil
        }
    }

    private var active: DownloadJob? {
        queue.jobs.first(where: { $0.stage.isActive })
    }

    private var failed: DownloadJob? {
        queue.jobs.first(where: { $0.stage == .failed })
    }

    var body: some View {
        if let job = ready ?? active ?? failed {
            GlassCard(padding: 19) {
                HStack(alignment: .center, spacing: 17) {
                    CoverArt(title: job.title, author: job.author, remote: job.cover, cornerRadius: 6)
                        .frame(width: 61)

                    VStack(alignment: .leading, spacing: 7) {
                        Label(heading(job), systemImage: symbol(job))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(job.stage == .completed ? Color.green : job.stage == .failed ? Color.orange : Color.secondary)
                        Text(job.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(detail(job))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        if job.stage.isActive {
                            ProgressView().controlSize(.mini)
                                .accessibilityLabel("Finding a readable copy")
                        }
                    }
                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 9) {
                        if job.stage == .completed, let id = job.importedBookID, store.book(id) != nil {
                            Button {
                                openWindow(id: "reader", value: id)
                            } label: {
                                Label("Read Now", systemImage: "book.fill")
                                    .font(.callout.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 9)
                            }
                            .buttonStyle(BookPrimaryActionStyle())
                            .buttonBorderShape(.capsule)
                            .controlSize(.large)
                            Button("Book Details") { BookDetailsPresenter.showLocal(id) }
                                .buttonStyle(BookSecondaryActionStyle())
                                .font(.caption.weight(.medium))
                        } else if job.stage == .failed {
                            Button { queue.retry(job.id) } label: {
                                Text("Retry").foregroundStyle(.white)
                            }
                                .buttonStyle(BookPrimaryActionStyle())
                                .controlSize(.regular)
                        }
                        Button("View Downloads") { showDownloads() }
                            .buttonStyle(.plain)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private func heading(_ job: DownloadJob) -> String {
        switch job.stage {
        case .completed: "READY TO READ"
        case .failed: "DOWNLOAD NEEDS ATTENTION"
        case .queued: "IN YOUR DOWNLOAD QUEUE"
        case .searching, .choosing: "FINDING A COPY"
        case .downloading: "DOWNLOADING"
        case .importing: "ADDING TO LIBRARY"
        case .cancelled: "CANCELLED"
        }
    }

    private func symbol(_ job: DownloadJob) -> String {
        switch job.stage {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle"
        case .queued: "clock"
        case .searching, .choosing: "magnifyingglass"
        case .downloading: "arrow.down.circle"
        case .importing: "books.vertical"
        case .cancelled: "xmark.circle"
        }
    }

    private func detail(_ job: DownloadJob) -> String {
        switch job.stage {
        case .completed: "Verified and added to your library. Pick up this book whenever you're ready."
        case .failed: "The source couldn't provide a readable copy. Retry or choose another source in Downloads."
        default: job.statusText.isEmpty ? "Working in the background while you keep browsing." : job.statusText
        }
    }
}
