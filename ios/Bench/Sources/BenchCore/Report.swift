import Foundation

// MARK: - Pass bar

/// Written down before looking at results, so "good enough" isn't decided after
/// seeing which way the numbers fell. Edit criteria.json to change the bar.
struct Criteria: Codable, Equatable {
    /// The engine being evaluated for adoption.
    var candidate = "apple"
    /// What it would replace.
    var baseline = "haiku"
    /// Share of recordings the candidate may fail to produce notes for.
    var maxFailureRate = 0.05
    /// Speaker names in the notes that are not in the transcript. Zero tolerance.
    var maxInventedNames = 0
    /// Bookmarks that must land on a real moment of the recording.
    var minBookmarkGroundedRate = 0.95
    /// Fact coverage as a share of the baseline's coverage.
    var minFactCoverageVsBaseline = 0.85
    /// How far the candidate's mean judge score may trail the baseline's (1-5 scale).
    var maxJudgeDeficit = 0.5
    /// (wins + half of ties) / comparisons against the baseline in blind pairwise judging.
    var minPairwiseScore = 0.40
    /// Extra share of numbers not found in the transcript, over the baseline's.
    var maxUnsupportedNumberExcess = 0.05

    static func load(from url: URL?) throws -> Criteria {
        guard let url else { return Criteria() }
        return try JSONDecoder().decode(Criteria.self, from: Data(contentsOf: url))
    }
}

// MARK: - Summaries

struct EngineSummary {
    var label: String
    var model: String
    var runs = 0
    var failures = 0
    var secondsSamples: [Double] = []
    var totalCost: Double?
    var inputTokens = 0
    var outputTokens = 0

    var bookmarks = 0
    var bookmarksSeekable = 0
    var bookmarksGrounded = 0
    var inventedNames = 0
    var forbiddenNameHits = 0
    var nameClashes = 0
    var numbersChecked = 0
    var numbersUnsupported = 0
    var factsTotal = 0
    var factsFound = 0
    var emptyCore = 0
    var words: [Double] = []

    var faithfulness: [Double] = []
    var completeness: [Double] = []
    var usefulness: [Double] = []

    var failureRate: Double { runs == 0 ? 0 : Double(failures) / Double(runs) }
    var succeeded: Int { runs - failures }
    var medianSeconds: Double? { Stats.median(secondsSamples) }
    var groundedRate: Double? { bookmarks == 0 ? nil : Double(bookmarksGrounded) / Double(bookmarks) }
    var seekableRate: Double? { bookmarks == 0 ? nil : Double(bookmarksSeekable) / Double(bookmarks) }
    var unsupportedNumberRate: Double? { numbersChecked == 0 ? nil : Double(numbersUnsupported) / Double(numbersChecked) }
    var factCoverage: Double? { factsTotal == 0 ? nil : Double(factsFound) / Double(factsTotal) }
    var judgeMean: Double? {
        let all = faithfulness + completeness + usefulness
        return all.isEmpty ? nil : Stats.mean(all)
    }
    var costPerRecording: Double? { totalCost.map { runs == 0 ? 0 : $0 / Double(runs) } }
}

struct PairTally {
    var a: String
    var b: String
    var aWins = 0
    var bWins = 0
    var ties = 0
    var comparisons: Int { aWins + bWins + ties }
    /// Credit for `a`: a win is 1, a tie is a half.
    var aScore: Double? { comparisons == 0 ? nil : (Double(aWins) + 0.5 * Double(ties)) / Double(comparisons) }
    var bScore: Double? { aScore.map { 1 - $0 } }
}

struct CriterionResult {
    var name: String
    /// nil when there isn't enough data to decide.
    var passed: Bool?
    var detail: String
}

enum Stats {
    static func mean(_ xs: [Double]) -> Double { xs.isEmpty ? 0 : xs.reduce(0, +) / Double(xs.count) }
    static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

// MARK: - Aggregation

struct Report {
    var summaries: [String: EngineSummary] = [:]
    var order: [String] = []
    var byBucket: [LengthBucket: [String: EngineSummary]] = [:]
    var pairs: [PairTally] = []
    var recordings = 0
    var judged = false
    var criteria: Criteria
    var perRecording: [(id: String, bucket: LengthBucket, rows: [(engine: String, run: RunRecord, metrics: RecapMetrics?, judge: AbsoluteJudgment?)])] = []

    init(runs: [RunRecord], absolute: [AbsoluteJudgment], pairsJudged: [PairJudgment], corpus: [CorpusItem], criteria: Criteria) {
        self.criteria = criteria
        let items = Dictionary(uniqueKeysWithValues: corpus.map { ($0.id, $0) })
        let known = runs.filter { items[$0.transcriptId] != nil }
        recordings = Set(known.map(\.transcriptId)).count
        judged = !absolute.isEmpty || !pairsJudged.isEmpty

        func ingest(_ run: RunRecord, into s: inout EngineSummary, item: CorpusItem) {
            s.runs += 1
            s.model = run.model
            s.inputTokens += run.inputTokens
            s.outputTokens += run.outputTokens
            if let c = run.costUSD { s.totalCost = (s.totalCost ?? 0) + c }
            guard run.ok, let recap = run.recap else { s.failures += 1; return }
            s.secondsSamples.append(run.seconds)
            let m = RecapAnalysis.metrics(for: recap, item: item)
            s.bookmarks += m.bookmarks
            s.bookmarksSeekable += m.bookmarksSeekable
            s.bookmarksGrounded += m.bookmarksGrounded
            s.inventedNames += m.inventedSpeakerNames.count
            s.forbiddenNameHits += m.forbiddenNameHits.count
            s.nameClashes += m.speakerNameClashes.count
            s.numbersChecked += m.numbersChecked
            s.numbersUnsupported += m.numbersUnsupported
            s.factsTotal += m.factsTotal
            s.factsFound += m.factsFound
            if m.emptyCore { s.emptyCore += 1 }
            s.words.append(Double(m.words))
        }

        for run in known {
            guard let item = items[run.transcriptId] else { continue }
            if !order.contains(run.engine) { order.append(run.engine) }
            var s = summaries[run.engine] ?? EngineSummary(label: run.engine, model: run.model)
            ingest(run, into: &s, item: item)
            summaries[run.engine] = s

            var bucket = byBucket[item.bucket] ?? [:]
            var bs = bucket[run.engine] ?? EngineSummary(label: run.engine, model: run.model)
            ingest(run, into: &bs, item: item)
            bucket[run.engine] = bs
            byBucket[item.bucket] = bucket
        }
        order.sort { Report.rank($0) < Report.rank($1) }

        for j in absolute {
            guard var s = summaries[j.engine] else { continue }
            s.faithfulness.append(Double(j.faithfulness))
            s.completeness.append(Double(j.completeness))
            s.usefulness.append(Double(j.usefulness))
            summaries[j.engine] = s
        }

        // Pairwise: a winner counts only if it wins in both presentation orders.
        var grouped: [String: [PairJudgment]] = [:]
        for p in pairsJudged {
            let names = [p.first, p.second].sorted()
            grouped["\(p.transcriptId)|\(names[0])|\(names[1])", default: []].append(p)
        }
        var tallies: [String: PairTally] = [:]
        for (key, group) in grouped {
            let parts = key.split(separator: "|").map(String.init)
            let (x, y) = (parts[1], parts[2])
            let winners = Set(group.map { $0.winnerEngine ?? "tie" })
            var tally = tallies["\(x)|\(y)"] ?? PairTally(a: x, b: y)
            if winners == [x] { tally.aWins += 1 } else if winners == [y] { tally.bWins += 1 } else { tally.ties += 1 }
            tallies["\(x)|\(y)"] = tally
        }
        pairs = tallies.values.sorted { ($0.a, $0.b) < ($1.a, $1.b) }

        // Per-recording detail for the appendix.
        let judgeIndex = Dictionary(uniqueKeysWithValues: absolute.map { ("\($0.transcriptId)|\($0.engine)", $0) })
        let grouping = Dictionary(grouping: known, by: \.transcriptId)
        for id in grouping.keys.sorted() {
            guard let item = items[id] else { continue }
            let rows = (grouping[id] ?? []).sorted { Report.rank($0.engine) < Report.rank($1.engine) }.map { run in
                (engine: run.engine, run: run,
                 metrics: run.recap.map { RecapAnalysis.metrics(for: $0, item: item) },
                 judge: judgeIndex["\(id)|\(run.engine)"])
            }
            perRecording.append((id: id, bucket: item.bucket, rows: rows))
        }
    }

    static func rank(_ engine: String) -> Int {
        ["apple": 0, "haiku": 1, "strong": 2][engine] ?? 3
    }

    // MARK: Verdict

    func evaluate() -> [CriterionResult] {
        guard let cand = summaries[criteria.candidate] else {
            return [CriterionResult(name: "Candidate present", passed: nil, detail: "No runs for '\(criteria.candidate)'.")]
        }
        let base = summaries[criteria.baseline]
        var out: [CriterionResult] = []

        out.append(CriterionResult(
            name: "Failure rate", passed: cand.runs == 0 ? nil : cand.failureRate <= criteria.maxFailureRate,
            detail: "\(pct(cand.failureRate)) (\(cand.failures)/\(cand.runs)), limit \(pct(criteria.maxFailureRate))"
        ))
        out.append(CriterionResult(
            name: "Invented names", passed: cand.succeeded == 0 ? nil : (cand.inventedNames + cand.forbiddenNameHits) <= criteria.maxInventedNames,
            detail: "\(cand.inventedNames + cand.forbiddenNameHits) found, limit \(criteria.maxInventedNames)"
        ))
        out.append(CriterionResult(
            name: "Bookmarks land on a real moment", passed: cand.groundedRate.map { $0 >= criteria.minBookmarkGroundedRate },
            detail: "\(cand.groundedRate.map(pct) ?? "n/a"), minimum \(pct(criteria.minBookmarkGroundedRate))"
        ))
        if let c = cand.factCoverage, let b = base?.factCoverage, b > 0 {
            out.append(CriterionResult(
                name: "Fact coverage vs \(criteria.baseline)", passed: c / b >= criteria.minFactCoverageVsBaseline,
                detail: "\(pct(c)) vs \(pct(b)) = \(pct(c / b)) of baseline, minimum \(pct(criteria.minFactCoverageVsBaseline))"
            ))
        } else {
            out.append(CriterionResult(name: "Fact coverage vs \(criteria.baseline)", passed: nil, detail: "Needs both engines run on recordings with gold facts."))
        }
        if let c = cand.unsupportedNumberRate, let b = base?.unsupportedNumberRate {
            out.append(CriterionResult(
                name: "Unsupported numbers vs \(criteria.baseline)", passed: c <= b + criteria.maxUnsupportedNumberExcess,
                detail: "\(pct(c)) vs \(pct(b)), at most +\(pct(criteria.maxUnsupportedNumberExcess)) allowed"
            ))
        }
        if let c = cand.judgeMean, let b = base?.judgeMean {
            out.append(CriterionResult(
                name: "Judge score vs \(criteria.baseline)", passed: b - c <= criteria.maxJudgeDeficit,
                detail: String(format: "%.2f vs %.2f (1-5), may trail by at most %.2f", c, b, criteria.maxJudgeDeficit)
            ))
        } else {
            out.append(CriterionResult(name: "Judge score vs \(criteria.baseline)", passed: nil, detail: "Run `bench judge` first."))
        }
        if let tally = pairs.first(where: { Set([$0.a, $0.b]) == Set([criteria.candidate, criteria.baseline]) }),
           let score = tally.a == criteria.candidate ? tally.aScore : tally.bScore {
            out.append(CriterionResult(
                name: "Blind pairwise vs \(criteria.baseline)", passed: score >= criteria.minPairwiseScore,
                detail: "\(pct(score)) over \(tally.comparisons) recordings, minimum \(pct(criteria.minPairwiseScore))"
            ))
        } else {
            out.append(CriterionResult(name: "Blind pairwise vs \(criteria.baseline)", passed: nil, detail: "Run `bench judge` first."))
        }
        return out
    }

    var verdict: (text: String, pass: Bool?) {
        let results = evaluate()
        if results.contains(where: { $0.passed == false }) {
            return ("Not good enough on every criterion: \(results.filter { $0.passed == false }.map(\.name).joined(separator: "; ")).", false)
        }
        if results.contains(where: { $0.passed == nil }) {
            return ("Inconclusive: some criteria have no data yet.", nil)
        }
        return ("Meets every criterion.", true)
    }

    // MARK: Markdown

    func markdown() -> String {
        var out: [String] = ["# On-device vs Claude benchmark", ""]
        let v = verdict
        out.append("**Verdict (\(criteria.candidate) vs \(criteria.baseline)): \(v.text)**")
        out.append("")
        out.append("\(recordings) recordings. Quality metrics cover only recordings an engine finished; the failure rate covers all of them.")
        out.append("")

        out.append("## Pass bar")
        out.append("")
        out.append("| Criterion | Result | Detail |")
        out.append("|---|---|---|")
        for r in evaluate() {
            let mark = r.passed == nil ? "n/a" : (r.passed! ? "pass" : "FAIL")
            out.append("| \(r.name) | \(mark) | \(r.detail) |")
        }
        out.append("")

        out.append("## Engines")
        out.append("")
        out.append("| Engine | Model | Failed | Median time | Cost / recording | Fact coverage | Bookmarks on target | Invented names | Name clashes | Unsupported numbers | Judge (1-5) |")
        out.append("|---|---|---|---|---|---|---|---|---|---|---|")
        for label in order {
            guard let s = summaries[label] else { continue }
            out.append("| \(label) | \(s.model) | \(s.failures)/\(s.runs) | \(s.medianSeconds.map { String(format: "%.1fs", $0) } ?? "n/a") | \(s.costPerRecording.map { String(format: "$%.4f", $0) } ?? "free") | \(s.factCoverage.map(pct) ?? "n/a") | \(s.groundedRate.map(pct) ?? "n/a") | \(s.inventedNames + s.forbiddenNameHits) | \(s.nameClashes) | \(s.unsupportedNumberRate.map(pct) ?? "n/a") | \(s.judgeMean.map { String(format: "%.2f", $0) } ?? "n/a") |")
        }
        out.append("")

        if summaries.values.contains(where: { !$0.faithfulness.isEmpty }) {
            out.append("### Judge scores")
            out.append("")
            out.append("| Engine | Faithfulness | Completeness | Usefulness | n |")
            out.append("|---|---|---|---|---|")
            for label in order {
                guard let s = summaries[label], !s.faithfulness.isEmpty else { continue }
                out.append(String(format: "| %@ | %.2f | %.2f | %.2f | %d |", label, Stats.mean(s.faithfulness), Stats.mean(s.completeness), Stats.mean(s.usefulness), s.faithfulness.count))
            }
            out.append("")
        }

        if !pairs.isEmpty {
            out.append("### Blind pairwise (both orders must agree to count as a win)")
            out.append("")
            out.append("| A | B | A wins | B wins | Ties | A score |")
            out.append("|---|---|---|---|---|---|")
            for p in pairs {
                out.append("| \(p.a) | \(p.b) | \(p.aWins) | \(p.bWins) | \(p.ties) | \(p.aScore.map(pct) ?? "n/a") |")
            }
            out.append("")
        }

        out.append("## By recording length")
        out.append("")
        out.append("Short fits one on-device window, medium needs two or three, long needs four or more and relies on merging.")
        out.append("")
        out.append("| Length | Engine | Failed | Median time | Fact coverage | Bookmarks on target |")
        out.append("|---|---|---|---|---|---|")
        for bucket in LengthBucket.allCases {
            guard let engines = byBucket[bucket] else { continue }
            for label in order {
                guard let s = engines[label] else { continue }
                out.append("| \(bucket.rawValue) | \(label) | \(s.failures)/\(s.runs) | \(s.medianSeconds.map { String(format: "%.1fs", $0) } ?? "n/a") | \(s.factCoverage.map(pct) ?? "n/a") | \(s.groundedRate.map(pct) ?? "n/a") |")
            }
        }
        out.append("")

        out.append("## Per recording")
        out.append("")
        for rec in perRecording {
            out.append("### \(rec.id) (\(rec.bucket.rawValue))")
            for row in rec.rows {
                if !row.run.ok {
                    out.append("- **\(row.engine)**: FAILED after \(String(format: "%.1fs", row.run.seconds)): \(row.run.error ?? "unknown")")
                    continue
                }
                let m = row.metrics
                var bits = [String(format: "%.1fs", row.run.seconds)]
                if let m, m.factsTotal > 0 { bits.append("facts \(m.factsFound)/\(m.factsTotal)") }
                if let m, m.bookmarks > 0 { bits.append("bookmarks \(m.bookmarksGrounded)/\(m.bookmarks) on target") }
                if let m, !m.inventedSpeakerNames.isEmpty { bits.append("invented names: \(m.inventedSpeakerNames.joined(separator: ", "))") }
                if let m, !m.speakerNameClashes.isEmpty { bits.append("same name on several speakers: \(m.speakerNameClashes.joined(separator: ", "))") }
                if let m, !m.forbiddenNameHits.isEmpty { bits.append("trap names: \(m.forbiddenNameHits.joined(separator: ", "))") }
                if let m, !m.unsupportedNumbers.isEmpty { bits.append("numbers not in transcript: \(m.unsupportedNumbers.prefix(6).joined(separator: ", "))") }
                if let j = row.judge { bits.append(String(format: "judge %d/%d/%d", j.faithfulness, j.completeness, j.usefulness)) }
                out.append("- **\(row.engine)**: " + bits.joined(separator: "; "))
                if let m, !m.missingFacts.isEmpty { out.append("  - missed: \(m.missingFacts.joined(separator: ", "))") }
                if let j = row.judge, !j.unsupportedClaims.isEmpty { out.append("  - judge flagged: \(j.unsupportedClaims.prefix(3).joined(separator: " | "))") }
            }
            out.append("")
        }

        out.append("## Reading this fairly")
        out.append("")
        out.append("- Small samples: with a handful of recordings, treat differences of a few points as noise.")
        out.append("- The judge is a Claude model and may prefer Claude-style prose. The mechanical metrics (names, numbers, bookmarks, fact coverage) do not share that bias.")
        out.append("- Time for the on-device model was measured on this Mac. An iPhone is slower and can throttle; re-time there before relying on it.")
        out.append("- Cost covers API calls only and uses list prices in Anthropic.swift.")
        return out.joined(separator: "\n") + "\n"
    }
}

func pct(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }
