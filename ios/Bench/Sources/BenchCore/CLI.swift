import Foundation

// bench check
// bench run     [--engines apple,haiku,strong] [--only id,id] [--out DIR] [--force]
// bench judge   [--out DIR]
// bench report  [--out DIR]
// bench import  --file transcript.txt --id NAME --mode lecture|meeting --title "..."
//
// Keys come from the environment only (ANTHROPIC_API_KEY) and are never printed.

public enum BenchCLI {

    struct Options {
        var command = "help"
        var engines = ["apple", "haiku", "strong"]
        var only: Set<String>?
        var corpus = "corpus"
        var resultsBase = "results"
        var out: String?
        var haikuModel = Contestants.defaultHaiku
        var strongModel = Contestants.defaultStrong
        var judgeModel = Contestants.defaultJudge
        var judgeVia = "claude"
        var effort = "medium"
        var maxCost = 5.0
        var concurrency = 4
        var force = false
        var criteria: String?
        // import
        var file: String?
        var id: String?
        var mode: String?
        var title: String?
    }

    public static func main(_ args: [String]) async -> Int32 {
        do {
            let options = try parse(Array(args.dropFirst()))
            switch options.command {
            case "check": return try check(options)
            case "run": return try await run(options)
            case "judge": return try await judge(options)
            case "report": return try report(options)
            case "import": return try importTranscript(options)
            default:
                print(helpText)
                return options.command == "help" ? 0 : 2
            }
        } catch {
            FileHandle.standardError.write(Data("error: \(Runner.describe(error))\n".utf8))
            return 1
        }
    }

    // MARK: Parsing

    static func parse(_ args: [String]) throws -> Options {
        var o = Options()
        guard let command = args.first else { return o }
        o.command = command
        var i = 1
        func value(_ flag: String) throws -> String {
            i += 1
            guard i < args.count else { throw BenchError.usage("\(flag) needs a value.") }
            return args[i]
        }
        while i < args.count {
            let flag = args[i]
            switch flag {
            case "--engines": o.engines = try value(flag).split(separator: ",").map(String.init)
            case "--only": o.only = Set(try value(flag).split(separator: ",").map(String.init))
            case "--corpus": o.corpus = try value(flag)
            case "--results": o.resultsBase = try value(flag)
            case "--out": o.out = try value(flag)
            case "--haiku-model": o.haikuModel = try value(flag)
            case "--strong-model": o.strongModel = try value(flag)
            case "--judge-model": o.judgeModel = try value(flag)
            case "--judge-via":
                let via = try value(flag)
                guard ["claude", "api"].contains(via) else { throw BenchError.usage("--judge-via is claude (your Claude subscription, through the claude CLI) or api (your API key).") }
                o.judgeVia = via
            case "--effort": o.effort = try value(flag)
            case "--max-cost":
                guard let cost = Double(try value(flag)), cost > 0 else { throw BenchError.usage("--max-cost needs a positive number of dollars.") }
                o.maxCost = cost
            case "--concurrency":
                guard let n = Int(try value(flag)), n > 0 else { throw BenchError.usage("--concurrency needs a positive integer.") }
                o.concurrency = n
            case "--criteria": o.criteria = try value(flag)
            case "--force": o.force = true
            case "--file": o.file = try value(flag)
            case "--id": o.id = try value(flag)
            case "--mode": o.mode = try value(flag)
            case "--title": o.title = try value(flag)
            default: throw BenchError.usage("Unknown option \(flag). Try `bench help`.")
            }
            i += 1
        }
        return o
    }

    static var apiKey: String { ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "" }

    static func resultDirectory(_ o: Options, create: Bool) throws -> ResultStore {
        let base = URL(fileURLWithPath: o.resultsBase)
        if let out = o.out { return ResultStore(root: URL(fileURLWithPath: out)) }
        if create {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            return ResultStore(root: base.appendingPathComponent(f.string(from: Date())))
        }
        guard let latest = ResultStore.latest(under: base) else {
            throw BenchError.usage("No results found under \(o.resultsBase). Run `bench run` first or pass --out.")
        }
        return ResultStore(root: latest)
    }

    // MARK: check

    static func check(_ o: Options) throws -> Int32 {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        print("macOS: \(os)")
        let apple = EngineFactory.appleAvailability()
        print("Apple on-device model: \(apple.detail)")
        print("ANTHROPIC_API_KEY: \(apiKey.isEmpty ? "NOT SET (cloud engines will not run; judging uses your Claude subscription unless --judge-via api)" : "set")")
        let corpus = try Corpus.load(from: URL(fileURLWithPath: o.corpus))
        print("Corpus: \(corpus.count) recordings in \(o.corpus)")
        for item in corpus {
            print(String(format: "  %-28@ %-8@ %-7@ %6d chars, %2d gold facts", item.id as NSString, item.mode.rawValue as NSString, item.bucket.rawValue as NSString, item.transcript.count, item.gold.facts.count))
        }
        print("Models: haiku=\(o.haikuModel) strong=\(o.strongModel) judge=\(o.judgeModel)")
        for model in [o.haikuModel, o.strongModel, o.judgeModel] where Pricing.rate(for: model) == nil {
            print("  note: no price on file for \(model); its cost will show as unknown")
        }
        return 0
    }

    // MARK: run

    static func run(_ o: Options) async throws -> Int32 {
        let corpus = try Corpus.load(from: URL(fileURLWithPath: o.corpus), only: o.only)
        let specs = try Contestants.specs(labels: o.engines, haiku: o.haikuModel, strong: o.strongModel)
        if specs.contains(where: \.isCloud), apiKey.isEmpty { throw BenchError.missingKey }
        BudgetGuard.shared.configure(limit: o.maxCost)

        let store = try resultDirectory(o, create: true)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try writeManifest(store, specs: specs, options: o, corpus: corpus)
        print("Results: \(store.root.path)")

        // On-device first and alone, so its timings aren't shared with network waits.
        for spec in specs.sorted(by: { !$0.isCloud && $1.isCloud }) {
            let handle = try EngineFactory.make(spec, apiKey: apiKey, effort: o.effort)
            if !spec.isCloud { await warmUp(handle.engine) }
            for item in corpus {
                let existing = store.runURL(transcript: item.id, engine: spec.label)
                if !o.force, FileManager.default.fileExists(atPath: existing.path) {
                    print("[\(spec.label)] \(item.id): already done, skipping")
                    continue
                }
                let record = await Runner.run(spec: spec, item: item, handle: handle)
                try store.save(record)
                print(summaryLine(record))
                if record.error?.contains("Spend limit") == true {
                    print("Stopped: spend limit reached.")
                    return 3
                }
            }
        }
        print(String(format: "Done. API spend this run: $%.4f", BudgetGuard.shared.total))
        print("Next: bench judge --out \(store.root.path)   then   bench report --out \(store.root.path)")
        return 0
    }

    static func summaryLine(_ r: RunRecord) -> String {
        var line = "[\(r.engine)] \(r.transcriptId): " + (r.ok ? "ok" : "FAILED")
        line += String(format: " in %.1fs, %d window(s)", r.seconds, r.chunks)
        if let c = r.costUSD { line += String(format: ", $%.4f", c) }
        if let e = r.error { line += " - \(e)" }
        return line
    }

    /// The first on-device request loads model assets, which would otherwise
    /// be billed to whichever recording happened to go first.
    static func warmUp(_ engine: RecapEngine) async {
        _ = try? await engine.respond(system: "Reply with the single word OK.", user: "Say OK.", maxTokens: 8)
    }

    static func writeManifest(_ store: ResultStore, specs: [EngineSpec], options: Options, corpus: [CorpusItem]) throws {
        struct Manifest: Codable {
            var date: Date
            var macOS: String
            var engines: [EngineSpec]
            var effort: String
            var recordings: [String]
            var maxCostUSD: Double
        }
        let manifest = Manifest(
            date: Date(), macOS: ProcessInfo.processInfo.operatingSystemVersionString, engines: specs,
            effort: options.effort, recordings: corpus.map(\.id), maxCostUSD: options.maxCost
        )
        try ResultStore.encoder.encode(manifest).write(to: store.root.appendingPathComponent("manifest.json"))
    }

    // MARK: judge

    static func judge(_ o: Options) async throws -> Int32 {
        let backend: JudgeBackend
        if o.judgeVia == "api" {
            guard !apiKey.isEmpty else { throw BenchError.missingKey }
            backend = .api(key: apiKey)
        } else {
            backend = .claudeCLI
        }
        BudgetGuard.shared.configure(limit: o.maxCost)
        let store = try resultDirectory(o, create: false)
        let runs = try store.loadRuns().filter { $0.ok && $0.recap != nil }
        let corpus = Dictionary(uniqueKeysWithValues: try Corpus.load(from: URL(fileURLWithPath: o.corpus)).map { ($0.id, $0) })

        struct Job { let label: String; let work: @Sendable () async throws -> Void }
        var jobs: [Job] = []
        let judgeModel = o.judgeModel
        let client = JudgeClient(model: judgeModel, backend: backend)

        for run in runs {
            guard let item = corpus[run.transcriptId], let recap = run.recap else { continue }
            let url = store.absoluteURL(transcript: run.transcriptId, engine: run.engine)
            if !o.force, FileManager.default.fileExists(atPath: url.path) { continue }
            jobs.append(Job(label: "score \(run.transcriptId) \(run.engine)") {
                let j = try await Judge.score(item: item, run: run, recap: recap, client: client)
                try store.save(j, to: url)
            })
        }

        let byRecording = Dictionary(grouping: runs, by: \.transcriptId)
        for (id, group) in byRecording {
            guard let item = corpus[id] else { continue }
            let sorted = group.sorted { Report.rank($0.engine) < Report.rank($1.engine) }
            for x in 0..<sorted.count {
                for y in (x + 1)..<max(sorted.count, x + 1) {
                    for (first, second) in [(sorted[x], sorted[y]), (sorted[y], sorted[x])] {
                        guard let a = first.recap, let b = second.recap else { continue }
                        let url = store.pairURL(transcript: id, first: first.engine, second: second.engine)
                        if !o.force, FileManager.default.fileExists(atPath: url.path) { continue }
                        jobs.append(Job(label: "compare \(id) \(first.engine) then \(second.engine)") {
                            let p = try await Judge.compare(
                                item: item, first: (first.engine, a), second: (second.engine, b),
                                client: client
                            )
                            try store.save(p, to: url)
                        })
                    }
                }
            }
        }

        if jobs.isEmpty { print("Nothing to judge (already done, or no successful runs)."); return 0 }
        print("Judging with \(judgeModel) via \(backend.label): \(jobs.count) calls, up to \(o.concurrency) at a time.")

        var failed = 0
        var stopped = false
        var next = 0
        await withTaskGroup(of: (String, Error?).self) { group in
            func launch() {
                guard next < jobs.count, !stopped else { return }
                let job = jobs[next]; next += 1
                group.addTask {
                    do { try await job.work(); return (job.label, nil) } catch { return (job.label, error) }
                }
            }
            for _ in 0..<min(o.concurrency, jobs.count) { launch() }
            while let (label, error) = await group.next() {
                if let error {
                    failed += 1
                    print("  failed: \(label): \(Runner.describe(error))")
                    if case BenchError.budgetExceeded = error { stopped = true }
                } else {
                    print("  done: \(label)")
                }
                launch()
            }
        }
        let spend = o.judgeVia == "api" ? String(format: "API spend this run: $%.4f", BudgetGuard.shared.total) : "No API spend (counted against your Claude subscription)."
        print("Judging finished: \(failed) failed. \(spend)")
        return failed == 0 ? 0 : 4
    }

    // MARK: report

    static func report(_ o: Options) throws -> Int32 {
        let store = try resultDirectory(o, create: false)
        let runs = try store.loadRuns()
        guard !runs.isEmpty else { throw BenchError.usage("No runs in \(store.root.path).") }
        let corpus = try Corpus.load(from: URL(fileURLWithPath: o.corpus))
        let criteria = try Criteria.load(from: (o.criteria ?? defaultCriteriaPath()).map { URL(fileURLWithPath: $0) })
        let report = Report(
            runs: runs, absolute: try store.loadAbsolute(), pairsJudged: try store.loadPairs(),
            corpus: corpus, criteria: criteria
        )
        let text = report.markdown()
        try text.write(to: store.root.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
        print(text)
        print("Saved \(store.root.appendingPathComponent("report.md").path)")
        return 0
    }

    static func defaultCriteriaPath() -> String? {
        FileManager.default.fileExists(atPath: "criteria.json") ? "criteria.json" : nil
    }

    // MARK: import

    static func importTranscript(_ o: Options) throws -> Int32 {
        guard let file = o.file, let id = o.id, let modeName = o.mode, let mode = Mode(rawValue: modeName) else {
            throw BenchError.usage("import needs --file, --id and --mode lecture|meeting.")
        }
        let dir = try Corpus.importTranscript(
            file: URL(fileURLWithPath: file), id: id, mode: mode, title: o.title ?? id,
            into: URL(fileURLWithPath: o.corpus)
        )
        print("Added \(dir.path). It has no gold facts; add them to meta.json for fact-coverage scoring.")
        return 0
    }

    static let helpText = """
    bench: compare Apple's on-device model with Claude on the app's recap task

      bench check                       availability, key, corpus summary
      bench run [options]               run engines over the corpus
      bench judge [options]             blind Claude judge (default: your Claude subscription via the claude CLI)
      bench report [options]            tables and a verdict against criteria.json
      bench import --file F --id ID --mode lecture|meeting [--title T]

    options
      --engines apple,haiku,strong      default: all three
      --only id,id                      restrict to some recordings
      --corpus DIR                      default: corpus
      --out DIR                         result directory (default: results/<timestamp>, or the latest for judge/report)
      --haiku-model ID                  default: \(Contestants.defaultHaiku) (the app's default)
      --strong-model ID                 default: \(Contestants.defaultStrong)
      --judge-model ID                  default: \(Contestants.defaultJudge)
      --judge-via claude|api            claude = subscription through the claude CLI (default), api = ANTHROPIC_API_KEY
      --effort low|medium|high          thinking effort for models that support it (default: medium)
      --max-cost USD                    stop before spending more than this in one invocation (default: 5)
      --concurrency N                   parallel judge calls (default: 4)
      --criteria FILE                   pass bar (default: ./criteria.json if present)
      --force                           redo work that already has a result

    The API key is read from ANTHROPIC_API_KEY and never printed. With direnv it is already
    loaded; otherwise: ANTHROPIC_API_KEY="$(secret get ANTHROPIC_API_KEY)" swift run bench run
    """
}
