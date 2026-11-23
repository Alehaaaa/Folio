import SwiftUI
import AppKit
import ScreenCaptureKit

extension Notification.Name {
    static let folioImport = Notification.Name("folio.import")
}

enum ScreenshotMode {
    static let path: String? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--screenshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    /// Lets about 120 frames draw, saves the main window as a PNG, then quits.
    @MainActor static func run(_ path: String) {
        var frames = 0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { timer in
            MainActor.assumeIsolated {
                frames += 1
                for w in NSApp.windows where w.isVisible { w.viewsNeedDisplay = true }
                // Testing aid: FOLIO_SHOT_FRAMES lets slower test scenarios finish before the picture.
                let wanted = Int(ProcessInfo.processInfo.environment["FOLIO_SHOT_FRAMES"] ?? "") ?? 120
                guard frames >= wanted else { return }
                timer.invalidate()
                Task { @MainActor in
                    await capture(to: path)
                    exit(0)
                }
            }
        }
    }

    @MainActor static func capture(to path: String) async {
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && !($0 is NSPanel) }
        let wantReader = ProcessInfo.processInfo.environment["FOLIO_OPEN_LATEST"] != nil
        let wantWelcome = ProcessInfo.processInfo.environment["FOLIO_PREVIEW_ONBOARDING"] == "1"
        let targetID = wantWelcome ? "onboarding" : (wantReader ? "reader" : "main")
        guard let window = windows.first(where: { $0.identifier?.rawValue.hasPrefix(targetID) == true }) ?? windows.first,
              let content = window.contentView else {
            let info = NSApp.windows.map { "\($0.identifier?.rawValue ?? "-") visible=\($0.isVisible) \(type(of: $0))" }.joined(separator: "; ")
            FileHandle.standardError.write(Data("No window to capture: \(info)\n".utf8))
            return
        }
        let view = content.superview ?? content
        view.layoutSubtreeIfNeeded()
        var png: Data?
        // Only use the system capture when this Mac already allows it; never ask.
        if CGPreflightScreenCaptureAccess() && ProcessInfo.processInfo.environment["FOLIO_LAYER_CAPTURE"] == nil {
            png = await captureWithScreenCaptureKit(window)
        }
        if png == nil { png = captureLayers(view) }
        guard let png else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try png.write(to: url) } catch {
            FileHandle.standardError.write(Data("Couldn't save screenshot: \(error)\n".utf8))
        }
    }

    @MainActor static func captureWithScreenCaptureKit(_ window: NSWindow) async -> Data? {
        do {
            let shareable = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let scWindow = shareable.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { return nil }
            let filter = SCContentFilter(desktopIndependentWindow: scWindow)
            let config = SCStreamConfiguration()
            let scale = window.backingScaleFactor
            config.width = Int(window.frame.width * scale)
            config.height = Int(window.frame.height * scale)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        } catch {
            return nil
        }
    }

    /// Last resort when the system capture isn't allowed: AppKit's own view caching.
    @MainActor static func captureLayers(_ view: NSView) -> Data? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        if ScreenshotMode.path != nil {
            // Draw without taking focus from whatever the person is doing.
            NSApp.setActivationPolicy(.accessory)
            UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        } else {
            NSApp.setActivationPolicy(.regular)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let path = ScreenshotMode.path {
            for w in NSApp.windows { w.orderFrontRegardless() }
            MainActor.assumeIsolated { ScreenshotMode.run(path) }
        } else {
            NSApp.activate()
        }
        Task { @MainActor in
            if ScreenshotMode.path == nil { await ReadingReminders.shared.startup() }
            FolioWidgetBridge.publish()
            await HardcoverClient.shared.restore()
            await FolioWidgetBridge.refreshHardcover()
        }
        // Testing aid: FOLIO_IMPORT="file1:file2" adds files to the library on launch.
        if let list = ProcessInfo.processInfo.environment["FOLIO_IMPORT"], !list.isEmpty {
            let files = list.split(separator: ":").map { URL(fileURLWithPath: String($0)) }
            MainActor.assumeIsolated { LibraryStore.shared.importFiles(files) }
        }
    }

    /// Files opened with Folio from Finder are added to the library.
    func application(_ application: NSApplication, open urls: [URL]) {
        let books = urls.filter { $0.isFileURL && BookFormat.from(url: $0) != nil }
        MainActor.assumeIsolated { LibraryStore.shared.importFiles(books) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct FolioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = LibraryStore.shared
    @State private var hc = HardcoverClient.shared
    @State private var gr = GoodreadsClient.shared
    @State private var prefs = ReaderPrefsStore.shared
    @State private var exts = ExtensionStore.shared
    @State private var popups = PopupCenter.shared
    @State private var navigation = FolioMobileNavigation()

    init() {
        FolioLog.start()
        FolioShelfSync.install()
    }

    var body: some Scene {
        WindowGroup("Folio", id: "main") {
            FolioMacRootView()
                .folioCoverPeekHost()
                .tint(FolioTheme.accent)
                .environment(store)
                .environment(hc)
                .environment(gr)
                .environment(prefs)
                .environment(exts)
                .environment(popups)
                .environment(navigation)
                .folioLogsLifecycle()
                .task {
                    await exts.checkForExtensionUpdates()
                    // Restore persisted jobs on every launch, even when Downloads
                    // has never been opened in the current session.
                    _ = DownloadQueue.shared
                    FolioShelfSync.shared.pushPending(library: store)
                    store.enqueueUnlinkedEPUBs()
                }
        }
        .defaultSize(width: 1280, height: 860)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { NotificationCenter.default.post(name: .folioShowSettings, object: nil) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Add to Library…") { NotificationCenter.default.post(name: .folioImport, object: nil) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
            }
        }

        WindowGroup("Reader", id: "reader", for: UUID.self) { $id in
            if let id {
                ReaderWindow(bookID: id)
                    .environment(store)
                    .environment(hc)
                    .environment(gr)
                    .environment(prefs)
                    .environment(exts)
                    .environment(popups)
                    .environment(navigation)
            }
        }
        .defaultSize(width: 1100, height: 780)
        .restorationBehavior(.disabled)
    }
}
