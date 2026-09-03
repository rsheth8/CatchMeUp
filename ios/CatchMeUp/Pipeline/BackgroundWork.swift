import BackgroundTasks
import Foundation
import UIKit
import UserNotifications

// Everything that keeps processing alive once the user has stopped looking at
// the app: a background assertion for the seconds right after a swipe away, a
// scheduled task for the rest, and a notification when the notes land.

// MARK: - Background assertion

/// Holds one `beginBackgroundTask` assertion for as long as work is running.
///
/// While the app is in the foreground this changes nothing — iOS isn't going to
/// suspend a visible app. It matters at the moment the user leaves: without an
/// assertion the app is suspended in seconds, mid-transcription, and the Live
/// Activity is left showing a percentage that will never move again.
@MainActor
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var onExpiry: (() -> Void)?

    var isHeld: Bool { identifier != .invalid }

    func begin(name: String, onExpiry: @escaping () -> Void) {
        guard identifier == .invalid else { return }
        self.onExpiry = onExpiry
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // iOS is about to suspend us whatever we do. Hand back the
            // assertion first, then let the queue park its work.
            guard let self else { return }
            let expiring = self.onExpiry
            self.end()
            expiring?()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
        onExpiry = nil
    }

    /// Roughly how long iOS is still willing to run us. `.greatestFiniteMagnitude`
    /// while in the foreground.
    static var remainingTime: TimeInterval {
        UIApplication.shared.backgroundTimeRemaining
    }
}

// MARK: - Scheduled resumption

/// A `BGProcessingTask` picks up whatever the 30-second assertion couldn't
/// finish. iOS decides when — usually while charging — so this is the safety
/// net rather than the main path.
enum BackgroundRefresh {
    static let identifier = "com.catchmeup.app.recap-processing"

    /// Registered from `didFinishLaunchingWithOptions`; iOS requires it before
    /// launch completes or it throws.
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier, using: nil
        ) { task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            handle(task)
        }
    }

    static func schedule(needsNetwork: Bool) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = needsNetwork
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Simulators and devices with Background App Refresh switched off
            // both land here. The queue still resumes the next time the app is
            // opened, which is the common case anyway.
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }

    private static func handle(_ task: BGProcessingTask) {
        let work = Task { @MainActor in
            await ProcessingQueue.shared.resumeUnfinishedWork()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = {
            work.cancel()
            Task { @MainActor in ProcessingQueue.shared.parkForLaterResumption() }
        }
    }
}

// MARK: - Notifications

/// Tells the user their recap is ready when they aren't in the app to see it.
///
/// Authorization is requested provisionally, so nothing prompts on first launch
/// — the first notification arrives quietly in Notification Center with a
/// keep/turn-off choice attached to it.
enum RecapNotifier {
    private static let category = "recapReady"

    static func prepare() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge, .provisional]) { _, _ in }
        }
    }

    static func recapReady(_ recording: Recording) {
        let body: String
        if let gist = recording.recap?.tldr?.first, !gist.isEmpty {
            body = gist
        } else {
            body = "Your notes are ready to read."
        }
        post(title: recording.displayTitle, body: body, recordingID: recording.id)
    }

    static func recapFailed(_ recording: Recording, message: String) {
        post(title: "Couldn't finish \(recording.displayTitle)",
             body: message,
             recordingID: recording.id)
    }

    private static func post(title: String, body: String, recordingID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["deepLink": CatchMeUpLink.recap(recordingID).absoluteString]
        if #available(iOS 15.0, *) { content.interruptionLevel = .active }

        let request = UNNotificationRequest(
            identifier: "recap.\(recordingID.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// Tapping a notification opens the recap it's about.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationRouter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let raw = response.notification.request.content.userInfo["deepLink"] as? String,
           let url = URL(string: raw) {
            PendingRouteStore.save(url)
        }
        completionHandler()
    }

    /// The recap is already on screen behind the banner often enough that
    /// suppressing it would be wrong — the user asked to be told.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
