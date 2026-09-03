import Foundation

/// Cheap lexical vote over a transcript. Used as a prior for on-device dual
/// generation and nowhere in the UI — a score the user never asked for.
enum RecapSignals {
    struct Verdict: Equatable {
        /// Which job to lead with. The recording's stored `mode` still owns the
        /// accent and section order until the user restyles.
        var dominant: Mode
        /// Both jobs have real signal, so the on-device path should run both
        /// guided schemas rather than hoping one type grows the other's fields.
        var mixed: Bool
    }

    private static let lectureCues = [
        "exam", "quiz", "midterm", "homework", "professor", "lecture",
        "definition", "theorem", "formula", "this is called", "for example",
        "chapter", "slides", "recitation", "office hours", "problem set",
        "student", "course", "lab section"
    ]

    private static let meetingCues = [
        "standup", "action item", "follow-up", "follow up", "deadline",
        "i'll take", "i will take", "we decided", "we should", "next steps",
        "owner", "agenda", "retro", "sprint", "by friday", "by monday",
        "assigned", "takeaway", "sync", "blockers", "ship"
    ]

    static func classify(_ transcript: String, prior: Mode) -> Verdict {
        let text = transcript.lowercased()
        let lecture = score(text, cues: lectureCues)
        let meeting = score(text, cues: meetingCues)

        let mixed = lecture >= 2 && meeting >= 2
        let dominant: Mode
        if lecture >= meeting * 3 / 2 && lecture >= 2 && lecture > meeting {
            dominant = .lecture
        } else if meeting >= lecture * 3 / 2 && meeting >= 2 && meeting > lecture {
            dominant = .meeting
        } else {
            dominant = prior
        }
        return Verdict(dominant: dominant, mixed: mixed)
    }

    private static func score(_ text: String, cues: [String]) -> Int {
        cues.reduce(0) { $0 + (text.contains($1) ? 1 : 0) }
    }
}

/// Labels and “also in this recording” summaries. Kept out of the views so
/// markdown export and the recap screen stay in agreement, and so tests can
/// check visibility without standing up SwiftUI.
enum RecapLayout {
    static func gistTitle(for mode: Mode) -> String {
        mode == .meeting ? "The gist" : "What you missed"
    }

    static func bookmarksTitle(for mode: Mode) -> String {
        mode == .meeting ? "Jump back in" : "Key moments"
    }

    static func notesTitle(for mode: Mode) -> String {
        mode == .meeting ? "Detailed notes" : "Notes by topic"
    }

    /// One line for the disclosure row. Nil means don't show it.
    static func alsoSummary(_ recap: Recap, dominant: Mode) -> String? {
        switch dominant {
        case .lecture:
            var bits: [String] = []
            if let n = recap.actionItems?.count, n > 0 {
                bits.append("\(n) follow-up\(n == 1 ? "" : "s")")
            }
            if let n = recap.speakers?.count, n > 0 {
                bits.append("who was there")
            }
            return bits.isEmpty ? nil : bits.joined(separator: " · ")
        case .meeting:
            var bits: [String] = []
            if let n = recap.terms?.count, n > 0 {
                bits.append("Glossary · \(n) term\(n == 1 ? "" : "s")")
            }
            if let n = recap.study?.count, n > 0 {
                bits.append("\(n) to study")
            }
            return bits.isEmpty ? nil : bits.joined(separator: " · ")
        }
    }
}

/// Open commitments and study bullets from the last week, for a header that
/// only exists when it has something to tap.
enum WeekPulse {
    struct Line: Identifiable, Equatable {
        var id: UUID
        var recordingID: UUID
        var text: String
        var symbol: String
    }

    static func lines(from recordings: [Recording], now: Date = .now, limit: Int = 2) -> [Line] {
        let weekAgo = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        let recent = recordings.filter { $0.createdAt >= weekAgo && $0.recap != nil }

        var out: [Line] = []
        for rec in recent {
            guard let items = rec.recap?.actionItems, !items.isEmpty else { continue }
            if let (idx, item) = items.enumerated().first(where: { !rec.completedActions.contains($0.offset) }) {
                out.append(Line(id: rec.id, recordingID: rec.id,
                                text: item, symbol: "checklist"))
                _ = idx
            }
            if out.count >= limit { return out }
        }
        if out.count < limit {
            for rec in recent {
                guard let study = rec.recap?.study, let first = study.first else { continue }
                if out.contains(where: { $0.recordingID == rec.id }) { continue }
                out.append(Line(id: rec.id, recordingID: rec.id,
                                text: first, symbol: "checkmark.circle"))
                if out.count >= limit { break }
            }
        }
        return Array(out.prefix(limit))
    }
}
