import Foundation
import Observation

@MainActor
@Observable
final class LibraryStore {
    private(set) var recordings: [Recording] = []
    private(set) var brains: [Brain] = []

    private let dir: URL
    private let recordingsFile: URL
    private let brainsFile: URL
    let audioDir: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = support.appendingPathComponent("CatchMeUp", isDirectory: true)
        audioDir = dir.appendingPathComponent("audio", isDirectory: true)
        recordingsFile = dir.appendingPathComponent("recordings.json")
        brainsFile = dir.appendingPathComponent("brains.json")
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        load()
    }

    // MARK: Query

    func recording(_ id: UUID) -> Recording? { recordings.first { $0.id == id } }

    func recordings(inBrain id: UUID) -> [Recording] {
        recordings.filter { $0.brainID == id }.sorted { $0.createdAt > $1.createdAt }
    }

    var sortedRecordings: [Recording] { recordings.sorted { $0.createdAt > $1.createdAt } }

    func audioURL(for recording: Recording) -> URL? {
        guard let name = recording.audioFilename else { return nil }
        let url = audioDir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Mutate

    func upsert(_ recording: Recording) {
        if let i = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[i] = recording
        } else {
            recordings.append(recording)
        }
        saveRecordings()
    }

    func delete(_ recording: Recording) {
        if let name = recording.audioFilename {
            try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(name))
        }
        recordings.removeAll { $0.id == recording.id }
        saveRecordings()
    }

    func assign(_ recordingID: UUID, toBrain brainID: UUID?) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[i].brainID = brainID
        saveRecordings()
    }

    @discardableResult
    func importAudio(from source: URL, preferredName: String) -> String? {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        let dest = audioDir.appendingPathComponent(name)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.copyItem(at: source, to: dest)
            return name
        } catch {
            return nil
        }
    }

    func newAudioFilename(ext: String = "m4a") -> String { "\(UUID().uuidString).\(ext)" }

    // MARK: Brains

    func upsert(_ brain: Brain) {
        if let i = brains.firstIndex(where: { $0.id == brain.id }) {
            brains[i] = brain
        } else {
            brains.append(brain)
        }
        saveBrains()
    }

    func delete(_ brain: Brain) {
        for r in recordings where r.brainID == brain.id { assign(r.id, toBrain: nil) }
        brains.removeAll { $0.id == brain.id }
        saveBrains()
    }

    func brain(_ id: UUID?) -> Brain? {
        guard let id else { return nil }
        return brains.first { $0.id == id }
    }

    // MARK: Persistence

    private func load() {
        let dec = JSONDecoder()
        if let d = try? Data(contentsOf: recordingsFile),
           let r = try? dec.decode([Recording].self, from: d) { recordings = r }
        if let d = try? Data(contentsOf: brainsFile),
           let b = try? dec.decode([Brain].self, from: d) { brains = b }
    }

    private func saveRecordings() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(recordings) { try? d.write(to: recordingsFile, options: .atomic) }
    }

    private func saveBrains() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? enc.encode(brains) { try? d.write(to: brainsFile, options: .atomic) }
    }

    // MARK: Demo seed

    func seedSampleIfEmpty() {
        guard recordings.isEmpty else { return }
        recordings = SampleData.recordings
        saveRecordings()
    }
}
