import Foundation

// A corpus item is a directory:
//
//   corpus/<id>/transcript.txt   `[HH:MM:SS] text` or `[HH:MM:SS] Speaker: text` lines,
//                                exactly the shape the app feeds the model
//   corpus/<id>/meta.json        mode, title, and (optional) gold facts
//
// Gold is optional on purpose. A real recording imported from the library has
// no hand-written answer key, and still gets every metric that doesn't need one
// (failures, latency, cost, timestamps, invented names and numbers, judge scores).

struct GoldFact: Codable, Hashable {
    /// Short name shown when the fact is missing from a recap.
    var id: String
    /// Any one of these phrases (case and punctuation ignored) counts as the
    /// recap having covered the fact. Include paraphrases a good note would use.
    var anyOf: [String]
}

struct Gold: Codable, Hashable {
    var facts: [GoldFact] = []
    /// Names that are genuinely spoken in the recording.
    var speakerNames: [String] = []
    /// Plausible names that are NOT in the recording. Seeing one in the notes
    /// is a hallucination by construction.
    var forbiddenNames: [String] = []

    init(facts: [GoldFact] = [], speakerNames: [String] = [], forbiddenNames: [String] = []) {
        self.facts = facts
        self.speakerNames = speakerNames
        self.forbiddenNames = forbiddenNames
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        facts = try c.decodeIfPresent([GoldFact].self, forKey: .facts) ?? []
        speakerNames = try c.decodeIfPresent([String].self, forKey: .speakerNames) ?? []
        forbiddenNames = try c.decodeIfPresent([String].self, forKey: .forbiddenNames) ?? []
    }
}

struct CorpusMeta: Codable {
    var mode: Mode
    var title: String
    var notes: String?
    var gold: Gold?
}

enum LengthBucket: String, Codable, CaseIterable {
    /// Fits one on-device window.
    case short
    /// Two or three on-device windows.
    case medium
    /// Four or more windows, where merging quality matters.
    case long
}

struct CorpusItem: Hashable {
    var id: String
    var mode: Mode
    var title: String
    var transcript: String
    var gold: Gold

    var bucket: LengthBucket {
        let n = TranscriptChunker.chunks(transcript, maxCharacters: RecapBudget.onDevice.charactersPerRequest).count
        switch n {
        case ...1: return .short
        case 2...3: return .medium
        default: return .long
        }
    }

    var lastTimestamp: Double { Transcript.stamps(in: transcript).last ?? 0 }
}

enum Corpus {
    static func load(from directory: URL, only: Set<String>? = nil) throws -> [CorpusItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else {
            throw BenchError.usage("No corpus at \(directory.path).")
        }
        let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var items: [CorpusItem] = []
        for dir in entries {
            let id = dir.lastPathComponent
            if let only, !only.contains(id) { continue }
            let transcriptURL = dir.appendingPathComponent("transcript.txt")
            let metaURL = dir.appendingPathComponent("meta.json")
            guard fm.fileExists(atPath: transcriptURL.path), fm.fileExists(atPath: metaURL.path) else { continue }
            let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let meta = try JSONDecoder().decode(CorpusMeta.self, from: Data(contentsOf: metaURL))
            items.append(CorpusItem(
                id: id, mode: meta.mode, title: meta.title, transcript: transcript, gold: meta.gold ?? Gold()
            ))
        }
        if let only {
            let missing = only.subtracting(items.map(\.id))
            if !missing.isEmpty {
                throw BenchError.usage("Not in the corpus: \(missing.sorted().joined(separator: ", ")).")
            }
        }
        guard !items.isEmpty else { throw BenchError.usage("The corpus at \(directory.path) is empty.") }
        return items
    }

    /// Adds a transcript (for example one exported from the app) to a corpus.
    @discardableResult
    static func importTranscript(
        file: URL, id: String, mode: Mode, title: String, into directory: URL
    ) throws -> URL {
        guard id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw BenchError.usage("Use letters, digits, dot, dash or underscore for --id.")
        }
        let text = try String(contentsOf: file, encoding: .utf8)
        guard !Transcript.stamps(in: text).isEmpty else {
            throw BenchError.usage("No [HH:MM:SS] timestamps found. The app's recap prompts expect that shape.")
        }
        let dir = directory.appendingPathComponent(id)
        guard !FileManager.default.fileExists(atPath: dir.path) else {
            throw BenchError.usage("\(id) already exists in the corpus.")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(CorpusMeta(mode: mode, title: title, notes: nil, gold: nil))
            .write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }
}

/// Timestamp helpers shared by the corpus and the metrics.
enum Transcript {
    private static let stampPattern = try! NSRegularExpression(pattern: #"\[(\d{1,2}):(\d{2}):(\d{2})\]"#)

    /// Every `[HH:MM:SS]` in the transcript, in seconds, in order.
    static func stamps(in transcript: String) -> [Double] {
        let range = NSRange(transcript.startIndex..., in: transcript)
        return stampPattern.matches(in: transcript, range: range).compactMap { match in
            guard let h = Double(substring(transcript, match.range(at: 1))),
                  let m = Double(substring(transcript, match.range(at: 2))),
                  let s = Double(substring(transcript, match.range(at: 3))) else { return nil }
            return h * 3600 + m * 60 + s
        }
    }

    private static func substring(_ text: String, _ range: NSRange) -> String {
        guard let r = Range(range, in: text) else { return "" }
        return String(text[r])
    }
}
