import Foundation
import UIKit

// MARK: - Diagnostics
//
// The block of text a beta report needs in front of it.
//
// A tester writes "it got stuck writing the notes" and that is genuinely all
// they should have to write; everything else — which engine, which build,
// whether iCloud was on, how big the library is — is the app's job to say. So
// this assembles it, and the Settings screen hands it over through the share
// sheet, where the tester picks who gets it.
//
// What it must never contain: recap titles, note text, transcripts, questions,
// the user's answers, or an API key. Those are the whole content of the app and
// none of them help diagnose a bug. Only shapes and counts leave here, and the
// tests below assert that.

struct Diagnostics {
    var appVersion: String
    var build: String
    var system: String
    var device: String
    var engine: String
    var provider: String?
    var syncEnabled: Bool
    var recordings: Int
    var brains: Int
    var unprocessed: Int
    var failed: Int
    var studyItems: Int
    var reviews: Int
    var prequestions: Bool
    var reminderHour: Int?

    @MainActor
    static func current(store: LibraryStore, study: StudyStore, settings: AppSettings) -> Diagnostics {
        let recs = store.sortedRecordings
        return Diagnostics(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—",
            system: "iOS \(UIDevice.current.systemVersion)",
            device: hardwareIdentifier(),
            engine: settings.engineKind.rawValue,
            // The provider's name, never the key. Which model wrote the notes
            // is often the answer; the credential never is.
            provider: settings.engineKind == .apiKey ? settings.providerID : nil,
            syncEnabled: store.syncEnabled,
            recordings: recs.count,
            brains: store.visibleBrains.count,
            unprocessed: recs.filter { !$0.isProcessed }.count,
            failed: recs.filter(\.needsAttention).count,
            studyItems: study.liveItems.count,
            reviews: study.logs.count,
            prequestions: settings.prequestions,
            reminderHour: settings.reviewReminder ? settings.reviewReminderHour : nil
        )
    }

    /// e.g. "iPhone17,1". More useful in a bug report than the marketing name,
    /// and it's what the crash logs will say.
    static func hardwareIdentifier() -> String {
        var info = utsname()
        uname(&info)
        let raw = withUnsafePointer(to: &info.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        return raw.isEmpty ? "unknown" : raw
    }

    /// The pasteable block. Deliberately plain text: it has to survive being
    /// dropped into a TestFlight feedback box, an email, or a chat message.
    var report: String {
        var lines = [
            "CatchMeUp \(appVersion) (\(build))",
            "\(system) · \(device)",
            "Engine: \(engine)\(provider.map { " · \($0)" } ?? "")",
            "iCloud sync: \(syncEnabled ? "on" : "off")",
            "Library: \(recordings) recaps · \(brains) brains",
        ]
        if unprocessed > 0 || failed > 0 {
            lines.append("Pending: \(unprocessed) unprocessed · \(failed) failed")
        }
        lines.append("Study: \(studyItems) questions · \(reviews) reviews")
        lines.append("Prequestions: \(prequestions ? "on" : "off")")
        lines.append("Reminder: \(reminderHour.map { "\($0):00" } ?? "off")")
        return lines.joined(separator: "\n")
    }

    /// What gets shared: a place for the tester to type, above the facts.
    var shareText: String {
        """
        What happened:


        What I expected:


        ---
        \(report)
        """
    }
}
