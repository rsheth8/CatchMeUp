import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class LibraryStore {
    /// One store per process. A `BGProcessingTask` can launch the app without
    /// ever building the view tree, so the background worker needs a way to
    /// reach the library that doesn't go through the environment — and two
    /// instances writing the same `recordings.json` would lose recaps.
    static let shared = LibraryStore()

    /// Includes tombstones; use the filtered accessors for UI.
    private(set) var recordings: [Recording] = []
    private(set) var brains: [Brain] = []

    private(set) var syncStatus: CloudSync.Status = .off
    private(set) var migration: MigrationState = .idle

    /// The only thing in the app that touches audio files. Views and playback
    /// ask it where a recording lives rather than assuming.
    let audio: AudioStorage

    /// Told when a recap is deleted or refiled, so its questions follow it.
    /// Optional and weak: the library is complete without a question bank, and
    /// nothing here should keep one alive.
    @ObservationIgnored weak var studySink: StudyItemSink?

    private let localDir: URL
    private var metadataQuery: NSMetadataQuery?
    private var cloudObserverTokens: [NSObjectProtocol] = []
    private var appObserverToken: NSObjectProtocol?
    private let recordingsName = "recordings.json"
    private let brainsName = "brains.json"

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        localDir = support.appendingPathComponent("CatchMeUp", isDirectory: true)
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        audio = AudioStorage(localRoot: localDir)

        refreshSyncMode()
        load()
        SpotlightIndexer.replace(with: recordings)

        appObserverToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.mergeFromDisk() }
        }
    }

    // MARK: - Where data lives

    var syncEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "iCloudSync") }
        set { setSyncEnabled(newValue) }
    }

    /// Flipping the toggle now starts a real migration instead of doing a
    /// blocking copy inline — see `migrate(toCloud:)`.
    func setSyncEnabled(_ enabled: Bool) {
        guard enabled != syncEnabled else { return }
        UserDefaults.standard.set(enabled, forKey: "iCloudSync")
        refreshSyncMode()
        Task { await migrate(toCloud: enabled) }
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
        audio.setCloudBacked(usingCloud)
        startOrStopMetadataQuery()
    }

    private var dataDir: URL {
        if usingCloud, let cloud = CloudSync.documentsURL { return cloud }
        return localDir
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

    // MARK: - Mutations

    func upsert(_ recording: Recording) {
        var r = recording
        r.updatedAt = Date()
        if let i = recordings.firstIndex(where: { $0.id == r.id }) { recordings[i] = r }
        else { recordings.append(r) }
        saveRecordings()
    }

    func delete(_ recording: Recording) {
        audio.removeAudio(for: recording)
        if let i = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[i].deleted = true
            recordings[i].updatedAt = Date()
        }
        // Tombstone the questions in the same breath. Both sides soft-delete,
        // so this still merges correctly across devices.
        studySink?.deleteItems(forRecording: recording.id)
        saveRecordings()
    }

    /// Renames a recap. The model-written title wins in the UI, so set both.
    func rename(_ recordingID: UUID, to newTitle: String) {
        let name = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[i].title = name
        if recordings[i].recap != nil { recordings[i].recap?.title = name }
        recordings[i].updatedAt = Date()
        saveRecordings()
    }

    /// Ticks an action item off (or back on).
    func updateMeeting(_ recordingID: UUID, _ change: (inout MeetingWorkspace) -> Void) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID && !$0.deleted }) else { return }
        var workspace = MeetingWorkspace.existing(for: recordings[i])
        change(&workspace)
        recordings[i].meeting = workspace
        recordings[i].updatedAt = .now
        saveRecordings()
    }

    func toggleAction(_ recordingID: UUID, index: Int) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        if let at = recordings[i].completedActions.firstIndex(of: index) {
            recordings[i].completedActions.remove(at: at)
        } else {
            recordings[i].completedActions.append(index)
        }
        recordings[i].updatedAt = Date()
        saveRecordings()
    }

    func assign(_ recordingID: UUID, toBrain brainID: UUID?) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[i].brainID = brainID
        recordings[i].updatedAt = Date()
        // Questions carry their own course, because interleaving and exam plans
        // both work off it. Moving the recap has to move them too.
        studySink?.reassign(recordingID: recordingID, toBrain: brainID)
        saveRecordings()
    }

    func setMode(_ recordingID: UUID, _ mode: Mode) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[i].mode = mode
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

    // MARK: - Audio lifecycle

    func audioUsage(target: AudioQuality) -> AudioUsage {
        audio.usage(for: sortedRecordings, brains: brains, target: target)
    }

    /// Sum of what we last measured. For a row that just needs a number —
    /// unlike `audioUsage(target:)`, this doesn't stat every file, so it's safe
    /// to read from a view body.
    var estimatedAudioBytes: Int64 {
        sortedRecordings.reduce(0) { $0 + ($1.hasAudio ? ($1.audioBytes ?? 0) : 0) }
    }

    /// Stores what we measured about a file. Called after every recording and
    /// import so the storage screen never has to guess.
    func noteAudioFacts(_ recordingID: UUID, _ facts: AudioFacts) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[i].apply(facts)
        recordings[i].updatedAt = Date()
        saveRecordings()
    }

    /// Settles the prequestion offer for a recap. Called when the sheet closes
    /// and also when the recap is opened somewhere a pretest makes no sense —
    /// either way the offer is spent, because it can only be made before the
    /// first read.
    func notePretest(_ recordingID: UUID, asked: Int, correct: Int) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }),
              recordings[i].pretestedAt == nil else { return }
        recordings[i].pretestedAt = Date()
        recordings[i].pretestAsked = asked
        recordings[i].pretestCorrect = correct
        recordings[i].updatedAt = Date()
        saveRecordings()
    }

    /// What retention and cloud eviction both key off.
    func markPlayed(_ recordingID: UUID) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[i].lastPlayedAt = Date()
        recordings[i].updatedAt = Date()
        saveRecordings()
    }

    /// Pins audio so nothing automatic will remove it from this device.
    func setKeepDownloaded(_ recordingID: UUID, _ keep: Bool) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        recordings[i].keepAudioDownloaded = keep
        recordings[i].updatedAt = Date()
        saveRecordings()
    }

    /// Deletes the audio and keeps the notes, transcript and bookmarks — the
    /// "Notes only" action. Permanent, and it propagates to other devices,
    /// because the user asked for the recording to be gone.
    func removeAudio(_ recordingID: UUID) {
        guard let i = recordings.firstIndex(where: { $0.id == recordingID }) else { return }
        audio.removeAudio(for: recordings[i])
        recordings[i].audioRemoved = true
        recordings[i].audioBytes = 0
        recordings[i].keepAudioDownloaded = false
        recordings[i].updatedAt = Date()
        saveRecordings()
    }

    /// Reclaims space by dropping this device's copy while iCloud keeps the
    /// original. Deliberately not written to the model: another device shouldn't
    /// learn anything from us tidying up locally.
    func freeLocalCopy(_ recordingID: UUID) throws {
        guard let recording = recording(recordingID) else { return }
        try audio.freeLocalCopy(for: recording)
    }

    /// Recordings whose notes are written, so clearing the audio loses nothing
    /// the user has read.
    func recordingsWithCompletedNotes() -> [Recording] {
        sortedRecordings.filter { $0.hasAudio && $0.isProcessed && !$0.keepAudioDownloaded }
    }

    @discardableResult
    func removeAudioForCompletedNotes() -> Int {
        let targets = recordingsWithCompletedNotes()
        for recording in targets { removeAudio(recording.id) }
        return targets.count
    }

    /// Applies a retention window.
    ///
    /// `allowLocalDeletion` is the safety catch: when this device holds the only
    /// copy, nothing happens unless the user has explicitly accepted that the
    /// cleanup can't be undone.
    @discardableResult
    func applyRetention(_ policy: AudioRetention, allowLocalDeletion: Bool) -> Int {
        guard let cutoff = policy.cutoff() else { return 0 }
        var cleared = 0
        for recording in sortedRecordings
        where recording.hasAudio && recording.isProcessed && !recording.keepAudioDownloaded {
            guard (recording.lastPlayedAt ?? recording.createdAt) < cutoff else { continue }
            let state = audio.availability(for: recording)
            if state.canFreeLocalCopy {
                try? freeLocalCopy(recording.id)
                cleared += 1
            } else if state == .onDevice, allowLocalDeletion {
                removeAudio(recording.id)
                cleared += 1
            }
        }
        return cleared
    }

    /// With Optimize Storage on: keep the newest and the pinned on the device
    /// and let iCloud hold the rest. Only ever touches audio iCloud already has
    /// a copy of, so there's nothing to lose here.
    @discardableResult
    func freeSpaceForOlderCloudAudio(keepingNewest keepRecent: Int = 10) -> Int {
        let stale = Date.now.addingTimeInterval(-7 * 24 * 60 * 60)
        var freed = 0
        for recording in sortedRecordings.filter({ $0.hasAudio && !$0.keepAudioDownloaded })
            .dropFirst(keepRecent) {
            guard audio.availability(for: recording).canFreeLocalCopy else { continue }
            // Something played this week is still recent to whoever played it.
            if let played = recording.lastPlayedAt, played > stale { continue }
            try? audio.freeLocalCopy(for: recording)
            freed += 1
        }
        return freed
    }

    /// Files nothing points at — usually a recording abandoned before it saved.
    ///
    /// Only ever called from an explicit tap. An empty library means the
    /// metadata failed to load rather than that every file is garbage, so that
    /// case bails out instead of clearing the whole folder.
    @discardableResult
    func removeOrphanedAudio() -> Int {
        let live = recordings.filter { !$0.deleted }
        guard !live.isEmpty else { return 0 }
        let orphans = audio.orphanedFiles(keeping: live)
        for file in orphans { try? FileManager.default.removeItem(at: file) }
        return orphans.count
    }

    // MARK: - Persistence

    /// Must match `write` — the encoder emits ISO-8601 dates, so the decoder
    /// has to be told to read them that way or every load fails silently.
    private static func makeDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    private func load() {
        let dec = Self.makeDecoder()
        if let d = coordinatedRead(recordingsFile), let r = try? dec.decode([Recording].self, from: d) {
            recordings = r
        }
        if let d = coordinatedRead(brainsFile), let b = try? dec.decode([Brain].self, from: d) {
            brains = b
        }
    }

    private func saveRecordings() {
        write(recordings, to: recordingsFile)
        SpotlightIndexer.replace(with: recordings)
    }
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
        let dec = Self.makeDecoder()
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

    enum MigrationState: Equatable {
        case idle
        case metadata
        case audio(done: Int, total: Int)
        case finished(CloudSync.Report)

        var isRunning: Bool {
            switch self {
            case .metadata, .audio: return true
            default: return false
            }
        }

        var text: String {
            switch self {
            case .idle: return ""
            case .metadata: return "Moving your notes…"
            case .audio(let done, let total):
                return total > 0 ? "Moving audio — \(done) of \(total)" : "Moving audio…"
            case .finished(let report): return report.summary
            }
        }
    }

    /// Moves metadata and audio when the iCloud toggle changes.
    ///
    /// Metadata is unioned rather than copied. The old version skipped the copy
    /// whenever the destination already had a `recordings.json` — which is
    /// exactly the case where another device had synced first — and the
    /// subsequent `load()` then overwrote every recap that existed only here.
    private func migrate(toCloud: Bool) async {
        guard let cloudDocs = CloudSync.documentsURL else {
            load()
            mergeFromDisk()
            return
        }

        migration = .metadata
        unionMetadata(into: toCloud ? cloudDocs : localDir)

        migration = .audio(done: 0, total: 0)
        let onProgress: @Sendable (Int, Int) -> Void = { [weak self] done, total in
            Task { @MainActor in self?.migration = .audio(done: done, total: total) }
        }
        let cloudAudio = cloudDocs.appendingPathComponent(AudioStorage.folderName, isDirectory: true)
        let report = toCloud
            ? await CloudMigration.moveToCloud(from: audio.localDirectory, to: cloudAudio,
                                               progress: onProgress)
            : await CloudMigration.copyFromCloud(from: cloudAudio, to: audio.localDirectory,
                                                 progress: onProgress)

        migration = .finished(CloudSync.Report(report, toCloud: toCloud))
        mergeFromDisk()
    }

    /// Brings both copies of the metadata together and writes the result where
    /// the app is about to start reading from.
    private func unionMetadata(into destination: URL) {
        let decoder = Self.makeDecoder()
        var mergedRecordings = recordings
        var mergedBrains = brains

        for root in [localDir, CloudSync.documentsURL].compactMap({ $0 }) {
            if let data = coordinatedRead(root.appendingPathComponent(recordingsName)),
               let incoming = try? decoder.decode([Recording].self, from: data) {
                mergedRecordings = Self.merge(local: mergedRecordings, remote: incoming) { $0.id }
                    newer: { $0.updatedAt }
            }
            if let data = coordinatedRead(root.appendingPathComponent(brainsName)),
               let incoming = try? decoder.decode([Brain].self, from: data) {
                mergedBrains = Self.merge(local: mergedBrains, remote: incoming) { $0.id }
                    newer: { $0.updatedAt }
            }
        }

        recordings = mergedRecordings
        brains = mergedBrains
        write(recordings, to: destination.appendingPathComponent(recordingsName))
        write(brains, to: destination.appendingPathComponent(brainsName))
        SpotlightIndexer.replace(with: recordings)
    }

    func clearMigrationNotice() {
        if case .finished = migration { migration = .idle }
    }

    /// Sweeps up audio that landed locally while iCloud was unavailable —
    /// recorded on a flight, or before the container had spun up.
    ///
    /// `AudioStorage` looks in both folders, so these files always played; the
    /// problem this fixes is that they were never actually backed up.
    func reconcileCloudAudio() async {
        guard usingCloud, !migration.isRunning,
              let cloudAudio = audio.cloudDirectory else { return }

        let strays = (try? FileManager.default.contentsOfDirectory(
            at: audio.localDirectory, includingPropertiesForKeys: nil
        )) ?? []
        guard strays.contains(where: { !$0.lastPathComponent.hasPrefix(".") }) else { return }

        migration = .audio(done: 0, total: 0)
        let report = await CloudMigration.moveToCloud(
            from: audio.localDirectory, to: cloudAudio
        ) { [weak self] done, total in
            Task { @MainActor in self?.migration = .audio(done: done, total: total) }
        }
        migration = report.moved > 0 ? .finished(CloudSync.Report(report, toCloud: true)) : .idle
    }

    // MARK: - Demo seed

    func seedSampleIfEmpty() {
        guard sortedRecordings.isEmpty else { return }
        recordings = SampleData.recordings
        saveRecordings()
    }
}
