import Foundation
import Observation

// MARK: - StudyStore
//
// Owns the question bank, the schedule and the review history. Persists the
// same way `LibraryStore` does — JSON in Application Support, or the iCloud
// container when sync is on — so a schedule follows the user between devices.
//
// The store never renders anything and never decides *what a question says*;
// `QuestionMint` writes questions, `FSRS` decides when they come back, and this
// keeps the books.

/// What the library needs from the question bank when a recap is deleted or
/// filed somewhere else.
///
/// A protocol rather than a direct reference so `LibraryStore` — which predates
/// studying and works fine without it — doesn't have to know what a `StudyStore`
/// is. It just reports that something moved.
@MainActor
protocol StudyItemSink: AnyObject {
    func deleteItems(forRecording id: UUID)
    func reassign(recordingID: UUID, toBrain brainID: UUID?)
}

@MainActor
@Observable
final class StudyStore: StudyItemSink {
    /// One bank per process, for the same reason as `LibraryStore.shared`: a
    /// recap can finish in a `BGProcessingTask` with no view tree anywhere, and
    /// its questions have to be written by whoever finishes it.
    static let shared = StudyStore()

    /// Includes tombstones; use the filtered accessors.
    private(set) var items: [StudyItem] = []
    private(set) var logs: [ReviewLog] = []
    private(set) var examPlans: [ExamPlan] = []

    /// Set while a background mint is running, so the UI can say so.
    private(set) var isMinting = false

    private let localDir: URL
    private let itemsName = "study-items.json"
    private let logsName = "study-log.json"
    private let plansName = "exam-plans.json"

    /// Review history is append-only and small per row, but it's the input to
    /// every stat in the app. Cap it so a heavy user's file stays sane.
    private let maxLogs = 20_000

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        localDir = support.appendingPathComponent("CatchMeUp", isDirectory: true)
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: - Where data lives
    //
    // Resolved per access rather than cached: the user can flip iCloud sync at
    // any time, and this has to follow `LibraryStore` to the same folder.

    private var dataDir: URL {
        if UserDefaults.standard.bool(forKey: "iCloudSync"), let cloud = CloudSync.documentsURL {
            return cloud
        }
        return localDir
    }

    private var itemsFile: URL { dataDir.appendingPathComponent(itemsName) }
    private var logsFile: URL { dataDir.appendingPathComponent(logsName) }
    private var plansFile: URL { dataDir.appendingPathComponent(plansName) }

    // MARK: - Queries

    var liveItems: [StudyItem] { items.filter { !$0.deleted } }

    var activeItems: [StudyItem] { items.filter { !$0.deleted && !$0.suspended } }

    func item(_ id: UUID) -> StudyItem? { items.first { $0.id == id && !$0.deleted } }

    func items(forRecording id: UUID) -> [StudyItem] {
        items.filter { $0.recordingID == id && !$0.deleted }
    }

    func items(inBrain id: UUID?) -> [StudyItem] {
        activeItems.filter { $0.brainID == id }
    }

    var plans: [ExamPlan] {
        examPlans.filter { !$0.deleted }.sorted { $0.date < $1.date }
    }

    func plan(forBrain id: UUID) -> ExamPlan? {
        plans.first { $0.brainID == id && !$0.isPast }
    }

    /// The soonest upcoming exam, which is what the dashboard leads with.
    var nextExam: ExamPlan? { plans.first { !$0.isPast } }

    // MARK: - Counts

    func dueCount(brainID: UUID? = nil, at now: Date = .now) -> Int {
        activeItems.filter {
            (brainID == nil || $0.brainID == brainID) && !$0.isNew && $0.memory.due <= now
        }.count
    }

    func newCount(brainID: UUID? = nil) -> Int {
        activeItems.filter { (brainID == nil || $0.brainID == brainID) && $0.isNew }.count
    }

    /// New items already introduced today, against the daily cap.
    func newIntroducedToday(at now: Date = .now) -> Int {
        let start = Calendar.current.startOfDay(for: now)
        var counted = Set<UUID>()
        for log in logs where log.wasNew && log.reviewedAt >= start {
            counted.insert(log.itemID)
        }
        return counted.count
    }

    /// Everything today actually asks for: reviews that have come due, plus as
    /// much new material as the daily cap still allows.
    ///
    /// The tab badge and the Study card both read this. They used to compute it
    /// separately — `dueCount` deliberately excludes new items — so a fresh
    /// library showed "Due today 10" under a tab with no badge at all.
    func todayCount(brainID: UUID? = nil, newLimit: Int, at now: Date = .now) -> Int {
        let room = max(0, newLimit - newIntroducedToday(at: now))
        return dueCount(brainID: brainID, at: now)
            + min(newCount(brainID: brainID), room)
    }

    func reviewsToday(at now: Date = .now) -> Int {
        let start = Calendar.current.startOfDay(for: now)
        return logs.filter { $0.reviewedAt >= start }.count
    }

    /// Consecutive days ending today (or yesterday, if today hasn't started yet)
    /// on which at least one review happened.
    var streak: Int {
        let cal = Calendar.current
        let days = Set(logs.map { cal.startOfDay(for: $0.reviewedAt) })
        guard !days.isEmpty else { return 0 }

        var cursor = cal.startOfDay(for: .now)
        // A streak isn't broken until today ends, so start from yesterday when
        // nothing has been reviewed yet today.
        if !days.contains(cursor) {
            guard let yesterday = cal.date(byAdding: .day, value: -1, to: cursor),
                  days.contains(yesterday) else { return 0 }
            cursor = yesterday
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            guard let previous = cal.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    // MARK: - The due queue
    //
    // Interleaved by construction. Blocked practice — all of one course, then
    // all of the next — feels more organised and produces worse discrimination
    // (Brunmair & Richter 2019), so the queue round-robins across courses and
    // avoids putting two questions on the same concept back to back.

    /// `recordingID` narrows the queue to a single recap — what "practise this
    /// lecture" means. It deliberately doesn't change the ordering rules: even
    /// one recap's questions are still interleaved by concept.
    func queue(mode: StudyMode, brainID: UUID? = nil, recordingID: UUID? = nil,
               limit: Int, newLimit: Int = 12, at now: Date = .now) -> [StudyItem] {
        let pool = activeItems.filter {
            (brainID == nil || $0.brainID == brainID)
                && (recordingID == nil || $0.recordingID == recordingID)
        }
        switch mode {
        case .review:
            return reviewQueue(pool, limit: limit, newLimit: newLimit, now: now)
        case .flashcards:
            return flashcardQueue(pool, limit: limit, now: now)
        case .practiceExam:
            return examQueue(pool, limit: limit)
        case .drill:
            return drillQueue(pool, limit: limit)
        }
    }

    private func reviewQueue(_ pool: [StudyItem], limit: Int, newLimit: Int, now: Date) -> [StudyItem] {
        // Overdue first, most overdue leading — those are the ones actually
        // decaying. Within that, oldest due date wins.
        let due = pool
            .filter { !$0.isNew && $0.memory.due <= now }
            .sorted { $0.memory.due < $1.memory.due }

        let roomForNew = max(0, newLimit - newIntroducedToday(at: now))
        let fresh = pool
            .filter(\.isNew)
            .sorted { $0.createdAt < $1.createdAt }
            .prefix(roomForNew)

        // New items are salted through the due work rather than front-loaded,
        // so a session doesn't open with a wall of unfamiliar material.
        return interleave(Array(due) + Array(fresh), limit: limit)
    }

    private func flashcardQueue(_ everything: [StudyItem], limit: Int, now: Date) -> [StudyItem] {
        // Multiple choice has nothing to flip.
        let pool = everything.filter { $0.kind != .choice }
        // Due work first so flipping cards still advances the schedule, then
        // whatever is closest to falling below the retention target.
        let ordered = pool.sorted { a, b in
            let ra = FSRS.retrievability(a.memory, at: now)
            let rb = FSRS.retrievability(b.memory, at: now)
            if a.isNew != b.isNew { return b.isNew }
            return ra < rb
        }
        return interleave(ordered, limit: limit)
    }

    private func examQueue(_ pool: [StudyItem], limit: Int) -> [StudyItem] {
        guard !pool.isEmpty else { return [] }

        // A practice exam should look like an exam: a spread of question types,
        // weighted toward what the learner is weakest on.
        let weak = weaknessScores()
        let ranked = pool.sorted { a, b in
            (weak[a.concept] ?? 0) > (weak[b.concept] ?? 0)
        }
        let focus = ranked.prefix(max(1, limit * 2 / 3))
        let rest = ranked.dropFirst(focus.count).shuffled()
        return interleave(Array(focus).shuffled() + Array(rest), limit: limit)
    }

    private func drillQueue(_ everything: [StudyItem], limit: Int) -> [StudyItem] {
        let weak = weaknessScores()
        let pool = everything
            .filter { (weak[$0.concept] ?? 0) > 0 }
            .sorted { (weak[$0.concept] ?? 0) > (weak[$1.concept] ?? 0) }
        return interleave(pool, limit: limit)
    }

    /// Round-robins across courses and keeps same-concept questions apart.
    private func interleave(_ items: [StudyItem], limit: Int) -> [StudyItem] {
        guard limit > 0, !items.isEmpty else { return [] }

        var buckets: [UUID?: [StudyItem]] = [:]
        var order: [UUID?] = []
        for item in items {
            if buckets[item.brainID] == nil { order.append(item.brainID) }
            buckets[item.brainID, default: []].append(item)
        }

        var out: [StudyItem] = []
        var cursor = 0
        var lastConcept = ""
        var stalled = 0

        while out.count < limit, stalled < order.count {
            let key = order[cursor % order.count]
            cursor += 1
            guard var bucket = buckets[key], !bucket.isEmpty else { stalled += 1; continue }
            stalled = 0

            // Prefer the first item that isn't another take on what we just
            // asked; fall back to the head if that's all that's left.
            let pick = bucket.firstIndex { $0.concept != lastConcept } ?? 0
            let item = bucket.remove(at: pick)
            buckets[key] = bucket
            lastConcept = item.concept
            out.append(item)
        }
        return out
    }

    // MARK: - Weakness
    //
    // Recency-weighted misses per concept, ported from `exam.py`. Drives the
    // drill queue and the "worth another look" list.

    func weaknessScores() -> [String: Double] {
        var scores: [String: Double] = [:]
        let recent = logs.suffix(600)
        guard !recent.isEmpty else { return [:] }
        let byItem = Dictionary(uniqueKeysWithValues: liveItems.map { ($0.id, $0.concept) })

        for (index, log) in recent.enumerated() {
            guard let concept = byItem[log.itemID], !concept.isEmpty else { continue }
            // Later reviews count for more, so a concept you've since fixed
            // fades out of the drill instead of haunting it.
            let recency = 0.5 + Double(index) / Double(max(1, recent.count))
            let delta: Double
            switch log.grade {
            case .again: delta = 1.0
            case .hard:  delta = 0.45
            case .good:  delta = -0.25
            case .easy:  delta = -0.4
            }
            scores[concept, default: 0] += delta * recency
        }
        return scores.filter { $0.value > 0 }
    }

    /// The concepts most worth drilling, with how many times they were missed.
    func weakConcepts(limit: Int = 8) -> [(concept: String, score: Double, misses: Int)] {
        let scores = weaknessScores()
        guard !scores.isEmpty else { return [] }
        let byItem = Dictionary(uniqueKeysWithValues: liveItems.map { ($0.id, $0.concept) })
        var misses: [String: Int] = [:]
        for log in logs where !log.correct {
            if let concept = byItem[log.itemID] { misses[concept, default: 0] += 1 }
        }
        return scores
            .sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (concept: $0.key, score: $0.value, misses: misses[$0.key] ?? 0) }
    }

    // MARK: - Calibration
    //
    // How far the learner's confidence sits from their actual recall. This is
    // the number that makes the fluency illusion visible.

    struct Calibration: Hashable {
        var rated: Int
        /// Mean predicted recall across rated answers.
        var predicted: Double
        /// Share actually recalled.
        var actual: Double
        /// Positive = overconfident.
        var gap: Double { predicted - actual }

        var isMeaningful: Bool { rated >= 10 }

        var verdict: String {
            guard isMeaningful else { return "Rate a few more answers to see this" }
            switch gap {
            case ..<(-0.12): return "You know more than you think"
            case (-0.12)..<0.08: return "Well calibrated"
            case 0.08..<0.2: return "Slightly overconfident"
            default: return "Overconfident — trust the quiz, not the feeling"
            }
        }
    }

    func calibration(brainID: UUID? = nil, days: Int = 60) -> Calibration {
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: .now) ?? .distantPast
        let rated = logs.filter {
            $0.confidence != nil && $0.reviewedAt >= cutoff
                && (brainID == nil || $0.brainID == brainID)
        }
        guard !rated.isEmpty else { return Calibration(rated: 0, predicted: 0, actual: 0) }
        let predicted = rated.reduce(0.0) { $0 + ($1.confidence?.predictedRecall ?? 0) }
            / Double(rated.count)
        let actual = Double(rated.filter(\.correct).count) / Double(rated.count)
        return Calibration(rated: rated.count, predicted: predicted, actual: actual)
    }

    /// Rolling accuracy, for the dashboard sparkline.
    func accuracyByDay(days: Int = 14) -> [(day: Date, total: Int, correct: Int)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        return (0..<days).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let next = cal.date(byAdding: .day, value: 1, to: day) ?? day
            let inDay = logs.filter { $0.reviewedAt >= day && $0.reviewedAt < next }
            return (day: day, total: inDay.count, correct: inDay.filter(\.correct).count)
        }
    }

    // MARK: - Recording a review

    /// Applies a grade: updates the schedule, appends the log, saves. Returns
    /// the item's new memory so the caller can show the next interval.
    @discardableResult
    func record(_ itemID: UUID, grade: FSRS.Grade, confidence: Confidence?,
                correct: Bool, seconds: Double, typed: String, sessionID: UUID?,
                params: FSRS.Parameters, updatesSchedule: Bool = true) -> FSRS.Memory? {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }

        let wasNew = items[index].memory.isNew
        if updatesSchedule {
            items[index].memory = FSRS.schedule(items[index].memory, grade: grade, params: params)
            items[index].updatedAt = Date()
        }

        logs.append(ReviewLog(itemID: itemID, brainID: items[index].brainID, grade: grade,
                              confidence: confidence, correct: correct, secondsSpent: seconds,
                              typed: typed, sessionID: sessionID, wasNew: wasNew))
        if logs.count > maxLogs { logs.removeFirst(logs.count - maxLogs) }

        saveItems()
        saveLogs()
        return items[index].memory
    }

    /// Retention target for an item, raised when its course has an exam close.
    func parameters(for item: StudyItem, base: FSRS.Parameters) -> FSRS.Parameters {
        guard let brainID = item.brainID, let plan = plan(forBrain: brainID) else { return base }
        var params = base
        params.desiredRetention = max(base.desiredRetention, plan.suggestedRetention)
        return params
    }

    // MARK: - Item lifecycle

    func setSuspended(_ itemID: UUID, _ suspended: Bool) {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[i].suspended = suspended
        items[i].updatedAt = Date()
        saveItems()
    }

    /// Puts an item back to never-studied, keeping the question.
    func reset(_ itemID: UUID) {
        guard let i = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[i].memory = .unseen
        items[i].updatedAt = Date()
        saveItems()
    }

    func add(_ newItems: [StudyItem]) {
        guard !newItems.isEmpty else { return }
        let existing = Set(liveItems.map { conceptKey($0) })
        let fresh = newItems.filter { !existing.contains(conceptKey($0)) }
        guard !fresh.isEmpty else { return }
        items.append(contentsOf: fresh)
        saveItems()
    }

    /// Items are scoped per course, so the same term taught in two different
    /// courses is two different things to learn.
    private func conceptKey(_ item: StudyItem) -> String {
        "\(item.brainID?.uuidString ?? "-")|\(item.concept)"
    }

    /// Questions outlive the screen that made them, so the library has to tell
    /// the bank when a recap moves or goes away. Without this, deleting a recap
    /// leaves its questions in tomorrow's queue pointing at a source that no
    /// longer exists.
    func deleteItems(forRecording id: UUID) {
        var changed = false
        for i in items.indices where items[i].recordingID == id && !items[i].deleted {
            items[i].deleted = true
            items[i].updatedAt = Date()
            changed = true
        }
        if changed { saveItems() }
    }

    /// Follows a recap when it's moved to a different course.
    func reassign(recordingID: UUID, toBrain brainID: UUID?) {
        var changed = false
        for i in items.indices where items[i].recordingID == recordingID && items[i].brainID != brainID {
            items[i].brainID = brainID
            items[i].updatedAt = Date()
            changed = true
        }
        if changed { saveItems() }
    }

    // MARK: - Minting

    /// Recaps that are finished but have no questions yet.
    func recordingsNeedingItems(_ recordings: [Recording]) -> [Recording] {
        let covered = Set(liveItems.map(\.recordingID))
        return recordings.filter { $0.isProcessed && !covered.contains($0.id) }
    }

    /// Builds the offline question bank for any recap that lacks one. Cheap and
    /// synchronous — this is pure text processing.
    @discardableResult
    func mintOffline(for recordings: [Recording]) -> Int {
        let pending = recordingsNeedingItems(recordings)
        guard !pending.isEmpty else { return 0 }
        var minted: [StudyItem] = []
        for recording in pending {
            minted += QuestionMint.items(for: recording)
        }
        // Multiple-choice needs a pool of sibling terms to draw distractors
        // from, so it's built per course rather than per recap.
        let byBrain = Dictionary(grouping: pending, by: { $0.brainID })
        for (_, group) in byBrain where group.count >= 1 {
            minted += QuestionMint.choiceItems(from: group, limit: 8 * group.count)
        }
        add(minted)
        return minted.count
    }

    /// Rebuilds one recap's questions against the notes it has *now*.
    ///
    /// Called when the processing queue finishes a recording — first pass or a
    /// rewrite. A rewrite replaces the notes wholesale, so questions minted from
    /// the old text can be about something the recap no longer says; those are
    /// dropped. Anything the user has actually answered is kept, schedule and
    /// all: throwing away review history to tidy up a question bank is the one
    /// thing spaced repetition can't recover from, and a stale question you've
    /// seen twice is a smaller cost than resetting its interval to zero.
    /// `library` is only there to give multiple-choice somewhere to find
    /// plausible distractors — sibling terms from the same course.
    @discardableResult
    func refreshItems(for recording: Recording, in library: [Recording]) -> Int {
        guard recording.isProcessed else { return 0 }

        var dropped = false
        for i in items.indices
        where items[i].recordingID == recording.id
            && !items[i].deleted
            && items[i].memory.reps == 0 {
            items[i].deleted = true
            items[i].updatedAt = Date()
            dropped = true
        }
        if dropped { saveItems() }

        var minted = QuestionMint.items(for: recording)
        let siblings = library.filter { $0.brainID == recording.brainID && $0.isProcessed }
        if siblings.count > 1 {
            minted += QuestionMint.choiceItems(from: siblings, limit: 8 * siblings.count)
        }
        // `add` drops anything whose concept is already live, so a rewrite that
        // says the same thing about a term you've studied changes nothing.
        let before = liveItems.count
        add(minted)
        return liveItems.count - before
    }

    /// Adds the model-written application questions on top. Safe to call
    /// repeatedly; does nothing without a working provider config.
    func enrich(_ recordings: [Recording], config: ProviderConfig) async {
        guard !config.apiKey.isEmpty || config.baseURL?.contains("localhost") == true else { return }
        guard !isMinting else { return }
        isMinting = true
        defer { isMinting = false }

        let enriched = Set(liveItems.filter { $0.kind == .application }.map(\.recordingID))
        let targets = recordings
            .filter { $0.isProcessed && !enriched.contains($0.id) }
            .prefix(3)

        for recording in targets {
            let existing = items(forRecording: recording.id)
            let extra = await QuestionMint.enrich(recording, existing: existing, config: config)
            if !extra.isEmpty { add(extra) }
        }
    }

    // MARK: - Exam plans

    func upsert(_ plan: ExamPlan) {
        var p = plan
        p.updatedAt = Date()
        if let i = examPlans.firstIndex(where: { $0.id == p.id }) { examPlans[i] = p }
        else { examPlans.append(p) }
        savePlans()
    }

    func delete(_ plan: ExamPlan) {
        guard let i = examPlans.firstIndex(where: { $0.id == plan.id }) else { return }
        examPlans[i].deleted = true
        examPlans[i].updatedAt = Date()
        savePlans()
    }

    /// How much daily work the plan implies: everything in the course, spread
    /// over the days remaining, with a floor so it never says "0 a day".
    func dailyTarget(for plan: ExamPlan) -> Int {
        let total = items(inBrain: plan.brainID).count
        guard total > 0 else { return 0 }
        let days = max(1, plan.daysAway)
        return max(5, Int((Double(total) / Double(days)).rounded(.up)))
    }

    // MARK: - Persistence

    private static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private func load() {
        let dec = Self.makeDecoder()
        if let d = coordinatedRead(itemsFile), let v = try? dec.decode([StudyItem].self, from: d) {
            items = v
        }
        if let d = coordinatedRead(logsFile), let v = try? dec.decode([ReviewLog].self, from: d) {
            logs = v.sorted { $0.reviewedAt < $1.reviewedAt }
        }
        if let d = coordinatedRead(plansFile), let v = try? dec.decode([ExamPlan].self, from: d) {
            examPlans = v
        }
    }

    private func saveItems() { write(items, to: itemsFile) }
    private func saveLogs()  { write(logs, to: logsFile) }
    private func savePlans() { write(examPlans, to: plansFile) }

    private func write<T: Encodable>(_ value: T, to url: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(value) else { return }
        var err: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &err) { u in
            try? data.write(to: u, options: .atomic)
        }
    }

    private func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var err: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &err) { u in
            result = try? Data(contentsOf: u)
        }
        return result
    }

    // MARK: - Merge (iCloud brought us someone else's copy)

    func mergeFromDisk() {
        let dec = Self.makeDecoder()
        var changed = false

        if let d = coordinatedRead(itemsFile),
           let incoming = try? dec.decode([StudyItem].self, from: d) {
            let merged = Self.mergeNewest(local: items, remote: incoming,
                                          id: { $0.id }, newer: { $0.updatedAt })
            if Set(merged) != Set(items) { items = merged; changed = true }
        }
        if let d = coordinatedRead(plansFile),
           let incoming = try? dec.decode([ExamPlan].self, from: d) {
            let merged = Self.mergeNewest(local: examPlans, remote: incoming,
                                          id: { $0.id }, newer: { $0.updatedAt })
            if Set(merged) != Set(examPlans) { examPlans = merged; changed = true }
        }
        // Reviews are historical events — union them, never overwrite. Two
        // devices studying offline should end up with both sets.
        if let d = coordinatedRead(logsFile),
           let incoming = try? dec.decode([ReviewLog].self, from: d) {
            var byID = Dictionary(logs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for log in incoming where byID[log.id] == nil { byID[log.id] = log }
            if byID.count != logs.count {
                logs = byID.values.sorted { $0.reviewedAt < $1.reviewedAt }
                if logs.count > maxLogs { logs.removeFirst(logs.count - maxLogs) }
                changed = true
            }
        }

        if changed { saveItems(); saveLogs(); savePlans() }
    }

    private static func mergeNewest<E: Hashable>(
        local: [E], remote: [E], id: (E) -> UUID, newer: (E) -> Date
    ) -> [E] {
        var byID: [UUID: E] = [:]
        for e in local { byID[id(e)] = e }
        for e in remote {
            if let existing = byID[id(e)] {
                if newer(e) >= newer(existing) { byID[id(e)] = e }
            } else {
                byID[id(e)] = e
            }
        }
        return Array(byID.values)
    }
}
