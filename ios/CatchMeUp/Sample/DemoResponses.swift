import Foundation

/// Deterministic, source-backed interactions. No network and no claim that a
/// language model generated these answers. Never reads outside supplied scope.
enum DemoResponses {
    static func answer(question: String, context: RetrievedContext) -> String {
        guard !context.isEmpty else { return "No matching sources yet. Add a recap or material to this brain.\n\n*Demo · local source matching, no AI request.*" }
        var terms = Set(BrainRetriever.tokens(in: question))
        let lowerQuestion = question.lowercased()
        if lowerQuestion.contains("open") || lowerQuestion.contains("next") {
            terms.formUnion(["open", "follow", "blocker", "question"])
        }
        if lowerQuestion.contains("risk") { terms.formUnion(["risk", "blocker", "blocked"]) }
        var candidates: [(source: String, text: String, score: Int)] = []
        func add(_ source: String, _ text: String) {
            let tokens = BrainRetriever.tokens(in: text)
            let score = terms.intersection(tokens).count
            candidates.append((source, text, score))
        }
        for recording in context.recaps {
            for note in recording.recap?.detailedNotes ?? [] {
                add(recording.displayTitle, "\(note.heading): \(note.content)")
            }
            for task in recording.meeting?.followUps ?? [] {
                add(recording.displayTitle, "Follow-up (\(task.status.title)): \(task.title). Owner: \(task.owner.isEmpty ? "not stated" : task.owner). Deadline: \(task.deadlineText.isEmpty ? "not stated" : task.deadlineText).")
            }
            for outcome in recording.meeting?.outcomes ?? [] {
                add(recording.displayTitle, "\(outcome.kind.title): \(outcome.text)")
            }
        }
        for material in context.materials {
            for page in material.pages {
                add("\(material.name), page \(page.number)", String(page.combinedText.prefix(550)))
            }
        }
        let broad = ["summary", "summarize", "overview", "study", "prepare", "highlights", "big ideas", "changed", "remember"].contains { lowerQuestion.contains($0) }
        let selected = candidates.enumerated()
            .filter { broad || $0.element.score > 0 }
            .sorted { $0.element.score == $1.element.score ? $0.offset < $1.offset : $0.element.score > $1.element.score }
            .prefix(4).map(\.element)
        guard !selected.isEmpty else {
            return "I couldn't match that question to this brain's sources. Try a concept, person, or project mentioned in its recaps.\n\n*Demo · local source matching, not a live AI model.*"
        }
        return "## From your sources\n\n" + selected.map {
            "- \($0.text)\n  \n  Source: *\($0.source)*"
        }.joined(separator: "\n\n") + "\n\n*Demo · excerpts selected locally. No API key or live AI model was used.*"
    }

    static func meeting(transcript: String) -> MeetingExtraction {
        var actions: [MeetingExtraction.Action] = []
        var outcomes: [MeetingExtraction.Outcome] = []
        for line in transcript.components(separatedBy: "\n") {
            guard let bracket = line.firstIndex(of: "]"), line.hasPrefix("[") else { continue }
            let stamp = String(line[line.index(after: line.startIndex)..<bracket])
            let text = String(line[line.index(after: bracket)...]).trimmingCharacters(in: .whitespaces)
            for raw in text.components(separatedBy: ". ") {
                let sentence = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !sentence.isEmpty else { continue }
                let lower = sentence.lowercased()
                if let range = sentence.range(of: " will ") {
                    let owner = String(sentence[..<range.lowerBound]).components(separatedBy: " ").last ?? ""
                    // Only names explicitly present in these authored fixtures.
                    if ["Priya", "Marcus", "Dana", "Lena", "Omar"].contains(owner) {
                        let deadline = sentence.range(of: " by ").map { String(sentence[$0.upperBound...]) } ?? ""
                        let action = String(sentence[range.upperBound...])
                        let title = action.prefix(1).uppercased() + action.dropFirst()
                        actions.append(.init(task: title, owner: owner, deadline: deadline,
                                             timestamp: stamp, evidence: sentence))
                    }
                }
                let kind: String?
                if lower.contains("we agreed") { kind = "decision" }
                else if lower.contains("blocker") || lower.contains("blocked") { kind = "blocker" }
                else if lower.contains("?") || lower.contains("not yet agreed") || lower.contains("have not agreed") { kind = "question" }
                else { kind = nil }
                if let kind {
                    outcomes.append(.init(kind: kind, text: sentence, timestamp: stamp, evidence: sentence))
                }
            }
        }
        return MeetingExtraction(actions: Array(actions.prefix(6)), outcomes: Array(outcomes.prefix(6)), context: [])
    }

    static func recap(transcript: String, mode: Mode) -> Recap {
        if let matched = try? ShowcaseCatalog.entries().first(where: { entry in
            entry.mode == mode && entry.notes.allSatisfy { transcript.contains($0[1]) }
        }) { return matched.recap }
        let lines = transcript.components(separatedBy: "\n").filter { !$0.isEmpty }
        let excerpts = lines.prefix(6).map { line -> String in
            guard let end = line.firstIndex(of: "]") else { return line }
            return String(line[line.index(after: end)...]).trimmingCharacters(in: .whitespaces)
        }
        return Recap(title: "Demo \(mode.title.lowercased()) · source excerpts", tldr: excerpts,
                     actionItems: nil, speakers: nil, bookmarks: nil,
                     detailedNotes: [DetailNote(heading: "Demo preview", content: "This is a local excerpt preview, not an AI-generated recap.\n\n" + excerpts.joined(separator: "\n\n"))],
                     terms: nil, study: nil)
    }
}
