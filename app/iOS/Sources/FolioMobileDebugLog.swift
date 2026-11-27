import Darwin
import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A plain-text runtime log at Documents/Folio.log, visible in the Files app.
///
/// It records launches, tab changes, network and memory checkpoints, and on a
/// crash the reason and backtrace: uncaught Objective-C exceptions, fatal
/// signals (Swift traps arrive as SIGTRAP), and Swift's own "Fatal error"
/// message, which goes to stderr and so is redirected into the file too.
/// When iOS kills the app for memory, nothing can run, so the next launch
/// notes that the previous session ended without closing normally.
enum FolioLog {
    static var fileURL: URL { documents.appendingPathComponent("Folio.log") }
    static var previousURL: URL { documents.appendingPathComponent("Folio.previous.log") }

    private static var documents: URL {
        #if os(macOS)
        // On the Mac the log sits with other app logs, in ~/Library/Logs/Folio.
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs/Folio", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
        #else
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }

    private static var markerURL: URL { documents.appendingPathComponent(".folio-running") }

    /// The open log file. Written with plain write(2), which is thread-safe
    /// and still usable from a signal handler.
    nonisolated(unsafe) fileprivate static var fd: Int32 = -1
    nonisolated(unsafe) fileprivate static var previousHandlers: [Int32: sig_t] = [:]
    nonisolated(unsafe) private static var started = false
    /// Set by the scene phase, so the hang watch ignores time spent suspended.
    nonisolated(unsafe) static var inBackground = false
    nonisolated(unsafe) static var lastSceneChange = Date.distantPast

    static let fatalSignals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGSYS]

    /// Opens the log and installs the crash handlers. Call once, first thing at launch.
    static func start() {
        guard !started else { return }
        started = true
        let manager = FileManager.default
        let path = fileURL.path
        if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int, size > 1_500_000 {
            try? manager.removeItem(at: previousURL)
            try? manager.moveItem(at: fileURL, to: previousURL)
        }
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        // Swift runtime errors ("Fatal error: …") are printed to stderr just before the trap.
        dup2(fd, STDERR_FILENO)

        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        raw("\n===== Launch \(Date().formatted(.iso8601)) =====\n")
        if manager.fileExists(atPath: markerURL.path) {
            log("The previous session ended without closing normally: iOS killed it (often for memory) or it crashed before anything below was written.", "launch")
        }
        log("Folio \(version) (\(build)), \(systemName) \(systemVersion), \(machine()), memory \(footprintMB()) MB", "launch")
        log("Log file: \(path)", "launch")
        markRunning()

        NSSetUncaughtExceptionHandler { exception in
            FolioLog.raw("\n*** CRASH: uncaught exception \(exception.name.rawValue): \(exception.reason ?? "no reason")\n")
            FolioLog.raw(exception.callStackSymbols.joined(separator: "\n") + "\n")
        }
        for sig in fatalSignals {
            previousHandlers[sig] = signal(sig, folioSignalHandler)
        }
        watchMainThread()
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { _ in
            FolioLog.log("Memory warning, using \(FolioLog.footprintMB()) MB", "memory")
        }
        #endif
    }

    private static var systemName: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }

    private static var systemVersion: String {
        #if os(macOS)
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #else
        UIDevice.current.systemVersion
        #endif
    }

    /// Pings the main thread every second from a background thread and logs any time
    /// it takes longer than half a second to answer, so hangs show up in the log.
    private static func watchMainThread() {
        Thread.detachNewThread {
            Thread.current.name = "folio.hang-watch"
            while true {
                let answered = DispatchSemaphore(value: 0)
                let sent = Date()
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 0.5) == .timedOut {
                    answered.wait()
                    // iOS suspends the app in the background, which freezes the main
                    // thread too: that pause is not a hang, so it isn't logged.
                    guard !inBackground, lastSceneChange < sent else { Thread.sleep(forTimeInterval: 1); continue }
                    let seconds = Date().timeIntervalSince(sent)
                    log("Main thread blocked for \(seconds.formatted(.number.precision(.fractionLength(1)))) s, "
                        + "memory \(footprintMB()) MB", "hang")
                }
                Thread.sleep(forTimeInterval: 1)
            }
        }
    }

    /// One timestamped line, e.g. `12:04:31.220 [discover] Loaded Fantasy: 20 books`.
    static func log(_ message: String, _ category: String = "app") {
        let time = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits)
            .secondFraction(.fractional(3)))
        raw("\(time) [\(category)] \(message)\n")
    }

    fileprivate static func raw(_ text: String) {
        guard fd >= 0 else { return }
        var text = text
        text.withUTF8 { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = write(fd, base, buffer.count)
        }
    }

    /// The app is in front: until it closes normally, an end counts as unexpected.
    static func markRunning() {
        FileManager.default.createFile(atPath: markerURL.path, contents: Data())
    }

    /// The app went to the background, where iOS may end it at any time without that being a fault.
    static func markClosedNormally() {
        try? FileManager.default.removeItem(at: markerURL)
    }

    /// Physical memory the app is using, as iOS counts it for its memory limit.
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint / 1_048_576) : -1
    }

    private static func machine() -> String {
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }
}

/// Writes the signal and a raw backtrace, then lets the crash continue as before.
private func folioSignalHandler(_ sig: Int32) {
    let fd = FolioLog.fd
    if fd >= 0 {
        let name: StaticString
        switch sig {
        case SIGTRAP: name = "\n*** CRASH: SIGTRAP (Swift runtime trap, see the Fatal error line above if any)\n"
        case SIGABRT: name = "\n*** CRASH: SIGABRT (abort)\n"
        case SIGSEGV: name = "\n*** CRASH: SIGSEGV (bad memory access)\n"
        case SIGBUS: name = "\n*** CRASH: SIGBUS (bad memory access)\n"
        case SIGILL: name = "\n*** CRASH: SIGILL (illegal instruction)\n"
        case SIGFPE: name = "\n*** CRASH: SIGFPE (arithmetic error)\n"
        default: name = "\n*** CRASH: fatal signal\n"
        }
        _ = write(fd, name.utf8Start, name.utf8CodeUnitCount)
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 80)
        let count = backtrace(&frames, Int32(frames.count))
        backtrace_symbols_fd(&frames, count, fd)
        fsync(fd)
    }
    let previous = FolioLog.previousHandlers[sig]
    signal(sig, previous ?? SIG_DFL)
    raise(sig)
}

extension View {
    /// Logs scene changes and keeps the "closed normally" marker current.
    func folioLogsLifecycle() -> some View {
        modifier(FolioLogLifecycle())
    }
}

private struct FolioLogLifecycle: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content.onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                FolioLog.inBackground = false
                FolioLog.lastSceneChange = Date()
                FolioLog.markRunning()
                FolioLog.log("Active, memory \(FolioLog.footprintMB()) MB", "scene")
            case .background:
                FolioLog.inBackground = true
                FolioLog.lastSceneChange = Date()
                FolioLog.log("Background", "scene")
                FolioLog.markClosedNormally()
                LibraryStore.shared.flushWidgets()
                FolioSystemIntegration.update(LibraryStore.shared)
            default: break
            }
        }
    }
}

/// Settings row: where the log lives, and a share button for it.
struct FolioDebugLogRow: View {
    var body: some View {
        ShareLink(item: FolioLog.fileURL) {
            Label("Share Debug Log", systemImage: "doc.text.magnifyingglass")
        }
        Text("Also in Files: Folio's Documents folder, Folio.log.")
            .font(.footnote)
            .foregroundStyle(FolioTheme.muted)
    }
}
