import CoreSpotlight
import EventKit
import Foundation
import Observation
import UniformTypeIdentifiers
import UIKit

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
    enum ExportError: LocalizedError {
        case accessDenied
        case noDefaultList

        var errorDescription: String? {
            switch self {
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
