import Foundation

// MARK: - Results on disk

/// One engine's attempt at one recording. Failures are results too: a recap the
/// app could not produce is exactly what the failure rate has to count.
struct RunRecord: Codable {
    var transcriptId: String
    var engine: String
    var model: String
    var ok: Bool
    var error: String?
    var seconds: Double
    /// Transcript windows the engine's budget splits this recording into.
    var chunks: Int
    var calls: Int
    var inputTokens: Int
    var outputTokens: Int
    /// nil for the on-device model, or when the model has no known price.
    var costUSD: Double?
    var recap: Recap?
    var finishedAt: Date
}

struct ResultStore {
    let root: URL

    var runsDir: URL { root.appendingPathComponent("runs") }
    var judgmentsDir: URL { root.appendingPathComponent("judgments") }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func runURL(transcript: String, engine: String) -> URL {
        runsDir.appendingPathComponent("\(transcript).\(engine).json")
    }

    func save(_ record: RunRecord) throws {
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)
        try Self.encoder.encode(record).write(to: runURL(transcript: record.transcriptId, engine: record.engine))
    }

    func loadRuns() throws -> [RunRecord] {
        try Self.loadAll(RunRecord.self, in: runsDir)
    }

    static func loadAll<T: Decodable>(_ type: T.Type, in directory: URL, prefix: String? = nil) throws -> [T] {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        return try files
            .filter { file in
                file.pathExtension == "json" && (prefix == nil || file.lastPathComponent.hasPrefix(prefix!))
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try decoder.decode(T.self, from: Data(contentsOf: $0)) }
    }

    /// The most recent run directory under `base`, for `judge` and `report`
    /// invoked without `--out`.
    static func latest(under base: URL) -> URL? {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return dirs.filter { $0.hasDirectoryPath }.sorted { $0.lastPathComponent < $1.lastPathComponent }.last
    }
}

// MARK: - Running

enum Runner {
    /// Pushes one recording through one engine the way the app does, and times it.
    static func run(spec: EngineSpec, item: CorpusItem, handle: EngineHandle) async -> RunRecord {
        handle.meter.reset()
        let chunks = TranscriptChunker.chunks(
            item.transcript, maxCharacters: handle.engine.recapBudget.charactersPerRequest
        ).count

        let clock = ContinuousClock()
        let start = clock.now
        var recap: Recap?
        var failure: String?
        do {
            recap = try await handle.engine.makeRecap(
                transcript: item.transcript, mode: item.mode, progress: { _ in }
            )
        } catch {
            failure = describe(error)
        }
        let elapsed = start.duration(to: clock.now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18

        // A recap with nothing in it is a failure from the user's side even
        // though no error was thrown.
        if let r = recap, (r.tldr ?? []).isEmpty, (r.detailedNotes ?? []).isEmpty {
            failure = "Empty recap: no summary and no notes."
        }

        return RunRecord(
            transcriptId: item.id,
            engine: spec.label,
            model: spec.modelName,
            ok: failure == nil,
            error: failure,
            seconds: seconds,
            chunks: chunks,
            calls: handle.meter.calls,
            inputTokens: handle.meter.inputTokens,
            outputTokens: handle.meter.outputTokens,
            costUSD: spec.isCloud && handle.meter.costKnown ? handle.meter.cost : nil,
            recap: recap,
            finishedAt: Date()
        )
    }

    static func describe(_ error: Error) -> String {
        if error is CancellationError { return "Cancelled." }
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        return String(describing: error)
    }
}
