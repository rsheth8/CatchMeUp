import Foundation

// MARK: - Grading
//
// Marks a typed short answer against the lecture's own wording.
//
// Two passes, in this order:
//
//   1. Offline keyword matching. No network, no API key, instant. This is the
//      one that always runs, so a review on a plane still works.
//   2. An optional model pass, only when the offline result is ambiguous —
//      a paraphrase that hits the idea in different words is the case keyword
//      matching gets wrong, and it's exactly the case worth spending a call on.
//
// Ported from `catchmeup/exam.py`, which had years of tuning against real
// lecture text; the stop-word list and synonym groups come straight across.

enum Grading {

    enum Verdict: String, Codable, Hashable {
        case pass
        case partial
        case miss
        case blank

        var title: String {
            switch self {
            case .pass:    return "Correct"
            case .partial: return "Partly there"
            case .miss:    return "Not quite"
            case .blank:   return "Skipped"
            }
        }

        var symbol: String {
            switch self {
            case .pass:    return "checkmark.circle.fill"
            case .partial: return "circle.lefthalf.filled"
            case .miss:    return "xmark.circle.fill"
            case .blank:   return "minus.circle"
            }
        }

        var isRecall: Bool { self == .pass }
    }

    struct Result: Hashable {
        var verdict: Verdict
        /// 0…1 share of the expected key ideas that appeared.
        var score: Double
        /// Which keys the answer hit — shown back as "you got: …".
        var hits: [String]
        /// Which it missed — the actionable half.
        var missed: [String]
        /// One clause explaining the mark, already written for display.
        var because: String

        static let blank = Result(verdict: .blank, score: 0, hits: [], missed: [],
                                  because: "Nothing typed")
    }

    // MARK: Offline

    /// Words too common to count as evidence that someone knew the answer.
    static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "from", "have", "has", "had",
        "was", "were", "are", "you", "your", "its", "it's", "but", "not", "can",
        "will", "would", "could", "should", "when", "where", "what", "which",
        "who", "how", "why", "all", "any", "each", "some", "more", "most", "than",
        "then", "them", "they", "their", "there", "these", "those", "into", "over",
        "only", "also", "just", "like", "used", "using", "very", "common", "means",
        "meaning", "called", "make", "makes", "does", "done", "take", "takes",
        "give", "gives", "one", "two", "often", "still", "even", "best", "though",
        "expect", "core", "rule", "name", "call", "value", "data", "define",
        "short", "answer", "choice", "exam", "quiz", "practice", "question",
        "student", "students", "lecture", "both", "piece", "instead", "exist",
        "options", "wrong", "because", "about", "same", "such", "been", "being",
    ]

    /// Words that mean the same thing often enough that marking them apart
    /// would just be pedantry.
    static let synonymGroups: [Set<String>] = [
        ["concatenate", "concatenation", "concat", "join", "joined", "joining",
         "append", "appended", "combine", "combined"],
        ["mutex", "lock", "locks", "locking"],
        ["exclusive", "excluded", "exclude"],
        ["inclusive", "included", "include", "including"],
        ["backward", "backwards", "reverse", "reversed", "reversing"],
        ["acquire", "acquired", "acquiring"],
        ["release", "released", "releasing"],
        ["frame", "frames", "stack"],
        ["pointer", "pointers", "reference", "references"],
        ["thread", "threads", "threading"],
        ["index", "indexes", "indices", "position", "offset"],
        ["slice", "slicing", "substring", "substr"],
        ["immutable", "unchangeable", "unmodifiable"],
        ["alias", "aliasing"],
        ["mutate", "mutated", "mutation", "mutable"],
        ["derivative", "differentiate", "differentiation"],
        ["integral", "integrate", "integration"],
        ["probability", "chance", "likelihood"],
    ]

    /// Marks `typed` against the item, using only what's on the device.
    static func offline(_ item: StudyItem, typed: String) -> Result {
        let answer = item.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        let input = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .blank }

        // Multiple choice is exact by construction.
        if item.kind == .choice { return .blank }

        if answer.isEmpty {
            return Result(verdict: .partial, score: 0.5, hits: [], missed: [],
                          because: "No stored answer to check against — compare it yourself")
        }

        let lowerAnswer = answer.lowercased()
        let lowerTyped = input.lowercased()
        if lowerTyped.contains(lowerAnswer) || lowerAnswer.contains(lowerTyped) {
            return Result(verdict: .pass, score: 1, hits: [], missed: [],
                          because: "Matches the lecture wording")
        }

        var keys = item.keys.filter { !$0.isEmpty }
        if keys.isEmpty { keys = extractKeys(from: answer) }
        guard !keys.isEmpty else {
            return Result(verdict: .partial, score: 0.5, hits: [], missed: [],
                          because: "Nothing specific to check — compare it yourself")
        }

        let blob = normalizedBlob(input)
        let tokens = expand(Set(tokenize(input)))

        var hits: [String] = []
        var missed: [String] = []
        for key in keys {
            if matches(key, blob: blob, tokens: tokens) { hits.append(key) } else { missed.append(key) }
        }

        // A long or symbol-bearing key is stronger evidence than a short word.
        let strong = hits.filter { $0.count > 4 || $0.contains(where: "[]+=()".contains) }
        let denominator = max(1, min(keys.count, 5))
        let score = Double(hits.count) / Double(denominator)

        let verdict: Verdict
        if strong.count >= 2 || (score >= 0.45 && (!strong.isEmpty || hits.count >= 2)) {
            verdict = .pass
        } else if score >= 0.25 || !strong.isEmpty {
            verdict = .partial
        } else {
            verdict = .miss
        }

        var parts: [String] = []
        if !hits.isEmpty { parts.append("you got: " + hits.prefix(4).joined(separator: ", ")) }
        if !missed.isEmpty && verdict != .pass {
            parts.append("still needed: " + missed.prefix(3).joined(separator: ", "))
        }

        return Result(verdict: verdict, score: min(1, score), hits: hits,
                      missed: Array(missed.prefix(4)),
                      because: parts.joined(separator: " · "))
    }

    /// Grades a multiple-choice tap.
    static func choice(_ item: StudyItem, picked: Int) -> Result {
        guard let correct = item.correctChoice else { return .blank }
        if picked == correct {
            return Result(verdict: .pass, score: 1, hits: [], missed: [], because: "")
        }
        let right = item.choices.indices.contains(correct) ? item.choices[correct] : item.answer
        return Result(verdict: .miss, score: 0, hits: [], missed: [],
                      because: "The answer was “\(right)”")
    }

    // MARK: Model pass

    /// Whether it's worth asking the model. Only ambiguous middles — a clear
    /// pass or an empty answer is already settled.
    static func wantsModelCheck(_ result: Result, typed: String) -> Bool {
        if result.verdict == .blank { return false }
        if result.verdict == .pass && result.score >= 0.7 { return false }
        return tokenize(typed).count >= 3
    }

    /// Asks the configured model whether a paraphrase got the idea. Returns nil
    /// on any failure so the caller keeps the offline verdict.
    static func model(_ item: StudyItem, typed: String, config: ProviderConfig) async -> Result? {
        let client = LLMClient(config: config)
        let system = """
        You grade short student answers against a gold answer taken from their own \
        lecture. Accept paraphrases and synonyms. Pass if the student stated the \
        actual rule or idea, even in different words. Partial if they got one key \
        piece. Miss if the idea is absent. Never require memorised phrasing. \
        Return ONLY JSON.
        """
        let user = """
        Return ONLY this JSON shape:
        {"verdict": "pass|partial|miss", "score": 0.0, "because": "one short clause, max 12 words"}

        Question: \(item.prompt)
        Gold answer: \(item.answer)
        Student answer: \(typed)
        """
        guard let raw = try? await client.complete(system: system, user: user, maxTokens: 300)
        else { return nil }

        guard let json = firstJSONObject(in: raw),
              let verdictRaw = json["verdict"] as? String,
              let verdict = Verdict(rawValue: verdictRaw.lowercased()),
              verdict != .blank
        else { return nil }

        let fallback: Double
        switch verdict {
        case .pass:    fallback = 0.85
        case .partial: fallback = 0.45
        default:       fallback = 0
        }
        let reported = (json["score"] as? Double) ?? (json["score"] as? NSNumber)?.doubleValue
        let score = reported ?? fallback
        let because = (json["because"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return Result(verdict: verdict, score: min(1, max(0, score)), hits: [], missed: [],
                      because: String(because.prefix(140)))
    }

    // MARK: - Text plumbing

    static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9+\\[\\]=_]+", with: " ", options: .regularExpression)
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 2 && !stopWords.contains($0) }
    }

    /// Pulls the words an acceptable answer really ought to contain: code-ish
    /// spans first, then hyphenated terms, then the longest content words.
    static func extractKeys(from answer: String, limit: Int = 6) -> [String] {
        var keys: [String] = []
        var seen = Set<String>()

        func add(_ raw: String) {
            let k = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard k.count > 2, !seen.contains(k), !stopWords.contains(k) else { return }
            seen.insert(k)
            keys.append(k)
        }

        for pattern in [#"`([^`]+)`"#, #"\b[A-Za-z_][\w.]*\[[^\]]+\]"#,
                        #"\b[a-z][a-z0-9]*(?:-[a-z0-9]+)+\b"#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = answer as NSString
            for m in re.matches(in: answer, range: NSRange(location: 0, length: ns.length)) {
                let range = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound
                    ? m.range(at: 1) : m.range
                add(ns.substring(with: range))
            }
        }

        for word in tokenize(answer).sorted(by: { $0.count > $1.count }) where word.count >= 4 {
            add(word)
            if keys.count >= limit { break }
        }
        return Array(keys.prefix(limit))
    }

    private static func normalizedBlob(_ text: String) -> String {
        var s = " " + text.lowercased() + " "
        s = s.replacingOccurrences(of: "+=", with: " plus-equals ")
        s = s.replacingOccurrences(of: "[`'\"]", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return s
    }

    /// Adds plurals, de-hyphenated forms and synonym-group members so a correct
    /// answer isn't marked down for saying "locks" instead of "mutex".
    private static func expand(_ tokens: Set<String>) -> Set<String> {
        var out = tokens
        for w in tokens {
            out.insert(w + "s")
            if w.count > 3, w.hasSuffix("s") { out.insert(String(w.dropLast())) }
            if w.count > 4, w.hasSuffix("es") { out.insert(String(w.dropLast(2))) }
            let compact = w.replacingOccurrences(of: "-", with: "")
            if compact != w { out.insert(compact) }
        }
        for group in synonymGroups where !out.isDisjoint(with: group) {
            out.formUnion(group)
        }
        return out
    }

    private static func matches(_ key: String, blob: String, tokens: Set<String>) -> Bool {
        let k = key.lowercased().trimmingCharacters(in: .whitespaces)
        guard !k.isEmpty else { return false }
        if blob.contains(k) { return true }
        let squashedBlob = blob.replacingOccurrences(of: " ", with: "")
        if squashedBlob.contains(k.replacingOccurrences(of: " ", with: "")) { return true }
        let parts = k.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { !stopWords.contains($0) }
        return !parts.isEmpty && parts.allSatisfy { tokens.contains($0) }
    }

    /// Models like to wrap JSON in prose or fences. Take the first balanced
    /// object rather than trusting the whole response to parse.
    static func firstJSONObject(in raw: String) -> [String: Any]? {
        if let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return obj
        }
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"),
              open < close else { return nil }
        let slice = String(raw[open...close])
        guard let data = slice.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
