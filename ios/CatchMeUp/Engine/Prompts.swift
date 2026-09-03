import Foundation

/// Schemas + prompt assembly, ported from pipeline.py.
enum Prompts {
    /// One schema for every recap. Empty arrays are omitted after parse; asking
    /// for only half of this is what made office hours lose their follow-ups.
    static let unionSchema = """
    Return ONLY valid JSON (no markdown fences, no commentary) matching this shape:
    {
      "title": "short descriptive title",
      "tldr": ["the things someone who missed this must know"],
      "action_items": ["who does what, with deadline if mentioned"],
      "speakers": [
        {"label": "Speaker 1", "name": "a name only if you hear it", "said": "their role in one line"}
      ],
      "bookmarks": [
        {"timestamp": "HH:MM:SS", "heading": "short label", "insight": "why this moment matters, in plain terms"}
      ],
      "detailed_notes": [
        {"heading": "topic heading", "content": "in-depth notes for this topic, several sentences"}
      ],
      "terms": [
        {"term": "vocab / formula / name", "definition": "plain-language definition"}
      ],
      "study": ["exam-style prompt or thing to memorize / practice"]
    }
    Include 5-15 bookmarks for the important moments, spread across this part.
    Cover the recording thoroughly in detailed_notes.
    Fill action_items and speakers only from what you can hear — never invent a name or owner.
    Fill terms and study only when material is actually taught. Leave unused arrays empty.
    """

    static func schema(for mode: Mode) -> String {
        _ = mode
        return unionSchema
    }

    /// The prompt for one window of transcript.
    ///
    /// `includeSchema` is false for guided generation, where FoundationModels
    /// describes the shape itself — repeating our JSON schema there would spend
    /// context we've already chunked the transcript to fit, and give the model
    /// two descriptions of the same thing to reconcile.
    static func recapPrompt(
        transcript: String, mode: Mode, part: Int = 1, of total: Int = 1, includeSchema: Bool = true
    ) -> String {
        var blocks = [mode.roleInstruction]
        if total > 1 { blocks.append(partFraming(part: part, of: total)) }
        if includeSchema { blocks.append(schema(for: mode)) }

        let heading = total > 1
            ? "Transcript for part \(part) of \(total) (timestamped):"
            : "Transcript (timestamped):"
        blocks.append("\(heading)\n\(transcript)")

        return blocks.joined(separator: "\n\n")
    }

    /// One slice of a transcript too long for the model's window. The pieces are
    /// merged in Swift afterwards, so each pass only has to cover its own part
    /// well — and has to be told not to summarise the whole thing from a
    /// fragment of it.
    private static func partFraming(part: Int, of total: Int) -> String {
        """
        This is part \(part) of \(total) of a longer recording. Cover ONLY what is in \
        this part. Do not summarise the recording as a whole, do not speculate about \
        what came before or after, and do not invent timestamps outside this part. \
        Another pass is handling the other parts and the results will be combined.
        \(part == 1
            ? "Give the recording a title based on what you can see here."
            : "Leave the title empty — part 1 has already named it.")
        """
    }

    // Ask (RAG over a brain)

    /// The answer is rendered as Markdown on a phone screen, so the shape of it
    /// matters as much as the content.
    static let answerFormat = """
    Formatting:
    - Open with a direct one or two sentence answer. No heading above it.
    - Then use `## ` headings only if the answer really has two or more parts. Never use `#`.
    - Prefer short bullets over long paragraphs, and bold the term each bullet is about.
    - Put code in a fenced block with its language. Keep formulas as plain text, not LaTeX.
    - Aim for under 250 words unless a plan or list was asked for.
    - Finish with one last line beginning `Sources:`. Copy recording titles exactly. For a \
      provided material, append the strongest location as `[Page 4]` or `[Slide 12]`.
    """

    /// `sources` are the exact recap and material titles that made it into the context.
    /// Naming them explicitly is what makes the trailing `Sources:` line worth
    /// anything — without it the model cites whatever title it half-remembers,
    /// and a citation nobody can check is worse than none.
    static func askPrompt(
        question: String, persona: String, context: String, sources: [String] = []
    ) -> String {
        let voice = persona.isEmpty ? "You answer questions about recordings and their supporting materials." : persona
        let sourceRule = sources.isEmpty
            ? ""
            : """

            The context below is excerpted from recordings and provided materials. These are the only \
            titles you may put in the Sources line — copy them exactly:
            \(sources.map { "- \($0)" }.joined(separator: "\n"))
            """

        return """
        \(voice)

        Answer the question using ONLY the context below. If it doesn't cover the answer, say so \
        plainly rather than filling the gap from general knowledge. Lines beginning \
        "Said [00:00:00]" come from transcripts. Lines marked Page or Slide come from \
        provided material. Never claim provided material was said aloud. When comparing the \
        two, clearly distinguish what was said, what was supplied, and what you inferred.
        \(sourceRule)

        \(answerFormat)

        --- CONTEXT ---
        \(context)
        --- END CONTEXT ---

        Question: \(question)
        """
    }
}
