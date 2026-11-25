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
            Toggle("Sync My Devices", isOn: Binding(
                get: { sync.isEnabled },
                set: { sync.isEnabled = $0 }
            ))
            if sync.isEnabled {
                Button { copyCode() } label: {
                    LabeledContent("Sync Code") {
                        Text(copied ? "Copied" : CloudSyncMerge.display(sync.code))
                            .font(copied ? .body : .body.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
                Button("Pair with Another Device", systemImage: "link") {
                    typedCode = ""
                    joining = true
                }
                .folioFormButton()
                Button { Task { await sync.syncNow() } } label: {
                    LabeledContent("Status") {
                        Text(status)
                            .foregroundStyle(sync.lastError == nil ? Color.secondary : FolioTheme.caution)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .tint(.primary)
                .disabled(sync.syncing)
            }
        } header: {
            Text("Devices")
        } footer: {
            Text(sync.isEnabled
                 ? "Turn on sync on your other device and enter this code there."
                 : "Keeps progress, status and collections the same on your Mac, iPhone and iPad. No account needed.")
        }
        .folioRow()
        .alert("Pair with Another Device", isPresented: $joining) {
            TextField("XXXX-XXXX-XXXX-XXXX", text: $typedCode)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.characters)
                #endif
            Button("Paste") {
                typedCode = pasteboardString() ?? typedCode
                join()
            }
            Button("Pair") { join() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter the sync code shown on your other device.")
        }
        .alert("That isn't a sync code", isPresented: $badCode) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A sync code has 16 letters and numbers, like ABCD-EFGH-JKLM-NPQR.")
        }
    }

    private var status: String {
        if sync.syncing && sync.lastSync == nil { return "Syncing…" }
        if let error = sync.lastError { return error }
        guard sync.lastSync != nil else { return "Not synced yet" }
        if let peer = sync.peers.first {
            let others = sync.peers.count > 1 ? " +\(sync.peers.count - 1)" : ""
            return "Synced with \(peer.name)\(others)"
        }
        return "Waiting for another device"
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
