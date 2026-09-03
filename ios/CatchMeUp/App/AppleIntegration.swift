import CoreSpotlight
import EventKit
import Foundation
import Observation
import UniformTypeIdentifiers
import UIKit
import UserNotifications

// MARK: - Links and navigation

enum CatchMeUpLink {
    static let scheme = "catchmeup"
    static let recapActivityType = "com.catchmeup.viewRecap"

    static func recap(_ id: UUID) -> URL {
        URL(string: "\(scheme)://recap/\(id.uuidString)")!
    }

    static func brain(_ id: UUID) -> URL {
        URL(string: "\(scheme)://brain/\(id.uuidString)")!
    }

    static func brainGraph(_ id: UUID) -> URL {
        URL(string: "\(scheme)://brain/\(id.uuidString)?view=graph")!
    }

    static func record(_ mode: Mode) -> URL {
        URL(string: "\(scheme)://record?mode=\(mode.rawValue)")!
    }

    /// Opens the Study tab. `brain` scopes it to one course, which is what a
    /// reminder about a single course's backlog should land on.
    static func study(brain: UUID? = nil) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "study"
        if let brain { components.queryItems = [.init(name: "brain", value: brain.uuidString)] }
        return components.url!
    }

    static func search(_ query: String = "") -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "search"
        if !query.isEmpty { components.queryItems = [.init(name: "query", value: query)] }
        return components.url!
    }
}

enum AppTab: Hashable {
    case library, study, brains, settings
}

@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab = .library
    var libraryPath: [UUID] = []
    var brainPath: [UUID] = []
    var brainGraphID: UUID?
    var libraryQuery = ""
    var recorderMode: Mode?
    var recorderBrainID: UUID?
    var recorderRecordingID: UUID?
    /// Set by a `catchmeup://study?brain=` link; the Study tab picks it up once
    /// and clears it, so a later manual filter change isn't fought over.
    var studyBrainID: UUID?

    func open(_ url: URL) {
        guard url.scheme?.lowercased() == CatchMeUpLink.scheme else { return }
        switch url.host?.lowercased() {
        case "recap":
            selectedTab = .library
            guard let rawID = url.pathComponents.dropFirst().first,
                  let id = UUID(uuidString: rawID) else { return }
            libraryPath = [id]
        case "brain":
            selectedTab = .brains
            guard let rawID = url.pathComponents.dropFirst().first,
                  let id = UUID(uuidString: rawID) else { return }
            brainPath = [id]
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if components?.queryItems?.contains(where: { $0.name == "view" && $0.value == "graph" }) == true {
                brainGraphID = id
            }
        case "record":
            selectedTab = .library
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let rawMode = components?.queryItems?.first(where: { $0.name == "mode" })?.value
            recorderMode = Mode(rawValue: rawMode ?? "") ?? .meeting
            recorderBrainID = nil
        case "study":
            selectedTab = .study
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let rawBrain = components?.queryItems?.first(where: { $0.name == "brain" })?.value
            studyBrainID = rawBrain.flatMap(UUID.init(uuidString:))
        case "search":
            selectedTab = .library
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            libraryPath.removeAll()
            libraryQuery = components?.queryItems?.first(where: { $0.name == "query" })?.value ?? ""
        default:
            break
        }
    }

    func continueActivity(_ activity: NSUserActivity) {
        if let raw = activity.userInfo?["deepLink"] as? String, let url = URL(string: raw) {
            open(url)
        } else if let rawID = activity.userInfo?["recordingID"] as? String,
                  let id = UUID(uuidString: rawID) {
            open(CatchMeUpLink.recap(id))
        }
    }

    func consumePendingRoute() {
        guard let url = PendingRouteStore.take() else { return }
        open(url)
    }
}

// App Intents and Home Screen quick actions may execute before SwiftUI has
// built its view tree. A one-shot URL makes launch routing reliable either way.
enum PendingRouteStore {
    private static let key = "pendingAppleRoute"

    static func save(_ url: URL) {
        UserDefaults.standard.set(url.absoluteString, forKey: key)
        NotificationCenter.default.post(name: .catchMeUpRouteRequested, object: nil)
    }

    static func take() -> URL? {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        UserDefaults.standard.removeObject(forKey: key)
        return URL(string: raw)
    }
}

extension Notification.Name {
    static let catchMeUpRouteRequested = Notification.Name("CatchMeUpRouteRequested")
}

// MARK: - Spotlight

enum SpotlightIndexer {
    private static let domain = "com.catchmeup.recaps"

    static func replace(with recordings: [Recording]) {
        let visible = recordings.filter { !$0.deleted && $0.recap != nil }
        let items = visible.map(searchableItem)
        let index = CSSearchableIndex.default()

        index.deleteSearchableItems(withDomainIdentifiers: [domain]) { error in
            guard error == nil, !items.isEmpty else { return }
            index.indexSearchableItems(items)
        }
    }

    private static func searchableItem(_ recording: Recording) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = recording.displayTitle
        attributes.displayName = recording.displayTitle
        attributes.contentDescription = recording.recap?.tldr?.joined(separator: " ")
        attributes.textContent = recording.searchBlob
        attributes.contentCreationDate = recording.createdAt
        attributes.contentModificationDate = recording.updatedAt
        attributes.keywords = [recording.mode.title, "recap", "transcript", "notes"]
        attributes.contentURL = CatchMeUpLink.recap(recording.id)

        let item = CSSearchableItem(
            uniqueIdentifier: "recap.\(recording.id.uuidString)",
            domainIdentifier: domain,
            attributeSet: attributes
        )
        item.expirationDate = .distantFuture
        return item
    }
}

// MARK: - Home Screen quick actions

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Both of these have to happen before launch completes: `BGTaskScheduler`
        // throws if an identifier is registered late, and a notification tapped
        // from a cold start is delivered to the delegate almost immediately.
        BackgroundRefresh.register()
        UNUserNotificationCenter.current().delegate = NotificationRouter.shared
        return true
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = QuickActionSceneDelegate.self
        return configuration
    }
}

final class QuickActionSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let shortcut = connectionOptions.shortcutItem {
            route(shortcut)
        }
    }

    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(route(shortcutItem))
    }

    @discardableResult
    private func route(_ item: UIApplicationShortcutItem) -> Bool {
        let url: URL
        switch item.type {
        case "com.catchmeup.recordMeeting": url = CatchMeUpLink.record(.meeting)
        case "com.catchmeup.recordLecture": url = CatchMeUpLink.record(.lecture)
        case "com.catchmeup.search": url = CatchMeUpLink.search()
        default: return false
        }
        PendingRouteStore.save(url)
        return true
    }
}

// MARK: - Reminders

enum ReminderExporter {
    /// Idempotent per follow-up, including after reinstall/metadata loss when
    /// the deep link can still find the exported reminder. No background writes.
    @MainActor
    static func add(task: MeetingFollowUp, recording: Recording) async throws -> String {
        guard !task.needsReview else { throw ExportError.reviewRequired }
        let eventStore = EKEventStore()
        guard try await eventStore.requestFullAccessToReminders() else { throw ExportError.accessDenied }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else { throw ExportError.noDefaultList }
        let url = URL(string: "\(CatchMeUpLink.recap(recording.id).absoluteString)?followUp=\(task.id.uuidString)")!
        let matches = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: eventStore.predicateForReminders(in: nil)) {
                continuation.resume(returning: $0 ?? [])
            }
        }
        let existing = task.reminderID.flatMap { eventStore.calendarItem(withIdentifier: $0) as? EKReminder }
            ?? matches.first(where: { $0.url == url })
        let reminder = existing ?? EKReminder(eventStore: eventStore)
        reminder.calendar = existing?.calendar ?? calendar
        reminder.title = task.title
        reminder.notes = ["From CatchMeUp · \(recording.displayTitle)",
                          task.owner.isEmpty ? "" : "Owner: \(task.owner)",
                          task.deadlineText.isEmpty ? "" : "As stated: \(task.deadlineText)"].filter { !$0.isEmpty }.joined(separator: "\n")
        reminder.url = url
        reminder.dueDateComponents = task.dueDate.map {
            Calendar.current.dateComponents([.year, .month, .day], from: $0)
        }
        reminder.isCompleted = task.status == .done
        try eventStore.save(reminder, commit: true)
        return reminder.calendarItemIdentifier
    }

    enum ExportError: LocalizedError {
        case accessDenied
        case noDefaultList
        case reviewRequired

        var errorDescription: String? {
            switch self {
            case .reviewRequired: return "Review this follow-up before adding it to Reminders."
            case .accessDenied: return "Allow Reminders access in Settings to add this follow-up."
            case .noDefaultList: return "Choose a default list in Reminders, then try again."
            }
        }
    }

    @MainActor
    static func add(title: String, recapTitle: String) async throws {
        let eventStore = EKEventStore()
        let granted = try await eventStore.requestFullAccessToReminders()
        guard granted else { throw ExportError.accessDenied }
        guard let calendar = eventStore.defaultCalendarForNewReminders() else {
            throw ExportError.noDefaultList
        }

        let reminder = EKReminder(eventStore: eventStore)
        reminder.title = title
        reminder.notes = "From CatchMeUp · \(recapTitle)"
        reminder.calendar = calendar
        try eventStore.save(reminder, commit: true)
    }
}
