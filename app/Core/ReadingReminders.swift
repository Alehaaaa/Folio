#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif
import Observation
import UserNotifications

/// Local, opt-in reading reminders. The anchor date keeps multi-day schedules stable
/// across launches; refreshing the notification queue extends the rolling horizon.
@Observable
@MainActor
final class ReadingReminders: NSObject, UNUserNotificationCenterDelegate {
    enum Frequency: Int, CaseIterable, Identifiable {
        case daily = 1
        case everyTwoDays = 2
        case everyThreeDays = 3
        case weekly = 7

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .daily: "Every day"
            case .everyTwoDays: "Every 2 days"
            case .everyThreeDays: "Every 3 days"
            case .weekly: "Every 7 days"
            }
        }
    }

    static let shared = ReadingReminders()

    nonisolated private static let notificationPrefix = "folio.reading-reminder."
    private static let enabledKey = "readingReminders.enabled"
    private static let frequencyKey = "readingReminders.frequency"
    private static let hourKey = "readingReminders.hour"
    private static let minuteKey = "readingReminders.minute"
    private static let anchorKey = "readingReminders.anchor"
    nonisolated private static let foregroundKey = "readingReminders.foreground"
    private static let queueSize = 60 // macOS may limit the number of pending requests per app.

    var enabled: Bool
    var frequency: Frequency
    var reminderTime: Date
    var showWhileOpen: Bool
    var authorizationStatus: UNAuthorizationStatus = .notDetermined
    var isUpdating = false
    var errorMessage: String?
    var nextReminder: Date?

    private var anchorDay: Date?
    // UserNotifications assumes a LaunchServices application bundle. SwiftPM's
    // raw `.build/.../Folio` executable has no bundle proxy; calling `.current()`
    // from that executable raises an uncaught Objective-C exception on macOS.
    // Keep development/CLI launches useful without disabling real app reminders.
    private static var hasApplicationBundle: Bool {
        Bundle.main.bundleURL.pathExtension.lowercased() == "app" &&
        Bundle.main.bundleIdentifier != nil
    }
    @ObservationIgnored private lazy var notifications: UNUserNotificationCenter? = {
        ReadingReminders.hasApplicationBundle ? UNUserNotificationCenter.current() : nil
    }()
    private var scheduleTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var lastScheduledAt: Date?

    private override init() {
        let defaults = UserDefaults.standard
        enabled = defaults.bool(forKey: Self.enabledKey)
        frequency = Frequency(rawValue: defaults.integer(forKey: Self.frequencyKey)) ?? .daily
        let hour = defaults.object(forKey: Self.hourKey) as? Int ?? 20
        let minute = defaults.object(forKey: Self.minuteKey) as? Int ?? 0
        reminderTime = Calendar.current.date(bySettingHour: min(23, max(0, hour)),
                                             minute: min(59, max(0, minute)),
                                             second: 0, of: Date()) ?? Date()
        showWhileOpen = defaults.object(forKey: Self.foregroundKey) as? Bool ?? true
        anchorDay = defaults.object(forKey: Self.anchorKey) as? Date
        super.init()
    }

    /// Called once from the application's launch callback, after macOS initializes the app.
    /// Reading the authorization state here never triggers a permission prompt.
    func startup() async {
        guard let notifications else {
            errorMessage = "Reading notifications require Folio.app. Launch the application bundle instead of the Swift build executable."
            return
        }
        notifications.delegate = self
        if activationObserver == nil {
            #if os(macOS)
            let notificationName = NSApplication.didBecomeActiveNotification
            #else
            let notificationName = UIApplication.didBecomeActiveNotification
            #endif
            activationObserver = NotificationCenter.default.addObserver(
                forName: notificationName, object: nil, queue: .main
            ) { _ in
                Task { @MainActor in await ReadingReminders.shared.onActivation() }
            }
        }
        await refreshAuthorization()
        enqueueReschedule()
    }

    func refreshAuthorization() async {
        guard let notifications else {
            authorizationStatus = .denied
            return
        }
        authorizationStatus = await notifications.notificationSettings().authorizationStatus
    }

    func setEnabled(_ value: Bool) async {
        guard !isUpdating else { return }
        guard let notifications else {
            enabled = false
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            errorMessage = "Notifications are available when Folio is launched as an app bundle."
            return
        }
        isUpdating = true
        defer { isUpdating = false }

        if value {
            await refreshAuthorization()
            if authorizationStatus == .notDetermined {
                do {
                    _ = try await notifications.requestAuthorization(options: [.alert, .sound])
                } catch {
                    errorMessage = "Couldn't request notification permission: \(error.localizedDescription)"
                }
                await refreshAuthorization()
            }
            guard isAuthorized else {
                enabled = false
                UserDefaults.standard.set(false, forKey: Self.enabledKey)
                enqueueReschedule()
                return
            }
            resetAnchor()
            errorMessage = nil
        } else {
            nextReminder = nil
            errorMessage = nil
        }

        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
        enqueueReschedule()
        await scheduleTask?.value
        if !value { await clearDeliveredReminders() }
    }

    func setFrequency(_ value: Frequency) {
        guard frequency != value else { return }
        frequency = value
        UserDefaults.standard.set(value.rawValue, forKey: Self.frequencyKey)
        resetAnchor()
        if enabled { enqueueReschedule() }
    }

    func setReminderTime(_ value: Date) {
        let old = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        let time = Calendar.current.dateComponents([.hour, .minute], from: value)
        guard old.hour != time.hour || old.minute != time.minute else { return }
        reminderTime = value
        UserDefaults.standard.set(time.hour ?? 20, forKey: Self.hourKey)
        UserDefaults.standard.set(time.minute ?? 0, forKey: Self.minuteKey)
        resetAnchor()
        if enabled { enqueueReschedule() }
    }

    func setShowWhileOpen(_ value: Bool) {
        showWhileOpen = value
        UserDefaults.standard.set(value, forKey: Self.foregroundKey)
    }

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    func openSystemNotificationSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else { return }
        NSWorkspace.shared.open(url)
        #else
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
        #endif
    }

    private func onActivation() async {
        let previous = authorizationStatus
        await refreshAuthorization()
        // Refresh after settings changes or periodically while Folio remains running.
        if previous != authorizationStatus || lastScheduledAt == nil ||
            Date().timeIntervalSince(lastScheduledAt!) > 24 * 60 * 60 {
            enqueueReschedule()
        }
    }

    private func resetAnchor() {
        guard let next = nextTime(after: Date()) else { return }
        anchorDay = Calendar.current.startOfDay(for: next)
        UserDefaults.standard.set(anchorDay, forKey: Self.anchorKey)
    }

    private func nextTime(after date: Date) -> Date? {
        let time = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        return Calendar.current.nextDate(after: date, matching: time, matchingPolicy: .nextTime)
    }

    /// Serialize replacements: canceled work finishes before its successor removes old IDs.
    private func enqueueReschedule() {
        let prior = scheduleTask
        prior?.cancel()
        scheduleTask = Task { [weak self] in
            await prior?.value
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await self.reconcileNotifications()
        }
    }

    private func reconcileNotifications() async {
        guard let notifications else { return }
        let existing = await notifications.pendingNotificationRequests()
        guard !Task.isCancelled else { return }
        let ids = existing.map(\.identifier).filter { $0.hasPrefix(Self.notificationPrefix) }
        if !ids.isEmpty { notifications.removePendingNotificationRequests(withIdentifiers: ids) }
        nextReminder = nil
        lastScheduledAt = Date()

        guard enabled else { return }
        await refreshAuthorization()
        guard isAuthorized, !Task.isCancelled else { return }

        let now = Date()
        if anchorDay == nil { resetAnchor() }
        guard let anchorDay else { return }
        let calendar = Calendar.current
        let dayDifference = max(0, calendar.dateComponents([.day], from: anchorDay,
                                                           to: calendar.startOfDay(for: now)).day ?? 0)
        let passedPeriods = dayDifference / frequency.rawValue
        var day = calendar.date(byAdding: .day, value: passedPeriods * frequency.rawValue,
                                to: anchorDay) ?? anchorDay
        let hour = calendar.component(.hour, from: reminderTime)
        let minute = calendar.component(.minute, from: reminderTime)
        func fireTime(on day: Date) -> Date? {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)
        }
        var firstDate: Date
        while true {
            guard let date = fireTime(on: day) else { return }
            if date > now {
                firstDate = date
                break
            }
            guard let following = calendar.date(byAdding: .day, value: frequency.rawValue, to: day) else { return }
            day = following
        }
        nextReminder = firstDate

        // Daily and weekly calendars repeat indefinitely; 2/3-day intervals require
        // explicitly queued dates (a repeating calendar cannot express those cadences).
        if frequency == .daily || frequency == .weekly {
            var components = calendar.dateComponents([.hour, .minute], from: firstDate)
            if frequency == .weekly { components.weekday = calendar.component(.weekday, from: firstDate) }
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            await addRequest(id: "\(Self.notificationPrefix)repeating", trigger: trigger)
        } else {
            for index in 0..<Self.queueSize {
                guard !Task.isCancelled else { return }
                guard let targetDay = calendar.date(byAdding: .day, value: index * frequency.rawValue, to: day),
                      let fireDate = fireTime(on: targetDay) else { return }
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                await addRequest(id: "\(Self.notificationPrefix)\(index)", trigger: trigger)
            }
        }
    }

    private func addRequest(id: String, trigger: UNNotificationTrigger) async {
        guard let notifications else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time for a little reading"
        content.body = "Open Folio and enjoy a few pages of your book."
        content.sound = .default
        do {
            try await notifications.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            errorMessage = nil
        } catch {
            errorMessage = "Couldn't schedule a reading reminder: \(error.localizedDescription)"
        }
    }

    private func clearDeliveredReminders() async {
        guard let notifications else { return }
        let delivered = await notifications.deliveredNotifications()
        let ids = delivered.map(\.request.identifier).filter { $0.hasPrefix(Self.notificationPrefix) }
        if !ids.isEmpty { notifications.removeDeliveredNotifications(withIdentifiers: ids) }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let isReadingReminder = notification.request.identifier.hasPrefix(Self.notificationPrefix)
        let showInForeground = UserDefaults.standard.object(forKey: Self.foregroundKey) as? Bool ?? true
        if isReadingReminder && !showInForeground { return [] }
        return [.banner, .sound]
    }
}
