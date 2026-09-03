import Foundation

// MARK: - Mode

enum Mode: String, Codable, CaseIterable, Identifiable, Hashable {
    case meeting
    case lecture

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meeting: return "Meeting"
        case .lecture: return "Lecture"
        }
    }

    var blurb: String {
        switch self {
        case .meeting: return "Standup, Zoom, 1:1, client call"
        case .lecture: return "Class, seminar, recorded talk"
        }
    }

    var symbol: String {
        switch self {
        case .meeting: return "person.2.wave.2"
        case .lecture: return "graduationcap"
        }
    }

    /// Role instruction handed to the model, ported from the CLI pipeline.
    var roleInstruction: String {
        switch self {
        case .lecture:
            return """
            You are writing notes for a student who missed this recorded lecture. \
            Teach the material: definitions, examples, formulas, and what is likely to show up on a quiz or exam. \
            Do not write as if this were a business meeting.
            """
        case .meeting:
            return """
            You are analyzing a transcript of a work meeting (standup, Zoom, client call, 1:1). \
            Write notes for someone who did not attend: decisions, owners, deadlines, and follow-ups. \
            Lines may be labeled Speaker 1, Speaker 2, … — use those labels in action items and speakers[].
            """
        }
    }

    static let lectureHints = ["lecture", "class", "lesson", "seminar", "tutorial", "recitation",
                               "course", "week", "midterm", "final", "exam", "lab", "professor", "prof"]
    static let meetingHints = ["standup", "stand-up", "zoom", "meet", "huddle", "sync", "1-1", "1on1",
                               "allhands", "all-hands", "retro", "sprint", "kickoff", "interview", "client", "weekly"]

    static func guess(fromFilename name: String) -> Mode {
        let lower = name.lowercased()
        if lectureHints.contains(where: lower.contains) { return .lecture }
        if meetingHints.contains(where: lower.contains) { return .meeting }
        return .meeting
    }
}

// MARK: - Transcript

struct Segment: Codable, Hashable, Identifiable {
    var id = UUID()
    var start: Double        // seconds
    var text: String
    var speaker: String?

    var stamp: String { Segment.hms(start) }

    static func hms(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

extension Array where Element == Segment {
    /// `[HH:MM:SS] text` lines, the shape the CLI feeds the model.
    var timestampedText: String {
        map { seg in
            if let sp = seg.speaker, !sp.isEmpty {
                return "[\(seg.stamp)] \(sp): \(seg.text)"
            }
            return "[\(seg.stamp)] \(seg.text)"
        }.joined(separator: "\n")
    }

    var plainText: String { map(\.text).joined(separator: " ") }
}

// MARK: - Recap (decoded from the model's JSON)

struct Bookmark: Codable, Hashable, Identifiable {
    var id = UUID()
    var timestamp: String = ""
    var heading: String = ""
    var insight: String = ""

    private enum CodingKeys: String, CodingKey { case timestamp, heading, insight }

    var seconds: Double? {
        let parts = timestamp.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}

struct DetailNote: Codable, Hashable, Identifiable {
    var id = UUID()
    var heading: String = ""
    var content: String = ""
    private enum CodingKeys: String, CodingKey { case heading, content }
}

struct Term: Codable, Hashable, Identifiable {
    var id = UUID()
    var term: String = ""
    var definition: String = ""
    private enum CodingKeys: String, CodingKey { case term, definition }
}

struct SpeakerNote: Codable, Hashable, Identifiable {
    var id = UUID()
    var label: String = ""
    var name: String = ""
    var said: String = ""
    private enum CodingKeys: String, CodingKey { case label, name, said }
}

struct Recap: Codable, Hashable {
    var title: String?
    var tldr: [String]?
    var actionItems: [String]?
    var speakers: [SpeakerNote]?
    var bookmarks: [Bookmark]?
    var detailedNotes: [DetailNote]?
    var terms: [Term]?
    var study: [String]?

    /// Lenient parse: strips ``` fences, falls back to the first `{ … }` block.
    static func parse(_ raw: String) throws -> Recap {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            if let nl = text.firstIndex(of: "\n") { text = String(text[text.index(after: nl)...]) }
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasSuffix("```") { text = String(text.dropLast(3)) }
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        if let data = text.data(using: .utf8), let r = try? decoder.decode(Recap.self, from: data) {
            return r
        }
        if let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}") {
            let slice = String(text[open...close])
            if let data = slice.data(using: .utf8) {
                return try decoder.decode(Recap.self, from: data)
            }
        }
        throw EngineError.badResponse
    }
}

// MARK: - Recording

struct Recording: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var deleted = false
    var mode: Mode
    var audioFilename: String?
    var duration: Double = 0
    var segments: [Segment] = []
    var recap: Recap?
    var brainID: UUID?
    var processingError: String?

    var displayTitle: String {
        if let t = recap?.title, !t.isEmpty { return t }
        return title
    }

    var isProcessed: Bool { recap != nil }

    init(id: UUID = UUID(), title: String, createdAt: Date = Date(), mode: Mode,
         audioFilename: String? = nil, duration: Double = 0, segments: [Segment] = [],
         recap: Recap? = nil, brainID: UUID? = nil) {
        self.id = id; self.title = title; self.createdAt = createdAt; self.updatedAt = createdAt
        self.mode = mode; self.audioFilename = audioFilename; self.duration = duration
        self.segments = segments; self.recap = recap; self.brainID = brainID
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, deleted, mode, audioFilename
        case duration, segments, recap, brainID, processingError
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        mode = try c.decode(Mode.self, forKey: .mode)
        audioFilename = try c.decodeIfPresent(String.self, forKey: .audioFilename)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        segments = try c.decodeIfPresent([Segment].self, forKey: .segments) ?? []
        recap = try c.decodeIfPresent(Recap.self, forKey: .recap)
        brainID = try c.decodeIfPresent(UUID.self, forKey: .brainID)
        processingError = try c.decodeIfPresent(String.self, forKey: .processingError)
    }
}

// MARK: - Brain

struct Brain: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var persona: String = ""
    var mode: Mode = .lecture
    var createdAt = Date()
    var updatedAt = Date()
    var deleted = false

    init(id: UUID = UUID(), name: String, persona: String = "", mode: Mode = .lecture, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.persona = persona; self.mode = mode
        self.createdAt = createdAt; self.updatedAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, persona, mode, createdAt, updatedAt, deleted
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        persona = try c.decodeIfPresent(String.self, forKey: .persona) ?? ""
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .lecture
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
    }
}

// MARK: - Errors

enum EngineError: LocalizedError {
    case badResponse
    case missingKey
    case onDeviceUnavailable(String)
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The model didn't return notes we could read. Try again."
        case .missingKey: return "Add your API key in Settings, or switch to Demo or On-device."
        case .onDeviceUnavailable(let why): return why
        case .http(let code, let body):
            let short = body.prefix(200)
            return "The provider returned an error (\(code)). \(short)"
        }
    }
}
