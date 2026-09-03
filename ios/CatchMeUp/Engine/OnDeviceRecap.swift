#if canImport(FoundationModels)
import FoundationModels
import Foundation

// Guided-generation mirrors of `Recap` for Apple's on-device model.
//
// The on-device path used to be handed the same "return only JSON" prompt as a
// hosted model, then parsed leniently with a retry when the reply came back
// with a code fence, a sentence of preamble or a missing brace — which a model
// this size does often. `@Generable` moves the shape from a request in the
// prompt to a constraint on decoding: there is no stray prose to strip and no
// malformed JSON to repair, because the schema doesn't permit either.
//
// The types are per mode and non-optional throughout. `Optional` isn't
// `Generable`, and asking for a lecture's speakers or a meeting's vocabulary
// would spend a small context window on fields the recap doesn't use.

// MARK: - Shared pieces

@available(iOS 26.0, *)
@Generable(description: "One moment in the recording worth jumping back to.")
struct GeneratedMoment {
    /// Constrained rather than requested. `Bookmark.seconds` parses this to
    /// place the moment on the audio, and a stamp the model formatted its own
    /// way silently became an unseekable bookmark.
    @Guide(description: "When it happens, as HH:MM:SS, copied from the transcript timestamps.",
           .pattern(/\d{1,2}:\d{2}:\d{2}/))
    var timestamp: String

    @Guide(description: "A short label for this moment, a few words at most.")
    var heading: String

    @Guide(description: "Why this moment matters, in plain terms. One or two sentences.")
    var insight: String
}

@available(iOS 26.0, *)
@Generable(description: "In-depth notes on one topic from the recording.")
struct GeneratedSection {
    @Guide(description: "The topic this section covers.")
    var heading: String

    @Guide(description: "Several sentences teaching this topic to someone who was not there.")
    var content: String
}

// MARK: - Meeting

@available(iOS 26.0, *)
@Generable(description: "One person heard speaking in the meeting.")
struct GeneratedSpeaker {
    @Guide(description: "The transcript's label for them, such as \"Speaker 1\".")
    var label: String

    @Guide(description: "Their name only if it is actually used out loud. Otherwise an empty string.")
    var name: String

    @Guide(description: "Their role in this meeting, in one line.")
    var said: String
}

@available(iOS 26.0, *)
@Generable(description: "Notes on a work meeting, for someone who did not attend.")
struct GeneratedMeetingRecap {
    @Guide(description: "A short descriptive title for the meeting.")
    var title: String

    @Guide(description: "The decisions and outcomes someone who missed this must know.", .count(2...8))
    var tldr: [String]

    @Guide(description: "Every follow-up you can hear, each naming who owns it and any deadline mentioned.",
           .maximumCount(10))
    var actionItems: [String]

    @Guide(description: "The people heard speaking. Never invent a name.", .maximumCount(8))
    var speakers: [GeneratedSpeaker]

    @Guide(description: "Decision and action-item moments, spread across this part of the meeting.",
           .count(2...6))
    var bookmarks: [GeneratedMoment]

    @Guide(description: "In-depth notes, one section per topic discussed.", .count(1...6))
    var detailedNotes: [GeneratedSection]
}

// MARK: - Lecture

@available(iOS 26.0, *)
@Generable
struct GeneratedFollowUp {
    var task: String
    @Guide(description: "Named owner only if stated. Otherwise empty.") var owner: String
    @Guide(description: "Deadline exactly as spoken, otherwise empty.") var deadline: String
    @Guide(description: "Exact HH:MM:SS copied from a transcript timestamp.") var timestamp: String
    @Guide(description: "A short verbatim transcript quote supporting this task.") var evidence: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedOutcome {
    @Guide(description: "Exactly one of: decision, proposal, blocker, question. Agreement is required for decision.")
    var kind: String
    var text: String
    var timestamp: String
    @Guide(description: "A short verbatim transcript quote supporting this outcome.") var evidence: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedDocumentContext {
    @Guide(description: "The exact materialID UUID supplied in a document label.") var materialID: String
    var page: Int
    @Guide(description: "Relevant document context, never a claim that this was said aloud.") var summary: String
}

@available(iOS 26.0, *)
@Generable
struct GeneratedMeetingAnalysis {
    @Guide(.maximumCount(6)) var actions: [GeneratedFollowUp]
    @Guide(.maximumCount(6)) var outcomes: [GeneratedOutcome]
    @Guide(.maximumCount(2)) var context: [GeneratedDocumentContext]

    var extraction: MeetingExtraction {
        MeetingExtraction(actions: actions.map {
            .init(task: $0.task, owner: $0.owner, deadline: $0.deadline, timestamp: $0.timestamp, evidence: $0.evidence)
        }, outcomes: outcomes.map {
            .init(kind: $0.kind, text: $0.text, timestamp: $0.timestamp, evidence: $0.evidence)
        }, context: context.map {
            .init(materialID: $0.materialID, page: $0.page, summary: $0.summary)
        })
    }
}

@available(iOS 26.0, *)
@Generable(description: "A term, formula or name worth remembering, with its meaning.")
struct GeneratedTerm {
    @Guide(description: "The term, formula or name.")
    var term: String

    @Guide(description: "A plain-language definition.")
    var definition: String
}

@available(iOS 26.0, *)
@Generable(description: "Notes on a recorded lecture, for a student who missed it.")
struct GeneratedLectureRecap {
    @Guide(description: "A short lecture title, including the course and topic if you can tell.")
    var title: String

    @Guide(description: "The things a student who missed this must know.", .count(2...8))
    var tldr: [String]

    @Guide(description: "Definitions, worked examples, and anything flagged as exam material.",
           .count(2...6))
    var bookmarks: [GeneratedMoment]

    @Guide(description: "In-depth notes, one section per topic. Teach rather than quote.",
           .count(1...6))
    var detailedNotes: [GeneratedSection]

    @Guide(description: "Vocabulary, formulas and names introduced here.", .maximumCount(12))
    var terms: [GeneratedTerm]

    @Guide(description: "Exam-style prompts, or things to memorise and practise.", .maximumCount(8))
    var study: [String]
}

// MARK: - Conversion

@available(iOS 26.0, *)
extension GeneratedMeetingRecap {
    var recap: Recap {
        var out = Recap()
        out.title = OnDeviceRecap.text(title)
        out.tldr = OnDeviceRecap.list(tldr)
        out.actionItems = OnDeviceRecap.list(actionItems)
        out.speakers = OnDeviceRecap.list(speakers.map(\.speakerNote)) { !$0.label.isEmpty || !$0.name.isEmpty }
        out.bookmarks = OnDeviceRecap.list(bookmarks.map(\.bookmark)) { !$0.heading.isEmpty }
        out.detailedNotes = OnDeviceRecap.list(detailedNotes.map(\.note)) { !$0.content.isEmpty }
        return out
    }
}

@available(iOS 26.0, *)
extension GeneratedLectureRecap {
    var recap: Recap {
        var out = Recap()
        out.title = OnDeviceRecap.text(title)
        out.tldr = OnDeviceRecap.list(tldr)
        out.bookmarks = OnDeviceRecap.list(bookmarks.map(\.bookmark)) { !$0.heading.isEmpty }
        out.detailedNotes = OnDeviceRecap.list(detailedNotes.map(\.note)) { !$0.content.isEmpty }
        out.terms = OnDeviceRecap.list(terms.map(\.term_)) { !$0.term.isEmpty && !$0.definition.isEmpty }
        out.study = OnDeviceRecap.list(study)
        return out
    }
}

@available(iOS 26.0, *)
extension GeneratedMoment {
    var bookmark: Bookmark {
        Bookmark(timestamp: OnDeviceRecap.stamp(timestamp),
                 heading: heading.trimmed,
                 insight: insight.trimmed)
    }
}

@available(iOS 26.0, *)
extension GeneratedSection {
    var note: DetailNote {
        DetailNote(heading: heading.trimmed, content: content.trimmed)
    }
}

@available(iOS 26.0, *)
extension GeneratedSpeaker {
    var speakerNote: SpeakerNote {
        SpeakerNote(label: label.trimmed, name: name.trimmed, said: said.trimmed)
    }
}

@available(iOS 26.0, *)
extension GeneratedTerm {
    /// Named with a trailing underscore because `term.term` reads worse than
    /// the stored property it shadows would.
    var term_: Term {
        Term(term: term.trimmed, definition: definition.trimmed)
    }
}

/// The rules every generated recap goes through on its way to `Recap`.
///
/// A guided model still fills a required field with something when it has
/// nothing to say — usually an empty string or a placeholder. Empty sections
/// have to arrive as `nil`, because the recap screen hides a missing section
/// and renders an empty one as a heading with nothing under it.
enum OnDeviceRecap {
    static func text(_ value: String) -> String? {
        let trimmed = value.trimmed
        return trimmed.isEmpty ? nil : trimmed
    }

    static func list(_ values: [String]) -> [String]? {
        let cleaned = values.map(\.trimmed).filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    static func list<T>(_ values: [T], keeping isUsable: (T) -> Bool) -> [T]? {
        let cleaned = values.filter(isUsable)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Normalises to `HH:MM:SS`. The pattern guide allows a single-digit hour,
    /// and a model transcribing a short recording tends to give `MM:SS`.
    static func stamp(_ raw: String) -> String {
        let parts = raw.trimmed.split(separator: ":").map(String.init)
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count, !numbers.isEmpty else { return raw.trimmed }

        let (h, m, s): (Int, Int, Int)
        switch numbers.count {
        case 2: (h, m, s) = (0, numbers[0], numbers[1])
        case 3: (h, m, s) = (numbers[0], numbers[1], numbers[2])
        default: return raw.trimmed
        }
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
#endif
