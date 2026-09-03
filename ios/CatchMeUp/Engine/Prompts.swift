import Foundation

/// Schemas + prompt assembly, ported from pipeline.py.
enum Prompts {
    static let meetingSchema = """
    Return ONLY valid JSON (no markdown fences, no commentary) matching this shape:
    {
      "title": "short descriptive meeting title",
      "tldr": ["bullet 1", "bullet 2", "..."],
      "action_items": ["Speaker 1 / Jordan: who does what, with deadline if mentioned"],
      "speakers": [
        {"label": "Speaker 1", "name": "Jordan or unknown", "said": "their role in this meeting in one line"}
      ],
      "bookmarks": [
        {"timestamp": "HH:MM:SS", "heading": "short label", "insight": "why this moment matters, in plain terms"}
      ],
      "detailed_notes": [
        {"heading": "topic heading", "content": "in-depth notes for this topic, several sentences"}
      ]
    }
    Include 5-15 bookmarks for the important / decision / action-item moments, spread across the whole meeting.
    Include as many detailed_notes sections as needed to cover the meeting thoroughly.
    List every follow-up and owner you can hear in action_items. Prefer the speaker label plus any name used.
    If the transcript has speaker labels, fill speakers[] — do not invent names you cannot hear.
    """

    static let lectureSchema = """
    Return ONLY valid JSON (no markdown fences, no commentary) matching this shape:
    {
      "title": "short lecture title (course + topic if you can tell)",
      "tldr": ["the 5-10 things a student who missed class must know"],
      "bookmarks": [
        {"timestamp": "HH:MM:SS", "heading": "concept or example name", "insight": "why this matters for the exam"}
      ],
      "detailed_notes": [
        {"heading": "topic heading", "content": "teach this topic clearly in several sentences, as if the student was absent"}
      ],
      "terms": [
        {"term": "vocab / formula / name", "definition": "plain-language definition"}
      ],
      "study": ["exam-style prompt or thing to memorize / practice"]
    }
    Include 5-15 bookmarks for definitions, worked examples, and "this will be on the exam" moments.
    Cover the lecture thoroughly in detailed_notes. Prefer teaching over quoting.
    """

    static func schema(for mode: Mode) -> String {
        mode == .lecture ? lectureSchema : meetingSchema
    }

    static func userPrompt(transcript: String, mode: Mode) -> String {
        """
        \(mode.roleInstruction)

        \(schema(for: mode))

        Transcript (timestamped):
        \(transcript)
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
    - Finish with one last line, exactly: `Sources: <recap title>, <recap title>`
    """

    static func askPrompt(question: String, persona: String, context: String) -> String {
        let voice = persona.isEmpty ? "You answer questions about a set of recap notes." : persona
        return """
        \(voice)

        Answer the question using ONLY the notes below. If the notes don't cover it, say so.

        \(answerFormat)

        --- NOTES ---
        \(context)
        --- END NOTES ---

        Question: \(question)
        """
    }
}
