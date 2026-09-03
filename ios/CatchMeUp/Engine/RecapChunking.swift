import Foundation

// A transcript longer than the model's window used to be handled by
// `transcript.prefix(9000)`, which quietly threw away everything after roughly
// the first ten minutes of a lecture and said nothing about it. Instead the
// transcript is cut on segment boundaries, each piece gets its own pass, and
// the partial recaps are merged here.

// MARK: - Splitting

enum TranscriptChunker {
    /// Splits on `[HH:MM:SS]` line boundaries so no timestamp is ever cut in
    /// half. A couple of lines of overlap carry sentence context across the
    /// seam, which stops a worked example from losing its setup.
    static func chunks(_ transcript: String, maxCharacters: Int, overlapLines: Int = 2) -> [String] {
        guard maxCharacters > 0, transcript.count > maxCharacters else {
            return transcript.isEmpty ? [] : [transcript]
        }

        let lines = transcript.components(separatedBy: "\n")
        var chunks: [String] = []
        var current: [String] = []
        var length = 0

        for line in lines {
            // A single line longer than the whole budget can't be helped by
            // splitting further; give it its own chunk rather than looping.
            if length + line.count + 1 > maxCharacters, !current.isEmpty {
                chunks.append(current.joined(separator: "\n"))
                // Carrying context forward is only worth it while the carry
                // stays small. Long segments could otherwise make every chunk
                // mostly a repeat of the last one.
                let carried = Array(current.suffix(overlapLines))
                let carriedLength = carried.reduce(0) { $0 + $1.count + 1 }
                if carriedLength <= maxCharacters / 3 {
                    current = carried
                    length = carriedLength
                } else {
                    current = []
                    length = 0
                }
            }
            current.append(line)
            length += line.count + 1
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n")) }
        return chunks
    }
}

// MARK: - Merging

enum RecapMerge {
    /// Caps exist so a three-hour recording doesn't produce a hundred bullets
    /// nobody will read. They're generous enough that a normal lecture is never
    /// clipped.
    private enum Cap {
        static let tldr = 12
        static let actionItems = 30
        static let bookmarks = 24
        static let detailedNotes = 30
        static let terms = 50
        static let study = 18
        static let speakers = 12
    }

    static func combine(_ parts: [Recap]) -> Recap {
        guard parts.count > 1 else { return parts.first ?? Recap() }

        var out = Recap()
        out.title = parts.compactMap(\.title).first { !$0.isEmpty }
        out.tldr = dedupe(parts.flatMap { $0.tldr ?? [] }, cap: Cap.tldr) { $0 }
        out.actionItems = dedupe(parts.flatMap { $0.actionItems ?? [] }, cap: Cap.actionItems) { $0 }
        out.study = dedupe(parts.flatMap { $0.study ?? [] }, cap: Cap.study) { $0 }
        out.terms = dedupe(parts.flatMap { $0.terms ?? [] }, cap: Cap.terms) { $0.term }
        out.speakers = mergeSpeakers(parts.flatMap { $0.speakers ?? [] })
        out.detailedNotes = mergeNotes(parts.flatMap { $0.detailedNotes ?? [] })

        // Bookmarks are the one list with a natural order, and the chunks
        // arrive in order anyway — but a model that guesses a timestamp can
        // still put one out of place.
        let bookmarks = dedupe(parts.flatMap { $0.bookmarks ?? [] }, cap: Cap.bookmarks) { $0.heading }
        out.bookmarks = bookmarks?.sorted { ($0.seconds ?? 0) < ($1.seconds ?? 0) }

        return out
    }

    /// Keeps the first of each key and drops empties. Nil rather than `[]` when
    /// nothing survives, because the UI hides missing sections and shows empty
    /// ones as a heading with nothing under it.
    private static func dedupe<T>(_ items: [T], cap: Int, key: (T) -> String) -> [T]? {
        var seen = Set<String>()
        var out: [T] = []
        for item in items {
            let k = normalized(key(item))
            guard !k.isEmpty, seen.insert(k).inserted else { continue }
            out.append(item)
            if out.count >= cap { break }
        }
        return out.isEmpty ? nil : out
    }

    /// Two chunks covering the same topic get one section, not two identical
    /// headings a paragraph apart.
    private static func mergeNotes(_ notes: [DetailNote]) -> [DetailNote]? {
        var order: [String] = []
        var byHeading: [String: DetailNote] = [:]

        for note in notes {
            let key = normalized(note.heading)
            guard !key.isEmpty || !note.content.isEmpty else { continue }
            if var existing = byHeading[key] {
                if !normalized(existing.content).contains(normalized(note.content)) {
                    existing.content += "\n\n" + note.content
                    byHeading[key] = existing
                }
            } else {
                byHeading[key] = note
                order.append(key)
            }
        }

        let merged = order.prefix(Cap.detailedNotes).compactMap { byHeading[$0] }
        return merged.isEmpty ? nil : Array(merged)
    }

    /// A speaker introduced by name halfway through should keep that name for
    /// the whole recap, not only the chunk it was heard in.
    private static func mergeSpeakers(_ speakers: [SpeakerNote]) -> [SpeakerNote]? {
        var order: [String] = []
        var byLabel: [String: SpeakerNote] = [:]

        for speaker in speakers {
            let key = normalized(speaker.label.isEmpty ? speaker.name : speaker.label)
            guard !key.isEmpty else { continue }
            if var existing = byLabel[key] {
                if existing.name.isEmpty, !speaker.name.isEmpty { existing.name = speaker.name }
                if existing.said.isEmpty { existing.said = speaker.said }
                byLabel[key] = existing
            } else {
                byLabel[key] = speaker
                order.append(key)
            }
        }

        let merged = order.prefix(Cap.speakers).compactMap { byLabel[$0] }
        return merged.isEmpty ? nil : Array(merged)
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}

// MARK: - Budgets

/// How much transcript one request can carry.
struct RecapBudget {
    let charactersPerRequest: Int

    /// Apple's on-device model has roughly a 4k-token window shared between the
    /// prompt and the answer, and the schema alone costs a few hundred. 5,000
    /// characters of transcript is about as much as fits with room to write
    /// something useful back.
    static let onDevice = RecapBudget(charactersPerRequest: 5_000)

    /// Hosted models could take far more in one go, but a smaller window buys
    /// noticeably more detail per section and keeps the reply clear of the
    /// `max_tokens` ceiling.
    static let cloud = RecapBudget(charactersPerRequest: 60_000)

    /// Context handed to an ask, which has to leave room for the answer too.
    static let onDeviceContext = 6_000
    static let cloudContext = 40_000
}
