import Foundation
import UserNotifications

/// The daily nudge to review.
///
/// Spaced repetition only works if you come back on the day the schedule asks
/// for, and an app you have to remember to open is an app you stop opening. So
/// the reminder isn't a fixed "study time!" alarm — it's a read of the actual
/// schedule: how much FSRS says has decayed by that morning.
///
/// A repeating notification can't do that, because its text is fixed when it's
/// scheduled. Instead this writes one notification per day for the next week,
/// each with that day's real number, and rewrites the whole run whenever the
/// numbers change — a session finishes, a recap mints questions, the app goes
/// to the background. Days with nothing due get no notification at all, which
/// is the part that keeps the rest believable.
enum StudyNotifier {
    private static let prefix = "study.due."
    static let horizon = 7

    /// Rewrites the next week of reminders from the current schedule.
    @MainActor
    static func reschedule(study: StudyStore, settings: AppSettings, from now: Date = .now) {
        guard !settings.isShowcase else { return }
        let reminderIsOn = settings.reviewReminder
        let hour = settings.reviewReminderHour
        let newLimit = settings.dailyNewLimit

        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
            guard reminderIsOn else { return }

            // Provisional authorisation, same as recap-ready notifications: the
            // first one lands quietly in Notification Center rather than opening
            // with a permission sheet the user has no context for yet.
            let granted = (try? await center.requestAuthorization(
                options: [.alert, .sound, .badge, .provisional]
            )) ?? false
            guard granted else { return }
            let entries = plan(from: now, hour: hour) { day in
                study.todayCount(newLimit: newLimit, at: day)
            }
            for entry in entries { try? await center.add(entry.request) }
        }
    }

    /// Cancels everything this type scheduled. Used when the toggle goes off.
    @MainActor
    static func cancelAll() {
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            let pending = await center.pendingNotificationRequests()
            let ours = pending.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }

    // MARK: - Building the week

    struct Entry {
        let fireDate: Date
        let count: Int
        let request: UNNotificationRequest
    }

    /// Pure apart from building the request objects: `dueAt` is injected so the
    /// day-picking rules can be tested without a store or a schedule on disk.
    static func plan(from now: Date,
                     hour: Int,
                     calendar: Calendar = .current,
                     dueAt: (Date) -> Int) -> [Entry] {
        var out: [Entry] = []

        for offset in 0..<horizon {
            guard let day = calendar.date(byAdding: .day, value: offset, to: now),
                  let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                  fire > now else { continue }
            // Counted at the moment the reminder fires, not at midnight — a card
            // due at 9pm shouldn't pad an 8am number.
            let count = dueAt(fire)
            guard count > 0 else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Time to review"
            content.body = body(count: count)
            content.sound = .default
            content.userInfo = ["deepLink": CatchMeUpLink.study().absoluteString]
            content.interruptionLevel = .active

            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
            out.append(Entry(
                fireDate: fire,
                count: count,
                request: UNNotificationRequest(
                    identifier: "\(prefix)\(offset)",
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                )
            ))
        }
        return out
    }

    /// Same 15-seconds-an-item estimate the Study tab shows, so the number in
    /// the notification and the number on the card can't disagree.
    static func body(count: Int) -> String {
        let minutes = max(1, Int((Double(count) * 15 / 60).rounded()))
        let noun = count == 1 ? "question is" : "questions are"
        return "\(count) \(noun) waiting — about \(minutes) min."
    }
}
