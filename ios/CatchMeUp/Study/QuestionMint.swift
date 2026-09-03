import Foundation

// MARK: - QuestionMint
//
// Turns a finished recap into a bank of study items, once, at recap time.
//
// Precomputed rather than generated live, for three reasons: a review session
// has to start instantly, it has to work with no network, and a question the
// user has already seen must come back *identical* or the spaced schedule is
// measuring a different item each time.
//
// The offline pass is a port of `catchmeup/exam.py` — heuristics tuned against
// a lot of real lecture text. The optional model pass adds the question types
// heuristics can't write: plausible multiple-choice distractors and applied
// "use it" questions.

enum QuestionMint {

    // MARK: Filters
    //
    // What to throw away. Lecture recaps are full of section headings that
    // aren't concepts ("Overview", "Announcements") and sentences that are
    // about the exam rather than the material.

    private static let fluffHeading = regex(
        "(walkthrough|overview|big picture|announcement|introduction to |housekeeping|"
        + "basics and initialization|practical example|summary|conclusion|recap$|"
        + "^key moments|^lecture notes|^agenda|^logistics)")

    private static let metaSentence = regex(
        "will (definitely )?be on the (quiz or )?exam|multiple-choice|common exam question|"
        + "quiz question|high-difficulty|expect .*questions?|options [a-d]\\b|"
        + "critical exam topic|appear frequently on exams|this is a common exam")

    private static let examFiller = regex(
        "\\s*(this will (definitely )?be on the (quiz or )?exam[^.]*\\.?|"
        + "this is a high-difficulty topic[^.]*\\.?|"
        + "this is (the )?(core idea|fundamental syntax)[^.]*\\.?)")

    /// Single words that show up in every lecture of a subject and make
    /// worthless questions.
    private static let genericConcepts: Set<String> = [
        "class", "classes", "method", "methods", "function", "functions",
        "object", "objects", "variable", "variables", "value", "values",
        "code", "example", "examples", "program", "programs", "data", "type",
        "types", "item", "items", "self", "none", "return", "print", "input",
        "output", "file", "files", "error", "errors", "test", "tests", "loop",
        "loops", "list", "lists", "string", "strings", "number", "numbers",
        "thing", "things", "way", "case", "cases", "part", "parts", "point",
        "points", "idea", "ideas", "topic", "topics", "note", "notes",
    ]

    // MARK: - Offline mint

    /// Builds the deterministic question set for one recap. Never fails, never
    /// touches the network — this is what a student gets with no API key.
    static func items(for recording: Recording) -> [StudyItem] {
        guard let recap = recording.recap else { return [] }
        let title = recording.displayTitle
        var out: [StudyItem] = []
        var seen = Set<String>()

        func add(_ item: StudyItem?) {
            guard let item, !item.prompt.isEmpty, !item.answer.isEmpty else { return }
            let key = item.concept.isEmpty ? StudyItem.normalize(item.prompt) : item.concept
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            out.append(item)
        }

        let terms = recap.terms ?? []
        for term in terms {
            add(termItem(term, recording: recording, title: title))
        }
        // A cloze on the same definition is a different retrieval route, not a
        // duplicate — generation beats recognition (Bertsch et al. 2007) — so
        // it gets its own concept key.
        for term in terms.prefix(12) {
            add(clozeItem(term, recording: recording, title: title))
        }
        for mark in recap.bookmarks ?? [] {
            add(momentItem(mark, recording: recording, title: title))
        }
        for note in recap.detailedNotes ?? [] {
            add(noteItem(note, recording: recording, title: title))
        }
        for prompt in recap.study ?? [] {
            add(studyItem(prompt, recording: recording, title: title))
        }

        return out
    }

    // MARK: Term → "What is X?"

    private static func termItem(_ term: Term, recording: Recording, title: String) -> StudyItem? {
        let name = displayTerm(term.term)
        guard isUsableConcept(name) else { return nil }
        let gold = firstSentences(term.definition, count: 2, limit: 220)
        guard gold.count >= 24 else { return nil }

        let prompt: String
        if looksLikeCode(name) {
            prompt = "What does `\(name)` mean here? Say what each part does, in a sentence or two."
        } else if isPlural(name) {
            // Recaps list plenty of terms in the plural ("environment
            // diagrams"), and "what is an environment diagrams" is the kind of
            // sentence that makes a reader distrust everything around it.
            prompt = "What are \(lowercasedIfPlain(name))? One or two sentences, in your own words."
        } else {
            prompt = "What is \(withArticle(name))? One or two sentences, in your own words."
        }
        let keys = Grading.extractKeys(from: gold + " " + name)
        guard keys.count >= 2 || looksLikeCode(name) else { return nil }

        return StudyItem(recordingID: recording.id, brainID: recording.brainID, sourceTitle: title,
                         timestamp: nil, kind: .term, prompt: prompt, answer: gold,
                         keys: keys, concept: name)
    }

    // MARK: Term → fill the blank

    private static func clozeItem(_ term: Term, recording: Recording, title: String) -> StudyItem? {
        let name = displayTerm(term.term)
        guard isUsableConcept(name), !looksLikeCode(name) else { return nil }
        let sentence = firstSentences(term.definition, count: 1, limit: 180)
        guard sentence.count >= 40 else { return nil }

        // Blank the most informative word that isn't the term itself.
        let candidates = Grading.tokenize(sentence)
            .filter { $0.count >= 5 && !name.lowercased().contains($0) }
            .sorted { $0.count > $1.count }
        guard let target = candidates.first else { return nil }

        guard let range = sentence.range(of: target, options: [.caseInsensitive]) else { return nil }
        let blanked = sentence.replacingCharacters(in: range, with: "______")

        return StudyItem(recordingID: recording.id, brainID: recording.brainID, sourceTitle: title,
                         timestamp: nil, kind: .cloze,
                         prompt: "Fill the blank — \(name):\n\n\(blanked)",
                         answer: target, keys: [target],
                         concept: "cloze " + name)
    }

    // MARK: Bookmark → "what's the rule?"

    private static func momentItem(_ mark: Bookmark, recording: Recording, title: String) -> StudyItem? {
        let heading = mark.heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableHeading(heading) else { return nil }

        var gold = firstSentences(mark.insight, count: 2, limit: 220)
        if gold.count < 24 {
            // A heading that already states a rule can be its own answer.
            guard heading.range(of: "\\b(must|always|never|inclusive|exclusive|first|only)\\b",
                                options: [.regularExpression, .caseInsensitive]) != nil
            else { return nil }
            gold = heading.hasSuffix(".") ? heading : heading + "."
        }

        let prompt: String
        if let asked = alreadyAQuestion(heading) {
            prompt = asked
        } else if let code = codeSpans(heading).first(where: isInterestingCode) {
            prompt = "What does `\(code)` do? Name the result — or the gotcha — from the lecture."
        } else {
            prompt = "\(heading) — what is the actual rule, in one sentence?"
        }

        let keys = Grading.extractKeys(from: gold + " " + heading)
        guard !keys.isEmpty else { return nil }

        return StudyItem(recordingID: recording.id, brainID: recording.brainID, sourceTitle: title,
                         timestamp: mark.seconds, kind: .moment, prompt: prompt, answer: gold,
                         keys: keys, concept: heading)
    }

    // MARK: Detailed note → "explain this"

    private static func noteItem(_ note: DetailNote, recording: Recording, title: String) -> StudyItem? {
        let heading = note.heading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isUsableHeading(heading), note.content.count >= 40 else { return nil }
        let gold = firstSentences(note.content, count: 2, limit: 240)
        guard gold.count >= 40 else { return nil }

        let prompt = alreadyAQuestion(heading)
            ?? "In a sentence or two, explain \(lowercasedIfPlain(heading)). State the rule — a small example is fine."
        let keys = Grading.extractKeys(from: gold + " " + heading)
        guard keys.count >= 2 else { return nil }

        return StudyItem(recordingID: recording.id, brainID: recording.brainID, sourceTitle: title,
                         timestamp: nil, kind: .concept, prompt: prompt, answer: gold,
                         keys: keys, concept: heading)
    }

    // MARK: Study checklist → keep the lecture's own question

    private static func studyItem(_ raw: String, recording: Recording, title: String) -> StudyItem? {
        let text = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 24, text.count <= 240 else { return nil }
        let isQuestion = text.contains("?")
            || text.range(of: "^(given |what |if |predict |trace |compute |derive |show )",
                          options: [.regularExpression, .caseInsensitive]) != nil
        guard isQuestion else { return nil }

        return StudyItem(recordingID: recording.id, brainID: recording.brainID, sourceTitle: title,
                         timestamp: nil, kind: .application, prompt: text, answer: text,
                         keys: Grading.extractKeys(from: text), concept: text)
    }

    // MARK: - Multiple choice (offline)
    //
    // Distractors come from other terms in the same course, which makes them
    // plausible for free — a wrong option a student has actually heard of is a
    // real discrimination test, and interleaving research says confusable
    // alternatives are where the learning is (Brunmair & Richter 2019).

    static func choiceItems(from recordings: [Recording], limit: Int = 40) -> [StudyItem] {
        var pool: [(term: String, definition: String, rec: Recording)] = []
        for rec in recordings {
            for term in rec.recap?.terms ?? [] {
                let name = displayTerm(term.term)
                let gold = firstSentences(term.definition, count: 1, limit: 160)
                guard isUsableConcept(name), gold.count >= 30 else { continue }
                pool.append((name, gold, rec))
            }
        }
        guard pool.count >= 4 else { return [] }

        var out: [StudyItem] = []
        for entry in pool.shuffled().prefix(limit) {
            let others = pool
                .filter { $0.term != entry.term }
                .shuffled()
                .prefix(3)
                .map(\.definition)
            guard others.count == 3 else { continue }

            var options = Array(others) + [entry.definition]
            options.shuffle()
            guard let correct = options.firstIndex(of: entry.definition) else { continue }

            out.append(StudyItem(
                recordingID: entry.rec.id, brainID: entry.rec.brainID,
                sourceTitle: entry.rec.displayTitle, timestamp: nil, kind: .choice,
                prompt: "Which of these describes **\(entry.term)**?",
                answer: entry.definition, keys: [], choices: options, correctChoice: correct,
                concept: "choice " + entry.term))
        }
        return out
    }

    // MARK: - Model enrichment
    //
    // Optional second pass. Asks for the two things heuristics genuinely can't
    // do: application questions that require using the idea rather than
    // restating it, and a "why does this work" prompt for elaborative
    // interrogation. Failure here is silent — the offline bank still stands.

    static func enrich(_ recording: Recording, existing: [StudyItem],
                       config: ProviderConfig, limit: Int = 6) async -> [StudyItem] {
        guard let recap = recording.recap else { return [] }

        let material = ([recap.tldr ?? []]
            + [(recap.terms ?? []).map { "\($0.term): \($0.definition)" }]
            + [(recap.detailedNotes ?? []).map { "\($0.heading): \($0.content)" }])
            .flatMap { $0 }
            .prefix(40)
            .joined(separator: "\n")
        guard material.count > 200 else { return [] }

        let asked = existing.map(\.prompt).prefix(20).joined(separator: "\n- ")
        let system = """
        You write exam questions from a student's own lecture notes. Questions must be \
        answerable from the notes alone, must require applying or explaining an idea \
        rather than repeating a definition, and must have a specific correct answer. \
        Return ONLY JSON.
        """
        let user = """
        Return ONLY this JSON shape:
        {"questions": [{"prompt": "...", "answer": "one or two sentences", "concept": "short name"}]}

        Write \(limit) questions from the notes below. Rules:
        - Each must test using the idea: predict an output, choose between two options, \
        explain why something happens, apply it to a new small case.
        - The answer must be fully supported by the notes. Invent nothing.
        - Keep each answer under 40 words.
        - Do not repeat any of these existing questions:
        - \(asked)

        NOTES
        \(material)
        """

        guard let raw = try? await LLMClient(config: config)
            .complete(system: system, user: user, maxTokens: 2000),
              let json = Grading.firstJSONObject(in: raw),
              let rows = json["questions"] as? [[String: Any]]
        else { return [] }

        let title = recording.displayTitle
        var out: [StudyItem] = []
        for row in rows.prefix(limit) {
            guard let prompt = (row["prompt"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  let answer = (row["answer"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  prompt.count > 12, answer.count > 12
            else { continue }
            let concept = (row["concept"] as? String) ?? prompt
            out.append(StudyItem(
                recordingID: recording.id, brainID: recording.brainID, sourceTitle: title,
                timestamp: nil, kind: .application, prompt: prompt, answer: answer,
                keys: Grading.extractKeys(from: answer), concept: concept))
        }
        return out
    }

    // MARK: - Text helpers

    /// First `count` sentences, with exam-chatter stripped out.
    static func firstSentences(_ text: String, count: Int, limit: Int) -> String {
        var raw = replace(examFiller, in: text, with: " ")
        raw = raw.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }

        let sentences = raw
            .split(whereSeparator: { ".!?".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !matches(metaSentence, $0) }
        guard !sentences.isEmpty else { return "" }

        var joined = sentences.prefix(count).joined(separator: ". ")
        if !joined.isEmpty && !joined.hasSuffix(".") { joined += "." }
        if joined.count > limit {
            let cut = String(joined.prefix(limit - 1))
            joined = (cut.split(separator: " ").dropLast().joined(separator: " ")) + "…"
        }
        return joined
    }

    private static func isUsableConcept(_ name: String) -> Bool {
        let t = name.trimmingCharacters(in: .whitespaces).lowercased()
        return t.count >= 3 && t.count <= 48 && !genericConcepts.contains(t)
    }

    private static func isUsableHeading(_ heading: String) -> Bool {
        let h = heading.trimmingCharacters(in: .whitespaces)
        guard h.count >= 3, h.count <= 80 else { return false }
        if matches(fluffHeading, h) { return false }
        let lower = h.lowercased()
        return !["this ", "the lecture", "example setup", "recap of"].contains { lower.hasPrefix($0) }
    }

    /// Strips a parenthetical, which is nearly always an aside rather than
    /// part of the term.
    ///
    /// An *empty* pair is the exception and is kept: `dict.get()` without its
    /// parentheses stops looking like code, and the prompt then asks "what is a
    /// dict.get?" instead of showing it in backticks.
    private static func displayTerm(_ term: String) -> String {
        term.replacingOccurrences(of: "\\s*\\([^)]+\\)\\s*", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeCode(_ text: String) -> Bool {
        text.range(of: "[\\[\\]()=:`+]", options: .regularExpression) != nil
    }

    private static func isInterestingCode(_ code: String) -> Bool {
        let c = code.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty else { return false }
        // `foo()` on its own says nothing; `s[1:3]` or `+=` does.
        if c.range(of: "^[A-Za-z_]\\w*\\(\\)$", options: .regularExpression) != nil { return false }
        return c.contains(where: "[]:+=".contains)
    }

    private static func codeSpans(_ text: String) -> [String] {
        var found: [String] = []
        for pattern in [#"`([^`]+)`"#, #"\b[A-Za-z_][\w.]*\[[^\]]+\]"#, #"\+="#] {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let range = m.numberOfRanges > 1 && m.range(at: 1).location != NSNotFound
                    ? m.range(at: 1) : m.range
                let span = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
                if !span.isEmpty && !found.contains(span) { found.append(span) }
            }
        }
        return found
    }

    /// Reuses a heading that is already phrased as a question.
    private static func alreadyAQuestion(_ text: String) -> String? {
        let h = text.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty else { return nil }
        if h.hasSuffix("?") { return h }
        let starters = ["what", "why", "how", "when", "where", "which"]
        let firstWord = h.split(separator: " ").first?.lowercased() ?? ""
        guard starters.contains(firstWord) else { return nil }
        return h.hasSuffix(".") ? String(h.dropLast()) + "?" : h + "?"
    }

    /// "Environment Diagrams" → "environment diagrams", but leaves acronyms and
    /// proper nouns alone.
    ///
    /// The lowering exists because the model title-cases terms it writes, so a
    /// plain noun arrives as "Query" and would otherwise be asked about as
    /// "What is a Query?". What has to survive is any word capitalised for a
    /// reason of its own rather than by that habit — see `looksLikeName`.
    private static func lowercasedIfPlain(_ text: String) -> String {
        guard !looksLikeCode(text), !looksLikeName(text) else { return text }
        let words = text.split(separator: " ")
        let titleCase = words.allSatisfy { $0.first?.isUppercase == true }
        return titleCase ? text.lowercased() : text
    }

    /// A name rather than a noun: an acronym (HTTP), or anything carrying a
    /// capital past its first letter — GraphQL, JavaScript, PostgreSQL, iOS.
    /// Nothing reaches that shape by being title-cased, so an interior capital
    /// is the lecture's own spelling and has to survive both the lowering and
    /// the article. "What is a graphql?" is the sentence that makes a reader
    /// stop trusting every question around it.
    private static func looksLikeName(_ text: String) -> Bool {
        if text == text.uppercased() { return true }
        return text.split(separator: " ").contains {
            $0.dropFirst().contains(where: \.isUppercase)
        }
    }

    static func withArticle(_ term: String) -> String {
        let t = lowercasedIfPlain(term)
        guard !looksLikeName(t) else { return t }
        guard let first = t.first, first.isLetter, first.isLowercase else { return t }
        guard !isUncountable(t) else { return t }
        return ("aeiou".contains(first) ? "an " : "a ") + t
    }

    /// Terms that take no article — "What is clustering?", not "What is a
    /// clustering?". Mostly gerunds, which is where lecture material lives:
    /// half of what a CS course names is an activity (hashing, overfitting,
    /// scaling) rather than a thing you can have two of.
    ///
    /// Deliberately narrow. Guessing wrong in this direction ("What is
    /// function?") reads worse than the article it removes, so anything that
    /// might be countable keeps its article — including -tion words, which are
    /// countable often enough (a function, a partition, an exception) that the
    /// suffix proves nothing.
    private static func isUncountable(_ term: String) -> Bool {
        let last = term.split(separator: " ").last.map(String.init) ?? term
        guard last.count > 4, !countableWords.contains(last) else { return false }
        for suffix in ["ing", "ness", "ism", "ity", "ics", "ency", "ance"]
        where last.hasSuffix(suffix) {
            return true
        }
        return uncountableWords.contains(last)
    }

    /// Whether the term is already plural, so the question should say "what
    /// are" rather than fitting it with an article.
    ///
    /// English plurals are a swamp; this only has to be right about the shapes
    /// that appear in a term list. Words ending in -ss, -us, -is and -ics are
    /// singular despite the s, and a short word ending in s usually isn't a
    /// plural of anything worth asking about.
    static func isPlural(_ term: String) -> Bool {
        let last = (term.split(separator: " ").last.map(String.init) ?? term).lowercased()
        guard last.count > 3, last.hasSuffix("s") else { return false }
        for ending in ["ss", "us", "is", "ics", "ous"] where last.hasSuffix(ending) {
            return false
        }
        return true
    }

    /// Nouns that only look like the suffix rules — a string is a thing you can
    /// have two of, whatever its ending suggests.
    private static let countableWords: Set<String> = [
        "string", "thing", "setting", "meaning", "mapping", "binding",
        "building", "warning", "listing", "reading", "recording", "opening",
        "entity", "quantity", "identity", "utility", "activity", "priority",
        "property", "instance", "variance", "distance", "sequence", "reference",
    ]

    /// The ones no suffix rule catches, kept short on purpose.
    private static let uncountableWords: Set<String> = [
        "data", "software", "hardware", "memory", "storage", "bandwidth",
        "throughput", "latency", "evidence", "research", "feedback", "context",
        "syntax", "logic", "math", "recursion", "concurrency", "classification",
        "regression", "inference", "compression", "encryption", "authentication",
    ]

    // MARK: Regex plumbing

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ re: NSRegularExpression?, _ text: String) -> Bool {
        guard let re else { return false }
        return re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    private static func replace(_ re: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let re else { return text }
        return re.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: (text as NSString).length),
            withTemplate: template)
    }
}
