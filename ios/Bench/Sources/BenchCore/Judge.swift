import Foundation

// A model-as-judge pass, used only for what mechanical checks can't see:
// whether the notes are faithful, complete and useful.
//
// Two safeguards against the obvious problems with this approach:
//   * Blind. Every recap is rendered to the same Markdown, and the judge is
//     never told which engine wrote it.
//   * Position-balanced. Every pairwise comparison runs in both orders, and a
//     winner only counts if it wins in both; disagreement is recorded as a tie.
//
// The judge is still a Claude model and may favour Claude-style prose. That is
// why the pass bar leans on mechanical metrics too, and why `bench report`
// prints the sample size next to every judged number.

struct AbsoluteJudgment: Codable {
    var transcriptId: String
    var engine: String
    var judgeModel: String
    var faithfulness: Int
    var completeness: Int
    var usefulness: Int
    var unsupportedClaims: [String]
    var missingKeyPoints: [String]
    var notes: String

    var mean: Double { Double(faithfulness + completeness + usefulness) / 3 }
}

struct PairJudgment: Codable {
    var transcriptId: String
    /// Shown first to the judge.
    var first: String
    /// Shown second.
    var second: String
    var judgeModel: String
    /// "first", "second" or "tie".
    var winner: String
    var reason: String

    /// The engine that won, or nil for a tie.
    var winnerEngine: String? {
        switch winner {
        case "first": return first
        case "second": return second
        default: return nil
        }
    }
}

enum Judge {

    // MARK: Prompts

    static let absoluteSystem = """
    You are a strict evaluator of notes written from a recording transcript. \
    You are given the transcript, optionally a list of facts the notes should cover, \
    and one set of notes. You do not know who or what wrote the notes. \
    Judge only against the transcript; never reward content because it sounds plausible.

    Score each from 1 to 5 as integers:
    - faithfulness: 5 means every claim, name, number and attribution in the notes is supported \
    by the transcript. Subtract for each invented name, figure, owner, deadline or misattributed \
    statement. 1 means the notes are largely made up or contradict the transcript.
    - completeness: 5 means someone who missed the recording would learn every important point, \
    decision, definition and follow-up. 1 means most of the substance is missing.
    - usefulness: 5 means the notes are clear, well organised and directly usable for studying \
    or acting on. Penalise vagueness, repetition, filler and notes that merely paraphrase \
    line by line.

    List concrete unsupportedClaims (quote or describe each, empty if none) and \
    missingKeyPoints (important things in the transcript that the notes leave out, empty if none). \
    Keep notes to one or two sentences.
    """

    static let pairSystem = """
    You compare two sets of notes (A and B) written from the same recording transcript. \
    You do not know who or what wrote either. Decide which set better serves someone who missed \
    the recording, weighing faithfulness to the transcript most heavily (invented names, numbers, \
    owners or claims are serious), then completeness of the important points, then clarity. \
    Length alone is not quality. Answer "A", "B" or "tie" if they are genuinely equivalent, \
    and give a one or two sentence reason.
    """

    static let absoluteSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "faithfulness": ["type": "integer"],
            "completeness": ["type": "integer"],
            "usefulness": ["type": "integer"],
            "unsupportedClaims": ["type": "array", "items": ["type": "string"]],
            "missingKeyPoints": ["type": "array", "items": ["type": "string"]],
            "notes": ["type": "string"],
        ],
        "required": ["faithfulness", "completeness", "usefulness", "unsupportedClaims", "missingKeyPoints", "notes"],
        "additionalProperties": false,
    ]

    static let pairSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "winner": ["type": "string", "enum": ["A", "B", "tie"]],
            "reason": ["type": "string"],
        ],
        "required": ["winner", "reason"],
        "additionalProperties": false,
    ]

    static func absolutePrompt(item: CorpusItem, recap: Recap) -> String {
        var blocks = ["TRANSCRIPT (\(item.mode.title)):\n\(item.transcript)"]
        if !item.gold.facts.isEmpty {
            blocks.append("FACTS THE NOTES SHOULD COVER:\n" + item.gold.facts.map { "- \($0.id)" }.joined(separator: "\n"))
        }
        blocks.append("NOTES TO EVALUATE:\n\(RecapAnalysis.markdown(recap))")
        return blocks.joined(separator: "\n\n---\n\n")
    }

    static func pairPrompt(item: CorpusItem, a: Recap, b: Recap) -> String {
        """
        TRANSCRIPT (\(item.mode.title)):
        \(item.transcript)

        ---

        NOTES A:
        \(RecapAnalysis.markdown(a))

        ---

        NOTES B:
        \(RecapAnalysis.markdown(b))
        """
    }

    // MARK: Calls

    static func score(
        item: CorpusItem, run: RunRecord, recap: Recap, model: String, apiKey: String
    ) async throws -> AbsoluteJudgment {
        let reply = try await AnthropicHTTP.message(
            model: model, system: absoluteSystem, user: absolutePrompt(item: item, recap: recap),
            maxTokens: 2_000, effort: "medium", jsonSchema: absoluteSchema, apiKey: apiKey
        )
        let json = try object(reply.text)
        func rating(_ key: String) throws -> Int {
            guard let n = json[key] as? Int else { throw BenchError.badJudgeReply("missing \(key)") }
            return min(5, max(1, n))
        }
        return AbsoluteJudgment(
            transcriptId: item.id, engine: run.engine, judgeModel: model,
            faithfulness: try rating("faithfulness"),
            completeness: try rating("completeness"),
            usefulness: try rating("usefulness"),
            unsupportedClaims: json["unsupportedClaims"] as? [String] ?? [],
            missingKeyPoints: json["missingKeyPoints"] as? [String] ?? [],
            notes: json["notes"] as? String ?? ""
        )
    }

    static func compare(
        item: CorpusItem, first: (engine: String, recap: Recap), second: (engine: String, recap: Recap),
        model: String, apiKey: String
    ) async throws -> PairJudgment {
        let reply = try await AnthropicHTTP.message(
            model: model, system: pairSystem, user: pairPrompt(item: item, a: first.recap, b: second.recap),
            maxTokens: 1_000, effort: "medium", jsonSchema: pairSchema, apiKey: apiKey
        )
        let json = try object(reply.text)
        let winner: String
        switch json["winner"] as? String {
        case "A": winner = "first"
        case "B": winner = "second"
        case "tie": winner = "tie"
        default: throw BenchError.badJudgeReply("winner was not A, B or tie")
        }
        return PairJudgment(
            transcriptId: item.id, first: first.engine, second: second.engine, judgeModel: model,
            winner: winner, reason: json["reason"] as? String ?? ""
        )
    }

    static func object(_ text: String) throws -> [String: Any] {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Structured output should already be bare JSON; tolerate a fence anyway.
        if let open = body.firstIndex(of: "{"), let close = body.lastIndex(of: "}"), open < close {
            body = String(body[open...close])
        }
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BenchError.badJudgeReply(String(text.prefix(120)))
        }
        return json
    }
}

// MARK: - Storage

extension ResultStore {
    func absoluteURL(transcript: String, engine: String) -> URL {
        judgmentsDir.appendingPathComponent("abs.\(transcript).\(engine).json")
    }

    func pairURL(transcript: String, first: String, second: String) -> URL {
        judgmentsDir.appendingPathComponent("pair.\(transcript).\(first)-before-\(second).json")
    }

    func save<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: judgmentsDir, withIntermediateDirectories: true)
        try Self.encoder.encode(value).write(to: url)
    }

    func loadAbsolute() throws -> [AbsoluteJudgment] {
        try Self.loadAll(AbsoluteJudgment.self, in: judgmentsDir, prefix: "abs.")
    }

    func loadPairs() throws -> [PairJudgment] {
        try Self.loadAll(PairJudgment.self, in: judgmentsDir, prefix: "pair.")
    }
}
