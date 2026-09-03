import Foundation

// Asking a brain a question used to hand the model `recs.prefix(12)` — the
// twelve most recent recaps in the brain, regardless of what was asked, cut off
// mid-sentence at a character count. A brain with thirty lectures in it meant
// eighteen the model never saw.
//
// This scores every passage in the brain against the question and spends the
// context budget on the ones that actually look like an answer. Transcripts are
// in scope too, so "what exactly did he say about X" has somewhere to land.

struct RetrievedContext: Sendable {
    let text: String
    /// Recaps that contributed at least one passage — the only titles the model
    /// is allowed to cite.
    let recaps: [Recording]
    /// How many recaps were searched, so the UI can be honest about coverage.
    let searchedCount: Int
    /// True when the budget stopped us short of everything that matched.
    let clipped: Bool

    var isEmpty: Bool { text.isEmpty }
}

enum BrainRetriever {

    // MARK: Entry point

    static func context(
        for question: String,
        recaps: [Recording],
        budget: Int
    ) -> RetrievedContext {
        let searchable = recaps.filter { $0.recap != nil || !$0.segments.isEmpty }
        guard !searchable.isEmpty else {
            return RetrievedContext(text: "", recaps: [], searchedCount: 0, clipped: false)
        }

        let passages = searchable.flatMap { self.passages(for: $0) }
        guard !passages.isEmpty else {
            return RetrievedContext(text: "", recaps: [], searchedCount: searchable.count, clipped: false)
        }

        let terms = tokens(in: question)
        let ranked = terms.isEmpty
            ? passages                                  // no usable question: keep the natural order
            : rank(passages, against: terms)

        let selection = select(ranked, from: searchable, budget: budget, hasQuery: !terms.isEmpty)
        return render(selection, searchedCount: searchable.count)
    }

    // MARK: Passages

    private struct Passage {
        enum Kind: Int {
            case gist, note, term, moment, action, said

            /// Curated text answers a question more cleanly than raw speech, so
            /// notes outrank transcript at equal relevance. Transcript still
            /// wins outright when it's the only place a term appears.
            var weight: Double {
                switch self {
                case .gist: return 1.35
                case .note: return 1.25
                case .term: return 1.2
                case .action: return 1.15
                case .moment: return 1.1
                case .said: return 0.85
                }
            }
        }

        let recordingID: UUID
        let kind: Kind
        let label: String
        let body: String
        /// Position within its recap, used to keep rendering in reading order.
        let order: Int
        var score: Double = 0

        var rendered: String { label.isEmpty ? body : "\(label): \(body)" }
        var cost: Int { rendered.count + 1 }
    }

    /// Roughly a paragraph. Small enough to be precise, big enough that a
    /// definition and its example stay together.
    private static let transcriptWindow = 700
    /// A brain can hold many hours of speech; there's no point scoring all of
    /// it when the budget will only ever fit a few dozen passages.
    private static let maxPassages = 6_000

    private static func passages(for recording: Recording) -> [Passage] {
        var out: [Passage] = []
        var order = 0

        func add(_ kind: Passage.Kind, _ label: String, _ body: String) {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            out.append(Passage(recordingID: recording.id, kind: kind,
                               label: label, body: trimmed, order: order))
            order += 1
        }

        if let recap = recording.recap {
            if let tldr = recap.tldr, !tldr.isEmpty {
                add(.gist, "Gist", tldr.map { "- \($0)" }.joined(separator: "\n"))
            }
            for note in recap.detailedNotes ?? [] {
                add(.note, "Notes — \(note.heading)", note.content)
            }
            for term in recap.terms ?? [] {
                add(.term, "Term — \(term.term)", term.definition)
            }
            for item in recap.actionItems ?? [] {
                add(.action, "Follow-up", item)
            }
            for mark in recap.bookmarks ?? [] {
                add(.moment, "Moment [\(mark.timestamp)] \(mark.heading)", mark.insight)
            }
        }

        out.append(contentsOf: transcriptPassages(for: recording, startingAt: order))
        return out
    }

    private static func transcriptPassages(for recording: Recording, startingAt start: Int) -> [Passage] {
        guard !recording.segments.isEmpty else { return [] }
        var out: [Passage] = []
        var order = start
        var buffer = ""
        var stamp = recording.segments[0].stamp

        func flush() {
            let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            out.append(Passage(recordingID: recording.id, kind: .said,
                               label: "Said [\(stamp)]", body: trimmed, order: order))
            order += 1
            buffer = ""
        }

        for segment in recording.segments {
            if buffer.isEmpty { stamp = segment.stamp }
            buffer += (buffer.isEmpty ? "" : " ") + segment.text
            if buffer.count >= transcriptWindow { flush() }
        }
        flush()
        return out
    }

    // MARK: Ranking

    private static func rank(_ passages: [Passage], against terms: [String]) -> [Passage] {
        let corpus = Array(passages.prefix(maxPassages))
        // Each side is expanded to every form of every word, so "closures" in
        // the question meets "closure" in the notes.
        let passageSets = corpus.map { indexSet(for: $0.rendered) }
        let groups = terms.map(variants(of:))

        // Plain IDF. A word in every passage tells us nothing about which one to
        // pick; a word in three of them tells us a lot.
        var documentFrequency = [Int](repeating: 0, count: groups.count)
        for set in passageSets {
            for (index, group) in groups.enumerated() where !group.isDisjoint(with: set) {
                documentFrequency[index] += 1
            }
        }
        let total = Double(corpus.count)
        let idf = documentFrequency.map { df in
            log(1 + (total - Double(df) + 0.5) / (Double(df) + 0.5))
        }

        var scored: [Passage] = []
        scored.reserveCapacity(corpus.count)
        for (index, passage) in corpus.enumerated() {
            let set = passageSets[index]
            var score = 0.0
            var matched = 0
            for (groupIndex, group) in groups.enumerated() where !group.isDisjoint(with: set) {
                score += idf[groupIndex]
                matched += 1
            }
            guard matched > 0 else { continue }
            // Reward passages that cover more of the question rather than
            // repeating one rare word.
            let coverage = Double(matched) / Double(groups.count)
            var passage = passage
            passage.score = score * passage.kind.weight * (0.6 + 0.4 * coverage)
            scored.append(passage)
        }
        return scored.sorted { $0.score > $1.score }
    }

    // MARK: Selection

    private struct Selection {
        var recaps: [Recording]
        var passagesByRecap: [UUID: [Passage]]
        var clipped: Bool
    }

    /// Header cost per recap, so the budget accounts for the titles too.
    private static let headerCost = 60

    private static func select(
        _ ranked: [Passage], from recaps: [Recording], budget: Int, hasQuery: Bool
    ) -> Selection {
        var chosen: [UUID: [Passage]] = [:]
        var spent = 0
        var clipped = false

        for passage in ranked {
            let cost = passage.cost + (chosen[passage.recordingID] == nil ? headerCost : 0)
            guard spent + cost <= budget else { clipped = true; continue }
            chosen[passage.recordingID, default: []].append(passage)
            spent += cost
        }

        // Nothing matched — or nothing fit. Falling back to the most recent
        // gists beats handing the model an empty context and letting it
        // improvise.
        if chosen.isEmpty {
            for recording in recaps {
                let all = passages(for: recording)
                guard let gist = all.first(where: { $0.kind == .gist }) ?? all.first else { continue }
                let cost = gist.cost + headerCost
                guard spent + cost <= budget else { clipped = true; break }
                chosen[recording.id] = [gist]
                spent += cost
            }
            clipped = clipped || !hasQuery
        }

        for id in chosen.keys {
            chosen[id]?.sort { $0.order < $1.order }
        }
        return Selection(recaps: recaps.filter { chosen[$0.id] != nil },
                         passagesByRecap: chosen,
                         clipped: clipped)
    }

    // MARK: Rendering

    private static func render(_ selection: Selection, searchedCount: Int) -> RetrievedContext {
        var blocks: [String] = []
        for recording in selection.recaps {
            guard let passages = selection.passagesByRecap[recording.id] else { continue }
            var block = "## \(recording.displayTitle)\n"
            block += "(\(recording.mode.title), \(recording.createdAt.formatted(date: .abbreviated, time: .omitted)))\n"
            block += passages.map(\.rendered).joined(separator: "\n")
            blocks.append(block)
        }

        return RetrievedContext(
            text: blocks.joined(separator: "\n\n"),
            recaps: selection.recaps,
            searchedCount: searchedCount,
            clipped: selection.clipped
        )
    }

    // MARK: Tokens

    private static let stopwords: Set<String> = [
        "the", "and", "for", "was", "were", "are", "did", "does", "with", "that", "this", "from",
        "what", "when", "where", "which", "who", "whom", "why", "how", "into", "onto", "about",
        "there", "their", "they", "them", "then", "than", "have", "has", "had", "you", "your",
        "can", "could", "would", "should", "will", "shall", "may", "might", "must", "but", "not",
        "any", "all", "some", "more", "most", "much", "many", "one", "two", "get", "got", "his",
        "her", "its", "our", "out", "off", "over", "under", "again", "just", "also", "been",
        "being", "because", "does", "doing", "done", "say", "said", "says", "tell", "explain",
    ]

    /// The words in a question worth matching on: lowercased, de-punctuated,
    /// stopwords and noise dropped.
    static func tokens(in text: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= 3, !stopwords.contains(word), seen.insert(word).inserted else { continue }
            out.append(word)
        }
        return out
    }

    /// Every form a word might appear in.
    ///
    /// Stemming one side only doesn't work: "closures" reduces to "closur"
    /// while "closure" stays put, so the plural in the question never meets the
    /// singular in the notes. Expanding both sides and intersecting is
    /// symmetric by construction, which is what a hand-rolled stemmer can't be.
    static func variants(of word: String) -> Set<String> {
        var out: Set<String> = [word]
        guard word.count > 4 else { return out }
        if word.hasSuffix("ies") { out.insert(word.dropLast(3) + "y") }
        if word.hasSuffix("es") { out.insert(String(word.dropLast(2))) }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { out.insert(String(word.dropLast())) }
        if word.hasSuffix("ing") { out.insert(String(word.dropLast(3))) }
        if word.hasSuffix("ed") { out.insert(String(word.dropLast(2))) }
        return out
    }

    /// Everything a passage could be matched against.
    static func indexSet(for text: String) -> Set<String> {
        var out = Set<String>()
        for raw in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            let word = String(raw)
            guard word.count >= 3 else { continue }
            out.formUnion(variants(of: word))
        }
        return out
    }
}
