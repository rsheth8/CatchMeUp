import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class LibraryStore {
    /// Includes tombstones; use the filtered accessors for UI.
    private(set) var recordings: [Recording] = []
    private(set) var brains: [Brain] = []

    private(set) var syncStatus: CloudSync.Status = .off

    private let localDir: URL
    private var metadataQuery: NSMetadataQuery?
    private var cloudObserverTokens: [NSObjectProtocol] = []
    private var appObserverToken: NSObjectProtocol?
    private let recordingsName = "recordings.json"
    private let brainsName = "brains.json"

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        localDir = support.appendingPathComponent("CatchMeUp", isDirectory: true)
        try? FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        refreshSyncMode()
        load()

        appObserverToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mergeFromDisk() }
        }
    }

    // MARK: - Where data lives

    var syncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "iCloudSync") }
        set {
            UserDefaults.standard.set(newValue, forKey: "iCloudSync")
            refreshSyncMode()
            if newValue { migrateLocalToCloud() }
            load()
            mergeFromDisk()
        }
    }

    private var usingCloud = false

    private func refreshSyncMode() {
        if syncEnabled {
            usingCloud = CloudSync.isAvailable
            syncStatus = usingCloud ? .synced : .unavailable
        } else {
            usingCloud = false
            syncStatus = .off
        }
        startOrStopMetadataQuery()
    }

    private var dataDir: URL {
        if usingCloud, let cloud = CloudSync.documentsURL { return cloud }
        return localDir
    }

    var audioDir: URL {
        let dir = dataDir.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var recordingsFile: URL { dataDir.appendingPathComponent(recordingsName) }
    private var brainsFile: URL { dataDir.appendingPathComponent(brainsName) }

    // MARK: - Filtered queries (hide tombstones)

    func recording(_ id: UUID) -> Recording? {
        recordings.first { $0.id == id && !$0.deleted }
    }

    var sortedRecordings: [Recording] {
        recordings.filter { !$0.deleted }.sorted { $0.createdAt > $1.createdAt }
    }

    var visibleBrains: [Brain] {
        brains.filter { !$0.deleted }.sorted { $0.createdAt > $1.createdAt }
    }

    func recordings(inBrain id: UUID) -> [Recording] {
        recordings.filter { $0.brainID == id && !$0.deleted }.sorted { $0.createdAt > $1.createdAt }
    }

    func brain(_ id: UUID?) -> Brain? {
        guard let id else { return nil }
        return brains.first { $0.id == id && !$0.deleted }
    }

    func audioURL(for recording: Recording) -> URL? {
        guard let name = recording.audioFilename else { return nil }
        let url = audioDir.appendingPathComponent(name)
        if usingCloud { try? FileManager.default.startDownloadingUbiquitousItem(at: url) }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Mutations

    func upsert(_ recording: Recording) {
        var r = recording
        r.updatedAt = Date()
        if let i = recordings.firstIndex(where: { $0.id == r.id }) { recordings[i] = r }
        else { recordings.append(r) }
        saveRecordings()
    }

    func delete(_ recording: Recording) {
        if let name = recording.audioFilename {
            try? FileManager.default.removeItem(at: audioDir.appendingPathComponent(name))
        }
        if let i = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[i].deleted = true
            recordings[i].updatedAt = Date()
        }
        saveRecordings()
    }

    func assign(_ recordingID: UUID, toBrain brainID: UUID?) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[i].brainID = brainID
        recordings[i].updatedAt = Date()
        saveRecordings()
    }

    func upsert(_ brain: Brain) {
        var b = brain
        b.updatedAt = Date()
        if let i = brains.firstIndex(where: { $0.id == b.id }) { brains[i] = b }
        else { brains.append(b) }
        saveBrains()
    }

    func delete(_ brain: Brain) {
        for r in recordings where r.brainID == brain.id { assign(r.id, toBrain: nil) }
        if let i = brains.firstIndex(where: { $0.id == brain.id }) {
            brains[i].deleted = true
            brains[i].updatedAt = Date()
        }
        saveBrains()
    }

    // MARK: - Audio helpers

    @discardableResult
    func importAudio(from source: URL, preferredName: String) -> String? {
        let ext = source.pathExtension.isEmpty ? "m4a" : source.pathExtension
        let name = "\(UUID().uuidString).\(ext)"
        let dest = audioDir.appendingPathComponent(name)
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do { try FileManager.default.copyItem(at: source, to: dest); return name }
        catch { return nil }
    }

    func newAudioFilename(ext: String = "m4a") -> String { "\(UUID().uuidString).\(ext)" }

    // MARK: - Persistence

    private func load() {
        let dec = JSONDecoder()
        if let d = coordinatedRead(recordingsFile), let r = try? dec.decode([Recording].self, from: d) {
            recordings = r
        }
        if let d = coordinatedRead(brainsFile), let b = try? dec.decode([Brain].self, from: d) {
            brains = b
        }
    }

    private func saveRecordings() { write(recordings, to: recordingsFile) }
    private func saveBrains() { write(brains, to: brainsFile) }

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

    // MARK: - Merge (called when iCloud reports a change)

    func mergeFromDisk() {
        let dec = JSONDecoder()
        var changed = false

        if let d = coordinatedRead(recordingsFile),
           let incoming = try? dec.decode([Recording].self, from: d) {
            let merged = Self.merge(local: recordings, remote: incoming) { $0.id } newer: { $0.updatedAt }
            if Set(merged) != Set(recordings) { recordings = merged; changed = true }
        }
        if let d = coordinatedRead(brainsFile),
           let incoming = try? dec.decode([Brain].self, from: d) {
            let merged = Self.merge(local: brains, remote: incoming) { $0.id } newer: { $0.updatedAt }
            if Set(merged) != Set(brains) { brains = merged; changed = true }
        }
        if changed { saveRecordings(); saveBrains() }
        if syncEnabled { syncStatus = usingCloud ? .synced : .unavailable }
    }

    /// Union by identity, keeping whichever copy was updated most recently.
    private static func merge<E: Hashable>(
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

    // MARK: - Metadata query (live iCloud updates)

    private func startOrStopMetadataQuery() {
        metadataQuery?.stop()
        metadataQuery = nil
        cloudObserverTokens.forEach(NotificationCenter.default.removeObserver)
        cloudObserverTokens.removeAll()
        guard usingCloud else { return }

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K ENDSWITH '.json'", NSMetadataItemFSNameKey)
        for name: NSNotification.Name in [.NSMetadataQueryDidUpdate, .NSMetadataQueryDidFinishGathering] {
            let token = NotificationCenter.default.addObserver(forName: name, object: q, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.mergeFromDisk() }
            }
            cloudObserverTokens.append(token)
        }
        q.start()
        metadataQuery = q
    }

    // MARK: - Migration

    private func migrateLocalToCloud() {
        guard let cloud = CloudSync.documentsURL else { return }
        let fm = FileManager.default
        for name in [recordingsName, brainsName] {
            let src = localDir.appendingPathComponent(name)
            let dst = cloud.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path), !fm.fileExists(atPath: dst.path) else { continue }
            try? fm.copyItem(at: src, to: dst)
        }
        let srcAudio = localDir.appendingPathComponent("audio", isDirectory: true)
        let dstAudio = cloud.appendingPathComponent("audio", isDirectory: true)
        try? fm.createDirectory(at: dstAudio, withIntermediateDirectories: true)
        if let files = try? fm.contentsOfDirectory(at: srcAudio, includingPropertiesForKeys: nil) {
            for f in files {
                let dst = dstAudio.appendingPathComponent(f.lastPathComponent)
                if !fm.fileExists(atPath: dst.path) { try? fm.copyItem(at: f, to: dst) }
            }
        }
    }

    // MARK: - Demo seed

    func seedSampleIfEmpty() {
        guard sortedRecordings.isEmpty else { return }
        recordings = SampleData.recordings
        saveRecordings()
    }
}
