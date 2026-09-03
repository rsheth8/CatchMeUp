import Foundation

/// Thin wrapper over the app's iCloud Drive ubiquity container.
/// When the user isn't signed into iCloud (or on a build without the entitlement,
/// e.g. most Simulators) `containerURL` is nil and the app stays fully local.
enum CloudSync {
    static let containerID = "iCloud.com.catchmeup.app"

    static var isSignedIn: Bool {
        FileManager.default.ubiquityIdentityToken != nil
    }

    /// `<ubiquity>/Documents` — the folder Apple syncs across the user's devices.
    static var documentsURL: URL? {
        guard let base = FileManager.default.url(forUbiquityContainerIdentifier: nil) else { return nil }
        let docs = base.appendingPathComponent("Documents", isDirectory: true)
        try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        return docs
    }

    static var isAvailable: Bool { isSignedIn && documentsURL != nil }

    enum Status {
        case off
        case unavailable          // toggle on, but no iCloud account / entitlement
        case syncing
        case synced

        var text: String {
            switch self {
            case .off: return "Off — recaps stay on this iPhone."
            case .unavailable: return "Sign in to iCloud on this device to turn on sync."
            case .syncing: return "Syncing with iCloud…"
            case .synced: return "On — recaps sync across your devices."
            }
        }

        var symbolName: String {
            switch self {
            case .off: return "iphone"
            case .unavailable: return "exclamationmark.icloud"
            case .syncing: return "arrow.triangle.2.circlepath.icloud"
            case .synced: return "checkmark.icloud"
            }
        }

        var isProblem: Bool { if case .unavailable = self { return true } else { return false } }
    }

    /// What a finished migration actually did, in words the user can act on.
    struct Report: Equatable, Sendable {
        var moved: Int
        var skipped: Int
        var notDownloaded: Int
        var failed: Int
        var bytes: Int64
        var toCloud: Bool

        init(_ report: CloudMigration.Report, toCloud: Bool) {
            moved = report.moved
            skipped = report.skipped
            notDownloaded = report.notDownloaded
            failed = report.failed
            bytes = report.bytes
            self.toCloud = toCloud
        }

        var isProblem: Bool { failed > 0 }

        var summary: String {
            var sentences: [String] = []
            if moved > 0 {
                let where_ = toCloud ? "to iCloud" : "to this iPhone"
                sentences.append("Moved \(moved) recording\(moved == 1 ? "" : "s") \(where_) (\(byteText(bytes))).")
            } else if skipped > 0 && failed == 0 {
                sentences.append("Everything was already in place.")
            } else if failed == 0 {
                sentences.append("Nothing needed moving.")
            }
            if notDownloaded > 0 {
                sentences.append("\(notDownloaded) recording\(notDownloaded == 1 ? " is" : "s are") still only in iCloud — they'll download when you play them.")
            }
            if failed > 0 {
                sentences.append("\(failed) couldn't be moved and were left where they are.")
            }
            return sentences.joined(separator: " ")
        }
    }
}
