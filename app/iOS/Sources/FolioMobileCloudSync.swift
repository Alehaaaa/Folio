import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Settings › Sync: turns Folio Sync on and pairs devices by sync code.
struct FolioCloudSyncSection: View {
    @State private var sync = FolioCloudSync.shared
    @State private var joining = false
    @State private var typedCode = ""
    @State private var badCode = false
    @State private var copied = false

    var body: some View {
        Section {
            Toggle("Sync Reading Progress", isOn: Binding(
                get: { sync.isEnabled },
                set: { sync.isEnabled = $0 }
            ))
            if sync.isEnabled {
                LabeledContent("Sync Code") {
                    Text(CloudSyncMerge.display(sync.code))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
                Button(copied ? "Copied" : "Copy Sync Code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    copyCode()
                }
                .folioFormButton()
                Button("Use a Code from Another Device…", systemImage: "link") {
                    typedCode = ""
                    joining = true
                }
                .folioFormButton()
                LabeledContent("Status") {
                    Text(status).foregroundStyle(sync.lastError == nil ? Color.secondary : FolioTheme.caution)
                        .multilineTextAlignment(.trailing)
                }
                Button(sync.syncing ? "Syncing…" : "Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await sync.syncNow() }
                }
                .disabled(sync.syncing || sync.endpoint.isEmpty)
                .folioFormButton()
                if sync.endpoint.isEmpty || sync.endpoint != FolioCloudSync.defaultEndpoint {
                    TextField("Sync server URL", text: Binding(
                        get: { sync.endpoint },
                        set: { sync.endpoint = $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    ))
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                }
            }
        } header: {
            Text("Sync")
        } footer: {
            Text(sync.isEnabled
                 ? "Copy this code, then on your other device turn on sync, tap Use a Code from Another Device and paste it. Progress, reading position, status and collections sync for books both devices have."
                 : "Keeps your reading progress, status and collections the same on your Mac, iPhone and iPad. No account needed.")
        }
        .folioRow()
        .alert("Sync Code", isPresented: $joining) {
            TextField("XXXX-XXXX-XXXX-XXXX", text: $typedCode)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
            Button("Paste") {
                typedCode = pasteboardString() ?? typedCode
                join()
            }
            Button("Use Code") { join() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter or paste the sync code shown in Settings on your other device.")
        }
        .alert("That isn't a sync code", isPresented: $badCode) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A sync code has 16 letters and numbers, like ABCD-EFGH-JKLM-NPQR.")
        }
    }

    private var status: String {
        if sync.endpoint.isEmpty { return "No sync server set" }
        if let error = sync.lastError { return error }
        guard let last = sync.lastSync else { return sync.syncing ? "Syncing…" : "Not synced yet" }
        let when = last.formatted(.relative(presentation: .named))
        if let peer = sync.peers.first {
            let others = sync.peers.count > 1 ? " and \(sync.peers.count - 1) more" : ""
            return "Synced \(when) with \(peer.name)\(others)"
        }
        return "Synced \(when). No other device yet"
    }

    private func join() {
        if !sync.join(typedCode) { badCode = true }
    }

    private func copyCode() {
        let text = CloudSyncMerge.display(sync.code)
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }

    private func pasteboardString() -> String? {
        #if os(iOS)
        UIPasteboard.general.string
        #else
        NSPasteboard.general.string(forType: .string)
        #endif
    }
}

extension View {
    /// Runs Folio Sync for the app: at launch, on returning to the app, and
    /// as the app leaves the screen.
    func folioCloudSync() -> some View { modifier(FolioCloudSyncLifecycle()) }

    /// Keeps Folio Sync from moving a book's position while it is open here.
    func folioSyncReader(_ id: UUID) -> some View {
        onAppear { FolioCloudSync.shared.readerOpened(id) }
            .onDisappear { FolioCloudSync.shared.readerClosed(id) }
    }
}

private struct FolioCloudSyncLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var phase

    func body(content: Content) -> some View {
        content
            .task { FolioCloudSync.shared.start() }
            .onChange(of: phase) { _, phase in
                switch phase {
                case .active: FolioCloudSync.shared.requestSync(after: 0)
                case .background: pushBeforeSuspending()
                default: break
                }
            }
    }

    private func pushBeforeSuspending() {
        #if os(iOS)
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask(withName: "Folio Sync") {
            UIApplication.shared.endBackgroundTask(task)
        }
        Task {
            await FolioCloudSync.shared.syncNow()
            UIApplication.shared.endBackgroundTask(task)
        }
        #else
        Task { await FolioCloudSync.shared.syncNow() }
        #endif
    }
}
