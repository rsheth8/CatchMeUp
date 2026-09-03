import Foundation

/// Practice questions from a brain's recaps. Offline — same idea as
/// `./catchup exam`: terms, key moments, and study prompts, graded by overlap.
struct ExamQuestion: Identifiable, Hashable {
    var id = UUID()
    var prompt: String
    var answer: String
    var kind: Kind
    var source: String
    var timestamp: String
    var concept: String
    var keys: [String]

    enum Kind: String, Hashable {
        case term, moment, notes, study
    }
}

struct ExamGrade: Hashable {
    var score: Double
    var verdict: Verdict
    var because: String

    enum Verdict: String {
        case pass, partial, miss, blank

        var title: String {
            switch self {
            case .pass: return "Got it"
            case .partial: return "Partly"
            case .miss: return "Not yet"
            case .blank: return "Blank"
            }
        }
    }
}

enum ExamBuilder {
    private static let stop: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "are", "was",
        "what", "when", "your", "you", "not", "but", "use", "used", "using",
        "can", "will", "how", "why", "into", "about", "have", "has",
    ]

    static func build(from recordings: [Recording], count: Int = 8) -> [ExamQuestion] {
        var pool: [ExamQuestion] = []
        var seen = Set<String>()

        func add(_ q: ExamQuestion?) {
            guard let q, !q.prompt.isEmpty, !q.answer.isEmpty else { return }
            let key = q.concept.lowercased()
            guard seen.insert(key).inserted else { return }
            pool.append(q)
        }

        for rec in recordings {
            guard let recap = rec.recap else { continue }
            let source = rec.displayTitle
            for term in recap.terms ?? [] {
                add(termQuestion(term, source: source))
            }
            for bm in recap.bookmarks ?? [] {
                add(momentQuestion(bm, source: source))
            }
            for note in recap.detailedNotes ?? [] {
                add(notesQuestion(note, source: source))
            }
            for item in recap.study ?? [] {
                add(studyQuestion(item, source: source))
            }
        }

        guard !pool.isEmpty else { return [] }
        var byKind: [ExamQuestion.Kind: [ExamQuestion]] = [
            .term: [], .moment: [], .notes: [], .study: [],
        ]
        for q in pool { byKind[q.kind, default: []].append(q) }
        for kind in byKind.keys { byKind[kind]?.shuffle() }

        let n = max(1, count)
        let quota: [(ExamQuestion.Kind, Int)] = [
            (.term, max(1, n * 2 / 5)),
            (.moment, max(1, n * 2 / 5)),
            (.notes, max(0, n / 5)),
            (.study, max(0, n / 5)),
        ]
        var picked: [ExamQuestion] = []
        var seenPrompt = Set<String>()
        func take(_ q: ExamQuestion) -> Bool {
            guard seenPrompt.insert(q.prompt.lowercased()).inserted else { return false }
            picked.append(q)
            return true
        }
        for (kind, want) in quota {
            var got = picked.filter { $0.kind == kind }.count
            while got < want, let next = byKind[kind]?.popLast(), picked.count < n {
                if take(next) { got += 1 }
            }
        }
        var leftover = byKind.values.flatMap { $0 }
        leftover.shuffle()
        for q in leftover where picked.count < n { _ = take(q) }
        picked.shuffle()
        return Array(picked.prefix(n))
    }

    static func grade(_ question: ExamQuestion, typed: String) -> ExamGrade {
        let typedTrim = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if typedTrim.isEmpty {
            return ExamGrade(score: 0, verdict: .blank, because: "empty answer")
        }
        let gold = question.answer.lowercased()
        let got = typedTrim.lowercased()
        if gold.contains(got) || got.contains(gold) {
            return ExamGrade(score: 1, verdict: .pass, because: "matches the lecture wording")
        }
        let keys = question.keys.isEmpty ? tokens(question.answer).filter { !stop.contains($0) } : question.keys
        let typedTokens = Set(tokens(typedTrim))
        let hits = keys.filter { key in
            let k = key.lowercased()
            return got.contains(k) || typedTokens.contains(k)
        }
        let denom = max(1, min(keys.count, 5))
        let score = Double(hits.count) / Double(denom)
        var because = hits.isEmpty ? "" : "you hit: " + hits.prefix(4).joined(separator: ", ")
        let missed = keys.filter { !hits.contains($0) }.prefix(3)
        if !missed.isEmpty {
            because += (because.isEmpty ? "" : " · ") + "still needed: " + missed.joined(separator: ", ")
        }
        let verdict: ExamGrade.Verdict
        if score >= 0.45 && hits.count >= 2 { verdict = .pass }
        else if score >= 0.25 || hits.contains(where: { $0.count > 4 }) { verdict = .partial }
        else { verdict = .miss }
        return ExamGrade(score: (score * 100).rounded() / 100, verdict: verdict, because: because)
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
    }

    private static func keys(from gold: String, extra: String = "") -> [String] {
        var out: [String] = []
        for w in tokens(gold + " " + extra) where !stop.contains(w) {
            if !out.contains(w) { out.append(w) }
            if out.count >= 6 { break }
        }
        return out
    }

    private static func firstSentences(_ text: String, limit: Int = 200) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let parts = trimmed.split { ".!?".contains($0) }.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        var out = parts.prefix(2).joined(separator: ". ")
        if out.count > limit {
            out = String(out.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        return out
    }

    private static func termQuestion(_ term: Term, source: String) -> ExamQuestion? {
        let gold = firstSentences(term.definition)
        guard gold.count >= 20 else { return nil }
        let shown = term.term.trimmingCharacters(in: .whitespaces)
        guard shown.count >= 2 else { return nil }
        let keyList = keys(from: gold, extra: shown)
        guard keyList.count >= 2 else { return nil }
        return ExamQuestion(
            prompt: "What is \(indefinite(shown))? One or two sentences, in your own words.",
            answer: gold,
            kind: .term,
            source: source,
            timestamp: "",
            concept: shown.lowercased(),
            keys: keyList
        )
    }

    private static func momentQuestion(_ bm: Bookmark, source: String) -> ExamQuestion? {
        let gold = firstSentences(bm.insight)
        guard gold.count >= 20, !bm.heading.isEmpty else { return nil }
        return ExamQuestion(
            prompt: "Why does “\(bm.heading)” matter? One or two sentences.",
            answer: gold,
            kind: .moment,
            source: source,
            timestamp: bm.timestamp,
            concept: bm.heading.lowercased(),
            keys: keys(from: gold, extra: bm.heading)
        )
    }

    private static func notesQuestion(_ note: DetailNote, source: String) -> ExamQuestion? {
        let gold = firstSentences(note.content)
        guard gold.count >= 24, !note.heading.isEmpty else { return nil }
        return ExamQuestion(
            prompt: "Explain \(note.heading) the way the lecture did.",
            answer: gold,
            kind: .notes,
            source: source,
            timestamp: "",
            concept: note.heading.lowercased(),
            keys: keys(from: gold, extra: note.heading)
        )
    }

    private static func studyQuestion(_ item: String, source: String) -> ExamQuestion? {
        let text = item.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 16 else { return nil }
        let prompt = text.hasSuffix("?") ? text : text
        return ExamQuestion(
            prompt: prompt,
            answer: firstSentences(item, limit: 240),
            kind: .study,
            source: source,
            timestamp: "",
            concept: String(text.lowercased().prefix(80)),
            keys: keys(from: item)
        )
    }

    private static func indefinite(_ term: String) -> String {
        let t = term.lowercased()
        guard t.first?.isLetter == true, !t.contains("["), t.split(separator: " ").count <= 4 else {
            return term
        }
        let vowels = "aeiou"
        let article = vowels.contains(t.first!) ? "an" : "a"
        return "\(article) \(t)"
    }
}
