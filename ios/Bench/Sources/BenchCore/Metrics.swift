import Foundation

// Mechanical checks on a recap. None of these need a judge model, so they are
// cheap, repeatable and not biased toward any vendor's writing style.
//
// They measure whether a recap is trustworthy and usable by the app, not
// whether it is well written; the judge covers that.

struct RecapMetrics: Codable, Equatable {
    // Bookmarks: each one has to put the player in the right place.
    var bookmarks = 0
    /// `Bookmark.seconds` can parse the timestamp at all.
    var bookmarksSeekable = 0
    /// Parseable, inside the recording, and within 60s of a real transcript line.
    var bookmarksGrounded = 0

    // Invented people.
    var namedSpeakers = 0
    var inventedSpeakerNames: [String] = []
    var forbiddenNameHits: [String] = []
    /// A real name given to more than one speaker label. The name is in the
    /// transcript, so it isn't "invented", but at least one attribution is wrong.
    var speakerNameClashes: [String] = []

    // Invented figures: numbers in the notes that never appear in the transcript.
    var numbersChecked = 0
    var numbersUnsupported = 0
    var unsupportedNumbers: [String] = []

    // Answer key.
    var factsTotal = 0
    var factsFound = 0
    var missingFacts: [String] = []

    // Shape.
    var tldr = 0
    var detailedNotes = 0
    var actionItems = 0
    var terms = 0
    var words = 0
    /// No summary and no notes at all. The recap screen would show nothing useful.
    var emptyCore = false

    var seekableRate: Double? { bookmarks == 0 ? nil : Double(bookmarksSeekable) / Double(bookmarks) }
    var groundedRate: Double? { bookmarks == 0 ? nil : Double(bookmarksGrounded) / Double(bookmarks) }
    var unsupportedNumberRate: Double? { numbersChecked == 0 ? nil : Double(numbersUnsupported) / Double(numbersChecked) }
    var factCoverage: Double? { factsTotal == 0 ? nil : Double(factsFound) / Double(factsTotal) }
}

enum RecapAnalysis {

    // MARK: Entry point

    static func metrics(for recap: Recap, item: CorpusItem) -> RecapMetrics {
        var m = RecapMetrics()
        let transcript = item.transcript
        let text = plainText(recap)

        // Bookmarks.
        let stamps = Transcript.stamps(in: transcript)
        let end = stamps.last ?? 0
        for bookmark in recap.bookmarks ?? [] {
            m.bookmarks += 1
            guard let seconds = bookmark.seconds else { continue }
            m.bookmarksSeekable += 1
            let nearest = stamps.map { abs($0 - seconds) }.min() ?? .infinity
            if seconds >= 0, seconds <= end + 60, nearest <= 60 { m.bookmarksGrounded += 1 }
        }

        // Speakers: a name only counts if it is actually spoken.
        let lowered = transcript.lowercased()
        for speaker in recap.speakers ?? [] {
            let name = speaker.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.lowercased() != speaker.label.lowercased() else { continue }
            m.namedSpeakers += 1
            if !lowered.contains(name.lowercased()) { m.inventedSpeakerNames.append(name) }
        }
        var labelsByName: [String: Set<String>] = [:]
        for speaker in recap.speakers ?? [] {
            let name = speaker.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !name.isEmpty, name != speaker.label.lowercased() else { continue }
            labelsByName[name, default: []].insert(speaker.label.lowercased())
        }
        m.speakerNameClashes = labelsByName.filter { $0.value.count > 1 }.keys.sorted()
        m.forbiddenNameHits = item.gold.forbiddenNames.filter { containsWord(text, $0) }

        // Numbers.
        let supported = Set(numbers(in: transcript, filterSmall: false))
        let claimed = numbers(in: stripTimestamps(text), filterSmall: true)
        m.numbersChecked = claimed.count
        m.unsupportedNumbers = claimed.filter { !supported.contains($0) }
        m.numbersUnsupported = m.unsupportedNumbers.count

        // Answer key.
        let recapKey = normalize(text)
        m.factsTotal = item.gold.facts.count
        for fact in item.gold.facts {
            if fact.anyOf.contains(where: { recapKey.contains(normalize($0)) && !normalize($0).isEmpty }) {
                m.factsFound += 1
            } else {
                m.missingFacts.append(fact.id)
            }
        }

        // Shape.
        m.tldr = (recap.tldr ?? []).count
        m.detailedNotes = (recap.detailedNotes ?? []).count
        m.actionItems = (recap.actionItems ?? []).count
        m.terms = (recap.terms ?? []).count
        m.words = text.split(whereSeparator: \.isWhitespace).count
        m.emptyCore = (recap.tldr ?? []).isEmpty && (recap.detailedNotes ?? []).isEmpty
        return m
    }

    // MARK: Text helpers

    /// Every string in the recap, for matching against.
    static func plainText(_ recap: Recap) -> String {
        var parts: [String] = []
        if let title = recap.title { parts.append(title) }
        parts += recap.tldr ?? []
        parts += recap.actionItems ?? []
        for s in recap.speakers ?? [] { parts += [s.label, s.name, s.said] }
        for b in recap.bookmarks ?? [] { parts += [b.timestamp, b.heading, b.insight] }
        for n in recap.detailedNotes ?? [] { parts += [n.heading, n.content] }
        for t in recap.terms ?? [] { parts += [t.term, t.definition] }
        parts += recap.study ?? []
        return parts.joined(separator: "\n")
    }

    /// The recap as readable Markdown. This is what a judge sees, identically
    /// for every engine, so layout can't reveal which model wrote it.
    static func markdown(_ recap: Recap) -> String {
        var out: [String] = []
        if let title = recap.title, !title.isEmpty { out.append("# \(title)") }
        func list(_ heading: String, _ items: [String]?) {
            guard let items, !items.isEmpty else { return }
            out.append("## \(heading)\n" + items.map { "- \($0)" }.joined(separator: "\n"))
        }
        list("Summary", recap.tldr)
        list("Action items", recap.actionItems)
        if let speakers = recap.speakers, !speakers.isEmpty {
            out.append("## Speakers\n" + speakers.map {
                "- \($0.label)\($0.name.isEmpty ? "" : " (\($0.name))"): \($0.said)"
            }.joined(separator: "\n"))
        }
        if let bookmarks = recap.bookmarks, !bookmarks.isEmpty {
            out.append("## Key moments\n" + bookmarks.map {
                "- [\($0.timestamp)] \($0.heading): \($0.insight)"
            }.joined(separator: "\n"))
        }
        if let notes = recap.detailedNotes, !notes.isEmpty {
            out.append("## Detailed notes\n" + notes.map { "### \($0.heading)\n\($0.content)" }.joined(separator: "\n\n"))
        }
        if let terms = recap.terms, !terms.isEmpty {
            out.append("## Terms\n" + terms.map { "- **\($0.term)**: \($0.definition)" }.joined(separator: "\n"))
        }
        list("Study", recap.study)
        return out.joined(separator: "\n\n")
    }

    /// Lowercase letters and digits only, so "Env. diagram's" matches "env diagrams".
    static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    static func containsWord(_ text: String, _ word: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b"
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static let timestampPattern = try! NSRegularExpression(pattern: #"\[?\b\d{1,2}:\d{2}(?::\d{2})?\b\]?"#)
    private static let numberPattern = try! NSRegularExpression(pattern: #"\d[\d,]*(?:\.\d+)?"#)

    static func stripTimestamps(_ text: String) -> String {
        timestampPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " "
        )
    }

    /// Number tokens with thousands separators removed. With `filterSmall`, a
    /// lone digit is ignored: "two options" and "step 3" are overwhelmingly
    /// list scaffolding, and counting them would punish ordinary note-taking.
    static func numbers(in text: String, filterSmall: Bool) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return numberPattern.matches(in: text, range: range).compactMap { match in
            guard let r = Range(match.range, in: text) else { return nil }
            var token = String(text[r]).replacingOccurrences(of: ",", with: "")
            while token.hasSuffix(".") { token.removeLast() }
            if filterSmall, token.count < 2, !token.contains(".") { return nil }
            return token
        }
    }
}
