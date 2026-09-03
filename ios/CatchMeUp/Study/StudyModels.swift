import Foundation

// MARK: - Study item
//
// One thing worth remembering, minted from a recap and scheduled by FSRS.
// Items carry their own provenance — which recap, which moment in the audio —
// because feedback that points at the source is what makes retrieval practice
// work (Wisniewski, Zierer & Hattie 2020). "Wrong" is not feedback; "here is
// the twenty seconds where your professor said it" is.

enum StudyItemKind: String, Codable, CaseIterable, Hashable {
    /// Vocabulary / definition, from the recap's terms.
    case term
    /// A key moment — a rule, a worked example, an "this will be on the exam".
    case moment
    /// A topic from the detailed notes, asked as an explain-it question.
    case concept
    /// Fill in the blank, generated from a definition sentence.
    case cloze
    /// Multiple choice with distractors.
    case choice
    /// An exam-style prompt the lecture itself posed.
    case application

    var title: String {
        switch self {
        case .term:        return "Term"
        case .moment:      return "Key moment"
        case .concept:     return "Concept"
        case .cloze:       return "Fill the blank"
        case .choice:      return "Multiple choice"
        case .application: return "Applied"
        }
    }

    var symbol: String {
        switch self {
        case .term:        return "character.book.closed"
        case .moment:      return "bookmark"
        case .concept:     return "doc.text"
        case .cloze:       return "rectangle.and.pencil.and.ellipsis"
        case .choice:      return "list.bullet"
        case .application: return "function"
        }
    }

    /// Whether a typed answer is expected. Choice items are tapped instead.
    var wantsTypedAnswer: Bool { self != .choice }
}

struct StudyItem: Codable, Identifiable, Hashable {
    var id = UUID()

    // Provenance
    var recordingID: UUID
    /// Set when the question came from a PDF or slide deck. `recordingID`
    /// remains populated for scheduling compatibility and points at an attached
    /// recap when one exists.
    var materialID: UUID?
    var brainID: UUID?
    var sourceTitle: String = ""
    /// Seconds into the recording where this was taught, when we know it.
    var timestamp: Double?

    // The question
    var kind: StudyItemKind
    var prompt: String
    var answer: String
    /// Key words/phrases an acceptable answer should contain. Offline grading
    /// leans on these so a review works with no network and no API key.
    var keys: [String] = []
    /// Multiple-choice options; `correctChoice` indexes into it.
    var choices: [String] = []
    var correctChoice: Int?
    /// Normalised grouping key, so two recaps that both teach "mutex" schedule
    /// as one thing rather than two.
    var concept: String = ""

    // Scheduling
    var memory = FSRS.Memory.unseen
    /// Taken out of rotation by the user without deleting it.
    var suspended = false

    // Sync parity with Recording / Brain
    var createdAt = Date()
    var updatedAt = Date()
    var deleted = false

    var isDue: Bool { !suspended && !deleted && memory.due <= .now }
    var isNew: Bool { memory.isNew }

    /// Answer text with the cloze blank filled back in, for the reveal.
    var revealText: String { answer }

    init(recordingID: UUID, materialID: UUID? = nil, brainID: UUID?, sourceTitle: String, timestamp: Double? = nil,
         kind: StudyItemKind, prompt: String, answer: String, keys: [String] = [],
         choices: [String] = [], correctChoice: Int? = nil, concept: String = "") {
        self.recordingID = recordingID
        self.materialID = materialID
        self.brainID = brainID
        self.sourceTitle = sourceTitle
        self.timestamp = timestamp
        self.kind = kind
        self.prompt = prompt
        self.answer = answer
        self.keys = keys
        self.choices = choices
        self.correctChoice = correctChoice
        self.concept = concept.isEmpty ? StudyItem.normalize(prompt) : StudyItem.normalize(concept)
    }

    /// Lowercased, punctuation-stripped, de-pluralised enough to merge the
    /// obvious duplicates across recaps.
    static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: " ", options: .regularExpression)
        let words = lowered.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let singular = words.map { w -> String in
            if w.count > 3, w.hasSuffix("es") { return String(w.dropLast(2)) }
            if w.count > 3, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
            return w
        }
        return singular.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    private enum CodingKeys: String, CodingKey {
        case id, recordingID, materialID, brainID, sourceTitle, timestamp, kind, prompt, answer
        case keys, choices, correctChoice, concept, memory, suspended
        case createdAt, updatedAt, deleted
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        recordingID = try c.decode(UUID.self, forKey: .recordingID)
        materialID = try c.decodeIfPresent(UUID.self, forKey: .materialID)
        brainID = try c.decodeIfPresent(UUID.self, forKey: .brainID)
        sourceTitle = try c.decodeIfPresent(String.self, forKey: .sourceTitle) ?? ""
        timestamp = try c.decodeIfPresent(Double.self, forKey: .timestamp)
        kind = try c.decodeIfPresent(StudyItemKind.self, forKey: .kind) ?? .term
        prompt = try c.decode(String.self, forKey: .prompt)
        answer = try c.decodeIfPresent(String.self, forKey: .answer) ?? ""
        keys = try c.decodeIfPresent([String].self, forKey: .keys) ?? []
        choices = try c.decodeIfPresent([String].self, forKey: .choices) ?? []
        correctChoice = try c.decodeIfPresent(Int.self, forKey: .correctChoice)
        concept = try c.decodeIfPresent(String.self, forKey: .concept) ?? ""
        memory = try c.decodeIfPresent(FSRS.Memory.self, forKey: .memory) ?? .unseen
        suspended = try c.decodeIfPresent(Bool.self, forKey: .suspended) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

// MARK: - Review log
//
// One row per answered question. This is what the calibration view reads:
// the confidence rating is taken *before* the answer is revealed, so
// predicted-vs-actual is a real measurement rather than hindsight.

/// The learner's own prediction, collected before they see whether they were
/// right. Students systematically over-rate fluent material (Koriat & Bjork
/// 2005); showing them the gap is what retrains the judgement.
enum Confidence: Int, Codable, CaseIterable, Identifiable, Hashable {
    case noIdea = 0
    case shaky  = 1
    case fairly = 2
    case certain = 3

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .noIdea:  return "No idea"
        case .shaky:   return "Shaky"
        case .fairly:  return "Fairly sure"
        case .certain: return "Certain"
        }
    }

    var symbol: String {
        switch self {
        case .noIdea:  return "questionmark"
        case .shaky:   return "hand.wave"
        case .fairly:  return "hand.thumbsup"
        case .certain: return "checkmark.seal"
        }
    }

    /// What this prediction implies about recall, for calibration scoring.
    var predictedRecall: Double {
        switch self {
        case .noIdea:  return 0.10
        case .shaky:   return 0.40
        case .fairly:  return 0.75
        case .certain: return 0.95
        }
    }
}

struct ReviewLog: Codable, Identifiable, Hashable {
    var id = UUID()
    var itemID: UUID
    var brainID: UUID?
    var reviewedAt = Date()
    var grade: FSRS.Grade
    var confidence: Confidence?
    /// Whether the graded answer counted as a recall. Mirrors `grade.isRecall`
    /// but is stored so an auto-graded verdict survives a manual override.
    var correct: Bool
    var secondsSpent: Double = 0
    var typed: String = ""
    /// Which session this belonged to, for streaks and session summaries.
    var sessionID: UUID?
    /// The item had never been studied before this review. Recorded rather than
    /// derived so the daily new-card limit stays correct across learning steps.
    var wasNew: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, itemID, brainID, reviewedAt, grade, confidence, correct
        case secondsSpent, typed, sessionID, wasNew
    }

    init(itemID: UUID, brainID: UUID?, grade: FSRS.Grade, confidence: Confidence?,
         correct: Bool, secondsSpent: Double, typed: String, sessionID: UUID?,
         wasNew: Bool) {
        self.itemID = itemID
        self.brainID = brainID
        self.grade = grade
        self.confidence = confidence
        self.correct = correct
        self.secondsSpent = secondsSpent
        self.typed = String(typed.prefix(400))
        self.sessionID = sessionID
        self.wasNew = wasNew
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        itemID = try c.decode(UUID.self, forKey: .itemID)
        brainID = try c.decodeIfPresent(UUID.self, forKey: .brainID)
        reviewedAt = try c.decode(Date.self, forKey: .reviewedAt)
        grade = try c.decodeIfPresent(FSRS.Grade.self, forKey: .grade) ?? .good
        confidence = try c.decodeIfPresent(Confidence.self, forKey: .confidence)
        correct = try c.decodeIfPresent(Bool.self, forKey: .correct) ?? true
        secondsSpent = try c.decodeIfPresent(Double.self, forKey: .secondsSpent) ?? 0
        typed = try c.decodeIfPresent(String.self, forKey: .typed) ?? ""
        sessionID = try c.decodeIfPresent(UUID.self, forKey: .sessionID)
        wasNew = try c.decodeIfPresent(Bool.self, forKey: .wasNew) ?? false
    }
}

// MARK: - Exam plan
//
// A date to work backward from. Cepeda et al. (2006) found the best gap
// between study sessions scales with the retention interval — so knowing when
// the exam is genuinely changes the right schedule, not just the urgency.

struct ExamPlan: Codable, Identifiable, Hashable {
    var id = UUID()
    var brainID: UUID
    var title: String
    var date: Date
    /// Minutes the student intends to study per day in the run-up.
    var dailyMinutes: Int = 20
    var createdAt = Date()
    var updatedAt = Date()
    var deleted = false

    init(brainID: UUID, title: String, date: Date, dailyMinutes: Int = 20) {
        self.brainID = brainID
        self.title = title
        self.date = date
        self.dailyMinutes = dailyMinutes
    }

    var daysAway: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now),
                                        to: Calendar.current.startOfDay(for: date)).day ?? 0
    }

    var isPast: Bool { daysAway < 0 }

    var countdownText: String {
        let d = daysAway
        if d < 0 { return "Passed" }
        if d == 0 { return "Today" }
        if d == 1 { return "Tomorrow" }
        if d < 14 { return "\(d) days" }
        return "\(d / 7) weeks"
    }

    /// Retention target that rises as the exam approaches. A test three weeks
    /// out doesn't need 95% recall today; the morning of does.
    var suggestedRetention: Double {
        switch daysAway {
        case ..<0:   return 0.90
        case 0...3:  return 0.95
        case 4...10: return 0.92
        case 11...28: return 0.90
        default:     return 0.88
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, brainID, title, date, dailyMinutes, createdAt, updatedAt, deleted
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        brainID = try c.decode(UUID.self, forKey: .brainID)
        title = try c.decode(String.self, forKey: .title)
        date = try c.decode(Date.self, forKey: .date)
        dailyMinutes = try c.decodeIfPresent(Int.self, forKey: .dailyMinutes) ?? 20
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

// MARK: - Session kinds

/// How a batch of items is being worked through. The scheduling consequences
/// differ: only `review` writes FSRS state on every answer.
enum StudyMode: String, CaseIterable, Identifiable, Hashable {
    /// Today's due queue, interleaved across courses. The main loop.
    case review
    /// Quizlet-style flip cards. Self-graded, still updates the schedule.
    case flashcards
    /// A timed run of questions with a score report at the end, no scheduling
    /// pressure — practice under test conditions.
    case practiceExam
    /// Questions on the concepts the learner has actually been missing.
    case drill

    var id: String { rawValue }

    var title: String {
        switch self {
        case .review:       return "Review"
        case .flashcards:   return "Flashcards"
        case .practiceExam: return "Practice exam"
        case .drill:        return "Drill weak spots"
        }
    }

    var symbol: String {
        switch self {
        case .review:       return "checkmark.circle"
        case .flashcards:   return "rectangle.on.rectangle"
        case .practiceExam: return "doc.text.magnifyingglass"
        case .drill:        return "target"
        }
    }

    var blurb: String {
        switch self {
        case .review:       return "What's due today, mixed across your courses"
        case .flashcards:   return "Flip through terms at your own pace"
        case .practiceExam: return "A timed run, scored at the end"
        case .drill:        return "Only the concepts you keep missing"
        }
    }

    /// Whether answers feed the spaced-repetition schedule.
    var updatesSchedule: Bool { self != .practiceExam }
}

// MARK: - Session summary

struct SessionSummary: Identifiable, Hashable {
    var id = UUID()
    var mode: StudyMode
    var answered: Int
    var correct: Int
    var seconds: Double
    /// Items that were missed, so the summary can offer a drill.
    var missedItemIDs: [UUID]
    /// Mean |predicted − actual| across items the learner rated. Lower is
    /// better-calibrated; nil when they skipped the ratings.
    var calibrationError: Double?

    var accuracy: Double { answered > 0 ? Double(correct) / Double(answered) : 0 }

    var accuracyText: String { "\(Int((accuracy * 100).rounded()))%" }
}
