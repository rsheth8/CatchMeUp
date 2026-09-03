import Foundation

enum FollowUpStatus: String, Codable, CaseIterable, Identifiable {
    case open, inProgress, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In progress"
        case .done: return "Done"
        }
    }
}

struct MeetingFollowUp: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var owner = ""
    var deadlineText = ""
    /// Only a person chooses a calendar date; vague spoken deadlines stay text.
    var dueDate: Date?
    var status: FollowUpStatus = .open
    var timestamp = ""
    var evidence = ""
    var needsReview = true
    var reminderID: String?
    var editedByUser = false

    var seconds: Double? { Bookmark(timestamp: timestamp, heading: "", insight: "").seconds }
    var key: String { MeetingWorkspace.taskKey(title: title, owner: owner) }
}

enum MeetingOutcomeKind: String, Codable, CaseIterable, Identifiable {
    case decision, proposal, blocker, question
    var id: String { rawValue }
    var title: String {
        switch self {
        case .decision: return "Decision"
        case .proposal: return "Proposal"
        case .blocker: return "Blocker"
        case .question: return "Open question"
        }
    }
    var symbol: String {
        switch self {
        case .decision: return "checkmark.seal"
        case .proposal: return "lightbulb"
        case .blocker: return "exclamationmark.triangle"
        case .question: return "questionmark.bubble"
        }
    }
}

struct MeetingOutcome: Codable, Hashable, Identifiable {
    var id = UUID()
    var kind: MeetingOutcomeKind
    var text: String
    var timestamp = ""
    var evidence = ""
    var reviewed = false
    var resolved = false
    var seconds: Double? { Bookmark(timestamp: timestamp, heading: "", insight: "").seconds }
}

struct MeetingDocumentNote: Codable, Hashable, Identifiable {
    var id: String { "\(materialID)-\(pageNumber)-\(summary)" }
    var materialID: UUID
    var pageNumber: Int
    var summary: String
}

struct MeetingWorkspace: Codable, Hashable {
    var agenda = ""
    var followUps: [MeetingFollowUp] = []
    var outcomes: [MeetingOutcome] = []
    var documentNotes: [MeetingDocumentNote] = []
    var analyzedAt: Date?
    var analysisNotice: String?

    static func key(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func taskKey(title: String, owner: String) -> String { key(title) + "|" + key(owner) }

    /// A read-only migration until the first edit. Existing completion checks
    /// are preserved and IDs are persisted when the workspace is first saved.
    static func existing(for recording: Recording) -> Self {
        if let meeting = recording.meeting { return meeting }
        var workspace = Self()
        workspace.followUps = (recording.recap?.actionItems ?? []).enumerated().map { index, text in
            var item = MeetingFollowUp(title: text)
            item.status = recording.completedActions.contains(index) ? .done : .open
            item.editedByUser = recording.completedActions.contains(index)
            return item
        }
        return workspace
    }

    /// Match exact normalized task text, never fuzzy-merge different promises.
    /// Retain edits, completion, calendar dates and reminder links on refresh.
    mutating func merge(_ extraction: MeetingExtraction, transcript: String,
                        materials: [SupplementalMaterial]) {
        let source = Self.key(transcript)
        for draft in extraction.actions {
            guard !draft.task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !Self.key(draft.evidence).isEmpty, source.contains(Self.key(draft.evidence)) else { continue }
            if followUps.contains(where: {
                $0.key == Self.taskKey(title: draft.task, owner: draft.owner)
                    || ($0.editedByUser && !$0.evidence.isEmpty && Self.key($0.evidence) == Self.key(draft.evidence))
            }) { continue }
            var item = MeetingFollowUp(title: draft.task)
            item.owner = draft.owner
            item.deadlineText = draft.deadline
            item.timestamp = Self.validTimestamp(draft.timestamp, evidence: draft.evidence, in: transcript)
            item.evidence = draft.evidence
            followUps.append(item)
        }
        for draft in extraction.outcomes {
            guard let kind = MeetingOutcomeKind(rawValue: draft.kind),
                  !draft.text.isEmpty, !Self.key(draft.evidence).isEmpty,
                  source.contains(Self.key(draft.evidence)),
                  !outcomes.contains(where: { $0.kind == kind && Self.key($0.text) == Self.key(draft.text) })
            else { continue }
            outcomes.append(MeetingOutcome(kind: kind, text: draft.text,
                                           timestamp: Self.validTimestamp(draft.timestamp, evidence: draft.evidence, in: transcript),
                                           evidence: draft.evidence))
        }
        for draft in extraction.context {
            guard let id = UUID(uuidString: draft.materialID),
                  let material = materials.first(where: { $0.id == id }),
                  material.pages.contains(where: { $0.number == draft.page }),
                  !draft.summary.isEmpty else { continue }
            let note = MeetingDocumentNote(materialID: id, pageNumber: draft.page, summary: draft.summary)
            if !documentNotes.contains(note) { documentNotes.append(note) }
        }
    }

    private static func validTimestamp(_ stamp: String, evidence: String, in transcript: String) -> String {
        guard !stamp.isEmpty, transcript.components(separatedBy: "\n").contains(where: {
            $0.contains("[\(stamp)]") && Self.key($0).contains(Self.key(evidence))
        }) else { return "" }
        return stamp
    }

    mutating func preserveUserChanges(from latest: Self?) {
        guard let latest else { return }
        agenda = latest.agenda
        for item in latest.followUps where item.editedByUser || item.reminderID != nil || item.status == .done {
            if let i = followUps.firstIndex(where: { $0.id == item.id || $0.key == item.key }) {
                if item.editedByUser || item.reminderID != nil { followUps[i] = item }
            } else { followUps.append(item) }
        }
        for outcome in latest.outcomes where outcome.reviewed || outcome.resolved {
            if let i = outcomes.firstIndex(where: { $0.id == outcome.id || Self.key($0.text) == Self.key(outcome.text) }) {
                outcomes[i] = outcome
            } else { outcomes.append(outcome) }
        }
    }
}

/// Transport schema has no generated IDs, statuses or calendar dates. Those
/// belong to the local app and are never entrusted to a model.
struct MeetingExtraction: Codable {
    struct Action: Codable {
        var task: String
        var owner: String
        var deadline: String
        var timestamp: String
        var evidence: String
    }
    struct Outcome: Codable {
        var kind: String
        var text: String
        var timestamp: String
        var evidence: String
    }
    struct Context: Codable {
        var materialID: String
        var page: Int
        var summary: String
    }
    var actions: [Action]
    var outcomes: [Outcome]
    var context: [Context]
}

/// Recurring meetings are explicitly grouped by Brain; unrelated standalone
/// meetings must never be used as one another's history.
enum MeetingPreparation {
    static func previous(for recording: Recording, in recordings: [Recording]) -> [Recording] {
        guard let brainID = recording.brainID else { return [] }
        return recordings.filter {
            $0.id != recording.id && $0.brainID == brainID && $0.mode == .meeting
                && $0.createdAt < recording.createdAt && !$0.deleted
        }.sorted { $0.createdAt > $1.createdAt }
    }

    static func brief(for recording: Recording, in recordings: [Recording]) -> String {
        let previous = previous(for: recording, in: recordings)
        guard !previous.isEmpty else { return "No previous meetings in this Brain yet." }
        var lines: [String] = ["Preparation for \(recording.displayTitle)"]
        var seen = Set<String>()
        for rec in previous.prefix(8) {
            let workspace = MeetingWorkspace.existing(for: rec)
            for task in workspace.followUps where seen.insert(task.key).inserted {
                guard task.status != .done else { continue }
                lines.append("Follow up: \(task.title)\(task.owner.isEmpty ? "" : " — \(task.owner)") [\(rec.displayTitle)]")
            }
            for outcome in workspace.outcomes {
                let key = "\(outcome.kind.rawValue)-\(MeetingWorkspace.key(outcome.text))"
                if seen.insert(key).inserted {
                    guard !outcome.resolved else { continue }
                    lines.append("\(outcome.kind.title)\(outcome.reviewed ? "" : " (unreviewed)"): \(outcome.text) [\(rec.displayTitle)]")
                }
            }
        }
        return lines.count == 1 ? "Previous meetings have no tracked open items. Open their recaps to review the notes." : lines.prefix(22).joined(separator: "\n\n")
    }
}
