import AppIntents

struct RecordMeetingIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Meeting"
    static let description = IntentDescription("Open CatchMeUp ready to record a meeting.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingRouteStore.save(CatchMeUpLink.record(.meeting))
        return .result()
    }
}

struct RecordLectureIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a Lecture"
    static let description = IntentDescription("Open CatchMeUp ready to record a lecture.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        PendingRouteStore.save(CatchMeUpLink.record(.lecture))
        return .result()
    }
}

struct SearchRecapsIntent: AppIntent {
    static let title: LocalizedStringResource = "Search Recaps"
    static let description = IntentDescription("Search your meeting and lecture notes in CatchMeUp.")
    static let openAppWhenRun = true

    @Parameter(title: "Search")
    var query: String

    func perform() async throws -> some IntentResult {
        PendingRouteStore.save(CatchMeUpLink.search(query))
        return .result()
    }
}

struct CatchMeUpShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordMeetingIntent(),
            phrases: ["Record a meeting with \(.applicationName)"],
            shortTitle: "Record Meeting",
            systemImageName: "person.2.wave.2"
        )
        AppShortcut(
            intent: RecordLectureIntent(),
            phrases: ["Record a lecture with \(.applicationName)"],
            shortTitle: "Record Lecture",
            systemImageName: "graduationcap"
        )
        AppShortcut(
            intent: SearchRecapsIntent(),
            phrases: ["Search my \(.applicationName) recaps"],
            shortTitle: "Search Recaps",
            systemImageName: "magnifyingglass"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .teal }
}
