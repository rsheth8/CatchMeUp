import Foundation

// MARK: - FSRS
//
// The Free Spaced Repetition Scheduler (FSRS-5).
//
// Two numbers describe what a person knows about one item:
//
//   stability  — days until the chance of recalling it falls to 90%
//   difficulty — 1…10, how hard this particular item is for this person
//
// Every review updates both, using the grade *and* how overdue the review was.
// An item recalled after a long gap gains far more stability than the same
// grade on an item reviewed early, which is the whole spacing effect expressed
// as arithmetic.
//
// Why FSRS rather than SM-2: SM-2 multiplies a fixed "ease factor" and ignores
// how overdue a card was. FSRS models the forgetting curve itself, and on
// benchmarks over hundreds of millions of real reviews reaches the same
// retention with roughly 20–30% fewer reviews. It also lets the user state a
// retention *target* (default 90%) instead of guessing at intervals.

enum FSRS {

    // MARK: Grades

    /// What the learner reports after seeing the answer. Values match the FSRS
    /// spec (1…4) and are persisted, so don't renumber them.
    enum Grade: Int, Codable, CaseIterable, Identifiable, Hashable {
        case again = 1
        case hard  = 2
        case good  = 3
        case easy  = 4

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .again: return "Again"
            case .hard:  return "Hard"
            case .good:  return "Got it"
            case .easy:  return "Easy"
            }
        }

        /// Shown under the button so the choice isn't guesswork.
        var blurb: String {
            switch self {
            case .again: return "Couldn't recall"
            case .hard:  return "Recalled, but a struggle"
            case .good:  return "Recalled correctly"
            case .easy:  return "Instant, no effort"
            }
        }

        var symbol: String {
            switch self {
            case .again: return "arrow.counterclockwise"
            case .hard:  return "tortoise"
            case .good:  return "checkmark"
            case .easy:  return "hare"
            }
        }

        var isRecall: Bool { self != .again }

        /// How a graded answer maps onto the button we pre-select for the user.
        static func suggested(fromVerdict verdict: Grading.Verdict) -> Grade {
            switch verdict {
            case .pass:    return .good
            case .partial: return .hard
            case .miss, .blank: return .again
            }
        }
    }

    // MARK: State

    enum State: String, Codable, Hashable {
        /// Never studied.
        case new
        /// In the first-time learning steps (minutes, not days).
        case learning
        /// Graduated — scheduled in days.
        case review
        /// Lapsed out of review and working back through short steps.
        case relearning
    }

    // MARK: Memory

    /// Everything the scheduler knows about one item. Stored on `StudyItem`.
    struct Memory: Codable, Hashable {
        var stability: Double = 0
        var difficulty: Double = 0
        var state: State = .new
        /// Index into the learning / relearning step list.
        var step: Int = 0
        var due: Date = .distantPast
        var lastReviewedAt: Date?
        var reps: Int = 0
        var lapses: Int = 0
        /// The interval we last scheduled, in days. Used for "you were N days late".
        var scheduledDays: Double = 0

        static let unseen = Memory()

        var isNew: Bool { state == .new }

        /// Days since the last review — the input the forgetting curve needs.
        func elapsedDays(at now: Date) -> Double {
            guard let last = lastReviewedAt else { return 0 }
            return max(0, now.timeIntervalSince(last) / 86_400)
        }
    }

    // MARK: Parameters

    struct Parameters: Hashable {
        /// The 19 FSRS-5 weights. Defaults are the published values fitted
        /// across a very large public review corpus; they are a good prior for
        /// a user with no history of their own.
        var w: [Double] = Parameters.defaultWeights

        /// The recall probability the schedule aims for at the moment an item
        /// comes due. Higher = more reviews, better retention.
        var desiredRetention: Double = 0.90

        /// Nothing is ever scheduled further out than this.
        var maximumInterval: Double = 365 * 2

        /// First-time steps, in minutes, before an item graduates to days.
        var learningSteps: [Double] = [1, 10]
        /// Steps after a lapse.
        var relearningSteps: [Double] = [10]

        static let defaultWeights: [Double] = [
            0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046,
            1.54575, 0.1192, 1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315,
            2.9898, 0.51655, 0.6621,
        ]

        static let `default` = Parameters()

        /// Guards against a corrupt or short weight vector loaded from disk.
        var weights: [Double] {
            w.count == Parameters.defaultWeights.count ? w : Parameters.defaultWeights
        }
    }

    // MARK: Forgetting curve

    /// Exponent of the power forgetting curve. FSRS-4.5 onward.
    static let decay: Double = -0.5
    /// Chosen so that `retrievability(t: S, S) == 0.9`.
    static let factor: Double = 19.0 / 81.0

    /// Probability of recalling an item `days` after the last review.
    static func retrievability(stability: Double, elapsedDays days: Double) -> Double {
        guard stability > 0 else { return 0 }
        return pow(1 + factor * days / stability, decay)
    }

    static func retrievability(_ memory: Memory, at now: Date = .now) -> Double {
        guard memory.state != .new, memory.stability > 0 else { return 0 }
        return retrievability(stability: memory.stability, elapsedDays: memory.elapsedDays(at: now))
    }

    /// Days until recall probability decays to `retention`.
    static func interval(stability: Double, retention: Double, maximum: Double) -> Double {
        guard stability > 0 else { return 0 }
        let r = min(max(retention, 0.70), 0.99)
        let days = (stability / factor) * (pow(r, 1 / decay) - 1)
        return min(max(days, 1), maximum)
    }

    // MARK: Scheduling

    /// The next memory state after grading an item. Pure — hand it the old
    /// state and it returns the new one, so it's trivially testable.
    static func schedule(
        _ memory: Memory,
        grade: Grade,
        now: Date = .now,
        params: Parameters = .default
    ) -> Memory {
        var m = memory
        let w = params.weights
        let elapsed = memory.elapsedDays(at: now)

        switch memory.state {
        case .new:
            m.stability = initialStability(grade: grade, w: w)
            m.difficulty = initialDifficulty(grade: grade, w: w)
            m.reps = 1
            m.lastReviewedAt = now
            applyLearningStep(&m, grade: grade, params: params, now: now, steps: params.learningSteps,
                              lapsed: false)

        case .learning, .relearning:
            m.reps += 1
            // Same-day repeats move stability with the short-term formula
            // rather than the full recall/lapse update.
            m.stability = shortTermStability(m.stability, grade: grade, w: w)
            m.difficulty = nextDifficulty(m.difficulty, grade: grade, w: w)
            m.lastReviewedAt = now
            let steps = memory.state == .relearning ? params.relearningSteps : params.learningSteps
            applyLearningStep(&m, grade: grade, params: params, now: now, steps: steps,
                              lapsed: memory.state == .relearning)

        case .review:
            let r = retrievability(stability: memory.stability, elapsedDays: elapsed)
            m.reps += 1
            m.difficulty = nextDifficulty(memory.difficulty, grade: grade, w: w)
            if grade == .again {
                m.lapses += 1
                m.stability = lapseStability(memory.stability, difficulty: memory.difficulty,
                                             retrievability: r, w: w)
                m.lastReviewedAt = now
                if params.relearningSteps.isEmpty {
                    graduate(&m, params: params, now: now)
                } else {
                    m.state = .relearning
                    m.step = 0
                    m.scheduledDays = params.relearningSteps[0] / (24 * 60)
                    m.due = now.addingTimeInterval(params.relearningSteps[0] * 60)
                }
            } else {
                m.stability = recallStability(memory.stability, difficulty: memory.difficulty,
                                              retrievability: r, grade: grade, w: w)
                m.lastReviewedAt = now
                graduate(&m, params: params, now: now)
            }
        }

        m.stability = min(max(m.stability, 0.01), 36_500)
        m.difficulty = min(max(m.difficulty, 1), 10)
        return m
    }

    /// What each button will do, so the UI can show "3d" / "12d" on it before
    /// the user commits. Cheap enough to call for all four grades per card.
    static func preview(
        _ memory: Memory,
        now: Date = .now,
        params: Parameters = .default
    ) -> [Grade: Date] {
        var out: [Grade: Date] = [:]
        for g in Grade.allCases {
            out[g] = schedule(memory, grade: g, now: now, params: params).due
        }
        return out
    }

    // MARK: - Step machinery

    private static func applyLearningStep(
        _ m: inout Memory, grade: Grade, params: Parameters, now: Date,
        steps: [Double], lapsed: Bool
    ) {
        guard !steps.isEmpty else { graduate(&m, params: params, now: now); return }

        switch grade {
        case .again:
            m.state = lapsed ? .relearning : .learning
            m.step = 0
            schedule(&m, minutes: steps[0], from: now)

        case .hard:
            m.state = lapsed ? .relearning : .learning
            // Stay on this step; halfway to the next one if there is one.
            let here = steps[min(m.step, steps.count - 1)]
            let next = m.step + 1 < steps.count ? steps[m.step + 1] : here * 1.5
            schedule(&m, minutes: (here + next) / 2, from: now)

        case .good:
            let next = m.step + 1
            if next < steps.count {
                m.state = lapsed ? .relearning : .learning
                m.step = next
                schedule(&m, minutes: steps[next], from: now)
            } else {
                graduate(&m, params: params, now: now)
            }

        case .easy:
            graduate(&m, params: params, now: now)
        }
    }

    private static func schedule(_ m: inout Memory, minutes: Double, from now: Date) {
        m.scheduledDays = minutes / (24 * 60)
        m.due = now.addingTimeInterval(minutes * 60)
    }

    private static func graduate(_ m: inout Memory, params: Parameters, now: Date) {
        m.state = .review
        m.step = 0
        let days = interval(stability: m.stability,
                            retention: params.desiredRetention,
                            maximum: params.maximumInterval)
        let whole = max(1, days.rounded())
        m.scheduledDays = whole
        m.due = Calendar.current.date(byAdding: .day, value: Int(whole), to: now) ?? now
    }

    // MARK: - The model

    private static func initialStability(grade: Grade, w: [Double]) -> Double {
        max(0.1, w[grade.rawValue - 1])
    }

    private static func initialDifficulty(grade: Grade, w: [Double]) -> Double {
        clampDifficulty(w[4] - exp(w[5] * Double(grade.rawValue - 1)) + 1)
    }

    private static func nextDifficulty(_ d: Double, grade: Grade, w: [Double]) -> Double {
        // Linear damping: a hard item can't be made much harder, an easy one
        // can't be made much easier.
        let delta = -w[6] * Double(grade.rawValue - 3)
        let damped = d + delta * (10 - d) / 9
        // Mean reversion toward the difficulty an "easy" first answer implies,
        // so long-lived items drift back to the middle instead of saturating.
        let target = initialDifficulty(grade: .easy, w: w)
        return clampDifficulty(w[7] * target + (1 - w[7]) * damped)
    }

    private static func recallStability(
        _ s: Double, difficulty d: Double, retrievability r: Double, grade: Grade, w: [Double]
    ) -> Double {
        let hardPenalty = grade == .hard ? w[15] : 1
        let easyBonus   = grade == .easy ? w[16] : 1
        let growth = exp(w[8])
            * (11 - d)
            * pow(s, -w[9])
            * (exp((1 - r) * w[10]) - 1)
            * hardPenalty
            * easyBonus
        return s * (1 + growth)
    }

    private static func lapseStability(
        _ s: Double, difficulty d: Double, retrievability r: Double, w: [Double]
    ) -> Double {
        let long = w[11] * pow(d, -w[12]) * (pow(s + 1, w[13]) - 1) * exp((1 - r) * w[14])
        // FSRS-5 caps post-lapse stability with the short-term term so a lapse
        // can never leave an item *more* stable than it was.
        let ceiling = s / exp(w[17] * w[18])
        return max(0.01, min(long, ceiling))
    }

    private static func shortTermStability(_ s: Double, grade: Grade, w: [Double]) -> Double {
        guard s > 0 else { return s }
        return s * exp(w[17] * (Double(grade.rawValue) - 3 + w[18]))
    }

    private static func clampDifficulty(_ d: Double) -> Double { min(max(d, 1), 10) }
}

// MARK: - Display helpers

extension FSRS {
    /// "10m", "2d", "3wk", "5mo" — what goes on the grade buttons.
    static func intervalText(from now: Date, to due: Date) -> String {
        let seconds = due.timeIntervalSince(now)
        if seconds < 60 { return "<1m" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(Int(minutes.rounded()))m" }
        let hours = minutes / 60
        if hours < 24 { return "\(Int(hours.rounded()))h" }
        let days = hours / 24
        if days < 7 { return "\(Int(days.rounded()))d" }
        if days < 30 { return "\(Int((days / 7).rounded()))wk" }
        if days < 365 { return "\(Int((days / 30).rounded()))mo" }
        return String(format: "%.1fyr", days / 365)
    }
}
