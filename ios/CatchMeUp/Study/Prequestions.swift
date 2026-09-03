import Foundation

// MARK: - Prequestions
//
// Two or three questions asked *before* the notes are read.
//
// The instinct is that this is backwards — how can you answer a question about
// material you haven't seen? That's the point. A failed guess primes the
// reading: the reader now has a question in mind, notices the answer when it
// arrives, and remembers it better than someone who read the same page cold
// (Richland, Kornell & Kao 2009; Little & Bjork 2016). The benefit survives
// wrong answers, which is why nothing here is scored and the copy never treats
// a miss as a failure.
//
// Two rules follow from the mechanism, and both are enforced elsewhere in the
// code but belong on the record here:
//
//   1. It happens once, before the first read. Afterwards it's just a quiz.
//   2. It does not touch the FSRS schedule. A pretest answer says nothing
//      about how long a memory will last — there is no memory yet — so
//      grading one as a review would start intervals on material the reader
//      has not even been taught. Prequestions leave every item `new`.

enum Prequestions {

    /// How many to ask. Three is about the ceiling before it stops feeling like
    /// a warm-up and starts feeling like a gate in front of your own notes.
    static let count = 3

    /// The fewest questions worth interrupting for.
    static let minimum = 2

    /// Kinds that work cold, best first.
    ///
    /// `cloze` and `choice` are deliberately excluded. A fill-in-the-blank with
    /// no prior exposure is unanswerable rather than productively hard, and
    /// multiple choice hands over the answer set — the reader recognises rather
    /// than generates, which is the one thing pretesting needs them to do.
    private static let order: [StudyItemKind] = [.term, .concept, .moment, .application]

    /// Picks the questions for one recap.
    ///
    /// Pure and order-stable: given the same bank it always asks the same
    /// things, so a reader who backgrounds the app mid-pretest comes back to
    /// the same three questions.
    static func pick(from items: [StudyItem], limit: Int = count) -> [StudyItem] {
        let usable = items.filter { !$0.deleted && !$0.suspended && order.contains($0.kind) }

        // One from each kind before a second of any — a warm-up that is three
        // definitions in a row has sampled one corner of the recap and primed
        // the reader for one corner of the reading. Kinds with nothing to offer
        // are simply skipped, so a terms-only recap still fills its three.
        let buckets = order.map { kind in usable.filter { $0.kind == kind } }
        var cursors = [Int](repeating: 0, count: buckets.count)

        var taken: [Set<String>] = []
        var out: [StudyItem] = []
        while out.count < limit {
            var tookOne = false
            for b in buckets.indices where out.count < limit {
                while cursors[b] < buckets[b].count {
                    let item = buckets[b][cursors[b]]
                    cursors[b] += 1
                    let sig = signature(item)
                    guard !sig.isEmpty, !taken.contains(where: { overlap($0, sig) }) else { continue }
                    taken.append(sig)
                    out.append(item)
                    tookOne = true
                    break
                }
            }
            guard tookOne else { break }
        }
        return out
    }

    /// What a question is *about*, as bare topic words.
    ///
    /// The item's own `concept` isn't enough on its own: it's whatever the mint
    /// had to hand, so one recap can yield a note headed "Graph" and a bookmark
    /// headed "What are graphs?" — two different concept keys for one topic.
    /// Stripping the question scaffolding leaves {graph} in both cases.
    static func signature(_ item: StudyItem) -> Set<String> {
        let source = item.concept.isEmpty ? item.prompt : item.concept
        // No length filter: single characters carry the subject often enough in
        // this material ("what is n?", "the k in k-means") that dropping them
        // would merge distinct questions. The scaffolding list covers the short
        // words that are actually noise.
        let words = StudyItem.normalize(source).split(separator: " ").map(String.init)
        let subject = words.filter { !scaffolding.contains($0) }
        // A prompt made entirely of scaffolding ("What does this mean?") still
        // has to be distinguishable from the next one, so fall back to the
        // whole phrase rather than treating it as having no subject at all.
        return Set(subject.isEmpty ? words : subject)
    }

    /// Words that describe the shape of a question rather than its subject.
    ///
    /// Deliberately conservative. Words that could plausibly be the thing being
    /// taught stay out of this list — "state" in a state machine, "term" in a
    /// maths lecture, "class" in an OOP one — because wrongly calling a subject
    /// word scaffolding merges two questions that aren't the same.
    private static let scaffolding: Set<String> = [
        "what", "which", "who", "whose", "why", "how", "when", "where",
        "explain", "describe", "define", "definition", "give",
        "the", "and", "for", "your", "own", "word", "one", "two", "sentence",
        "mean", "means", "meaning", "about", "does", "did", "was", "were",
        "this", "that", "these", "those", "there", "here", "with", "from",
        "into", "is", "are", "of", "in", "to", "it", "do", "be", "as", "at",
        "on", "or", "an", "a", "i",
    ]

    /// Two questions count as the same topic when one's subject words are
    /// contained in the other's — "graph" against "graph", or "mutex" against
    /// "mutex lock". Merely sharing a word isn't enough: "lock ordering" and
    /// "lock contention" are different questions worth asking separately.
    private static func overlap(_ a: Set<String>, _ b: Set<String>) -> Bool {
        a.isSubset(of: b) || b.isSubset(of: a)
    }

    /// Whether this recap is worth a pretest at all.
    static func worthAsking(_ items: [StudyItem]) -> Bool {
        pick(from: items).count >= minimum
    }

    // MARK: Wording
    //
    // The framing does real work: a reader who thinks they are being tested
    // will skip, and a reader who thinks a wrong guess was wasted has learned
    // the opposite of the lesson.

    static let intro = "Guess before you read. Even a wrong guess makes the answer stick when you meet it in the notes — nothing here is scored."

    /// What to say once it's over, given how many landed.
    static func closing(correct: Int, asked: Int) -> String {
        guard asked > 0 else { return "No problem — the notes are next." }
        if correct == 0 {
            return "All new, then. Those are the bits to watch for as you read."
        }
        if correct == asked {
            return "You already knew all of it. The notes will fill in the rest."
        }
        return "\(correct) of \(asked) already there. Watch for the other \(asked - correct) as you read."
    }
}
