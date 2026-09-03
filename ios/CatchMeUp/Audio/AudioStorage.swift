import Foundation
import Observation

// MARK: - Where a recording's audio is right now

enum AudioAvailability: Equatable, Sendable {
    /// No audio was ever attached, or the user kept the notes and dropped it.
    case none
    /// The only copy is on this device. Deleting it is unrecoverable.
    case onDevice
    /// In iCloud and cached here.
    case downloaded
    /// In iCloud, not currently on this device.
    case inCloud
    case downloading(Double)
    /// We have a filename but the file isn't anywhere we can see.
    case missing

    /// Can it be handed to `AudioPlayer` as-is?
    var isPlayable: Bool { self == .onDevice || self == .downloaded }

    /// Is a copy taking up room on this device?
    var occupiesDevice: Bool { isPlayable }

    /// Would playing it require a download first?
    var needsDownload: Bool {
        if case .downloading = self { return true }
        return self == .inCloud
    }

    var isDownloading: Bool { if case .downloading = self { return true } else { return false } }

    /// Only true when iCloud still holds a copy — the one case where removing
    /// the local file is safe.
    var canFreeLocalCopy: Bool { self == .downloaded }

    var label: String {
        switch self {
        case .none: return "No audio"
        case .onDevice: return "On this iPhone"
        case .downloaded: return "Downloaded"
        case .inCloud: return "In iCloud"
        case .downloading(let p): return "Downloading \(Int(p * 100))%"
        case .missing: return "Audio not found"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "waveform.slash"
        case .onDevice: return "iphone"
        case .downloaded: return "checkmark.icloud"
        case .inCloud: return "icloud.and.arrow.down"
        case .downloading: return "arrow.down.circle"
        case .missing: return "exclamationmark.triangle"
        }
    }
}

enum AudioStorageError: LocalizedError {
    case noAudio
    case notInCloud
    case downloadTimedOut
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .noAudio: return "This recap doesn't have any audio."
        case .notInCloud: return "This is the only copy of the audio, so it can't be removed to save space."
        case .downloadTimedOut: return "The audio is taking a long time to come down from iCloud. Check your connection and try again."
        case .downloadFailed(let why): return why
        }
    }
}

// MARK: - Usage

/// One recording's worth of the storage dashboard.
struct AudioEntry: Identifiable, Equatable, Sendable {
    var recordingID: UUID
    var title: String
    var brainID: UUID?
    var createdAt: Date
    var lastPlayedAt: Date?
    var duration: Double
    var bytes: Int64
    var availability: AudioAvailability
    var isPinned: Bool
    var hasNotes: Bool
    var canOptimize: Bool
    var format: String?

    var id: UUID { recordingID }

    /// Bytes this recording is costing us on this device.
    var deviceBytes: Int64 { availability.occupiesDevice ? bytes : 0 }
}

struct BrainUsage: Identifiable, Equatable, Sendable {
    var brainID: UUID?
    var name: String
    var bytes: Int64
    var count: Int

    var id: String { brainID?.uuidString ?? "unfiled" }
}

struct AudioUsage: Equatable, Sendable {
    var entries: [AudioEntry] = []

    /// Everything the library holds, wherever it lives.
    var totalBytes: Int64 = 0
    /// The part of that sitting on this device.
    var deviceBytes: Int64 = 0
    var fileCount: Int = 0
    var missingCount: Int = 0
    var inCloudCount: Int = 0

    /// Files that aren't yet in the target format.
    var optimizableCount: Int = 0
    var optimizableBytes: Int64 = 0
    /// What those files would weigh afterwards.
    var projectedBytes: Int64 = 0

    var byBrain: [BrainUsage] = []

    var estimatedSaving: Int64 { max(0, optimizableBytes - projectedBytes) }

    /// Audio whose notes are already written — safe to clear without losing work.
    var completedBytes: Int64 = 0
    var completedCount: Int = 0

    /// Missing files are left out — they'd show a remembered size for something
    /// that isn't anywhere, which reads as a bug.
    var largest: [AudioEntry] {
        entries
            .filter { $0.bytes > 0 && $0.availability != .missing }
            .sorted { $0.bytes > $1.bytes }
    }
}

// MARK: - The storage manager

/// The single owner of audio files on disk.
///
/// Everything else — playback, the pipeline, the library, the dashboard — asks
/// this object where a recording's audio is and what shape it's in, so no view
/// has to know whether the user turned on iCloud.
@MainActor
@Observable
final class AudioStorage {
    static let folderName = "audio"

    private(set) var isCloudBacked = false

    /// Live download state keyed by filename, fed by the metadata query below.
    private(set) var cloudItems: [String: CloudItem] = [:]
    /// Downloads this app kicked off, so the player can show progress even
    /// before iCloud publishes any metadata.
    private var pendingDownloads: Set<String> = []

    private let localRoot: URL
    /// The query lives outside actor isolation so it can be torn down in
    /// `deinit`, which isn't allowed to touch main-actor state.
    private let queries = QueryBox()

    struct CloudItem: Equatable, Sendable {
        var isDownloaded: Bool
        var isDownloading: Bool
        var percent: Double        // 0…1
        var bytes: Int64
    }

    init(localRoot: URL) {
        self.localRoot = localRoot
        try? FileManager.default.createDirectory(at: localDirectory, withIntermediateDirectories: true)
    }

    // MARK: Locations

    /// Where new files go.
    var directory: URL {
        let dir = (isCloudBacked ? cloudDirectory : nil) ?? localDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    var localDirectory: URL {
        localRoot.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    var cloudDirectory: URL? {
        CloudSync.documentsURL?.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// Both possible homes, active one first. Looking in both means a half-
    /// finished migration degrades to "slower" rather than "your audio is gone".
    private var searchRoots: [URL] {
        var roots = [directory]
        for candidate in [localDirectory, cloudDirectory].compactMap({ $0 }) where candidate != roots[0] {
            roots.append(candidate)
        }
        return roots
    }

    func setCloudBacked(_ enabled: Bool) {
        guard enabled != isCloudBacked else { return }
        isCloudBacked = enabled
        cloudItems.removeAll()
        startOrStopQuery()
    }

    func newFilename() -> String { "\(UUID().uuidString).\(AudioQuality.fileExtension)" }

    /// The file for `name`, wherever it actually sits. Nil when nothing — not
    /// even an iCloud placeholder — can be found.
    func location(of name: String) -> URL? {
        let fm = FileManager.default
        for root in searchRoots {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
            if fm.fileExists(atPath: Self.placeholder(for: url).path) { return url }
        }
        return nil
    }

    /// A URL only if the bytes are here now. This is what playback should use.
    func playableURL(for recording: Recording) -> URL? {
        guard let name = recording.audioFilename, !recording.audioRemoved else { return nil }
        let fm = FileManager.default
        for root in searchRoots {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// iCloud replaces an evicted `foo.m4a` with a `.foo.m4a.icloud` stub.
    private static func placeholder(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    // MARK: State

    func availability(for recording: Recording) -> AudioAvailability {
        guard let name = recording.audioFilename, !recording.audioRemoved else { return .none }
        let fm = FileManager.default

        if let item = cloudItems[name] {
            if item.isDownloading { return .downloading(item.percent) }
            if item.isDownloaded { return .downloaded }
        }
        if pendingDownloads.contains(name) { return .downloading(cloudItems[name]?.percent ?? 0) }

        for root in searchRoots {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                let ubiquitous = (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]))?
                    .isUbiquitousItem ?? false
                return ubiquitous ? .downloaded : .onDevice
            }
            if fm.fileExists(atPath: Self.placeholder(for: url).path) { return .inCloud }
        }
        return cloudItems[name] != nil ? .inCloud : .missing
    }

    /// How big the file is, whether or not it's downloaded. Falls back to the
    /// size recorded on the model so cloud-only rows still show a number.
    func bytes(for recording: Recording) -> Int64 {
        guard let name = recording.audioFilename, !recording.audioRemoved else { return 0 }
        if let url = playableURL(for: recording), let size = AudioFile.byteSize(at: url) { return size }
        if let cloud = cloudItems[name]?.bytes, cloud > 0 { return cloud }
        return recording.audioBytes ?? 0
    }

    /// Reads the file and returns what it really is. Use when correctness
    /// matters more than speed — importing, optimizing, or a library scan.
    func facts(for recording: Recording) async -> AudioFacts? {
        guard let url = playableURL(for: recording) else { return nil }
        return await AudioFile.facts(at: url)
    }

    // MARK: Bringing audio down from iCloud

    /// Makes sure the bytes are on this device, downloading if they aren't.
    @discardableResult
    func ensureLocal(for recording: Recording, timeout: TimeInterval = 180) async throws -> URL {
        if let ready = playableURL(for: recording) { return ready }
        guard let name = recording.audioFilename, !recording.audioRemoved else {
            throw AudioStorageError.noAudio
        }
        guard let url = location(of: name) else { throw AudioStorageError.noAudio }

        do { try FileManager.default.startDownloadingUbiquitousItem(at: url) }
        catch { throw AudioStorageError.downloadFailed(error.localizedDescription) }

        pendingDownloads.insert(name)
        defer { pendingDownloads.remove(name) }

        let deadline = Date.now.addingTimeInterval(timeout)
        while Date.now < deadline {
            try Task.checkCancellation()
            if let ready = playableURL(for: recording) { return ready }
            if let error = downloadError(at: url) { throw AudioStorageError.downloadFailed(error) }
            try? await Task.sleep(for: .milliseconds(350))
        }
        throw AudioStorageError.downloadTimedOut
    }

    private func downloadError(at url: URL) -> String? {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingErrorKey])
        return (values?.ubiquitousItemDownloadingError as NSError?)?.localizedDescription
    }

    /// Drops the local copy but leaves the file in iCloud. Refuses when iCloud
    /// isn't holding one, because then this *is* the copy.
    func freeLocalCopy(for recording: Recording) throws {
        guard availability(for: recording).canFreeLocalCopy else { throw AudioStorageError.notInCloud }
        guard let name = recording.audioFilename,
              let url = location(of: name) else { throw AudioStorageError.noAudio }
        try FileManager.default.evictUbiquitousItem(at: url)
    }

    // MARK: Writing

    /// Copies an imported file in unchanged. Converting it here would make the
    /// user wait on a progress bar before they see anything; `AudioOptimizer`
    /// picks it up straight afterwards.
    func importFile(from source: URL) async -> (filename: String, facts: AudioFacts?)? {
        let ext = source.pathExtension.isEmpty ? AudioQuality.fileExtension : source.pathExtension
        let name = "\(UUID().uuidString).\(ext.lowercased())"
        let destination = directory.appendingPathComponent(name)

        // A lecture recording can be hundreds of megabytes, so the copy itself
        // goes off the main actor.
        let copied = await Task.detached(priority: .userInitiated) { () -> Bool in
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do { try FileManager.default.copyItem(at: source, to: destination); return true }
            catch { return false }
        }.value

        guard copied else { return nil }
        return (name, await AudioFile.facts(at: destination))
    }

    /// Swaps a freshly encoded temporary file in for the original, in one move.
    /// The original is only unlinked once the replacement is in place.
    @discardableResult
    func replaceAudio(for recording: Recording, with temporary: URL) throws -> String {
        guard let name = recording.audioFilename,
              let existing = location(of: name) else { throw AudioStorageError.noAudio }

        // Keep the extension honest — an imported `.mp3` becomes real AAC.
        let finalName = (name as NSString).deletingPathExtension + ".\(AudioQuality.fileExtension)"
        let destination = existing.deletingLastPathComponent().appendingPathComponent(finalName)

        var coordinationError: NSError?
        var thrown: Error?
        NSFileCoordinator().coordinate(writingItemAt: destination, options: .forReplacing,
                                       error: &coordinationError) { target in
            do {
                if FileManager.default.fileExists(atPath: target.path) {
                    _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
            } catch {
                thrown = error
            }
        }
        if let thrown { throw thrown }
        if let coordinationError { throw coordinationError }

        // The container changed, so the old `.mp3` (or `.wav`) is now dead weight.
        if finalName != name { removeFile(named: name) }
        return finalName
    }

    /// Deletes the audio outright, everywhere. There is no undo.
    func removeAudio(for recording: Recording) {
        guard let name = recording.audioFilename else { return }
        removeFile(named: name)
    }

    private func removeFile(named name: String) {
        let fm = FileManager.default
        for root in searchRoots {
            let url = root.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                var error: NSError?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting,
                                               error: &error) { target in
                    try? fm.removeItem(at: target)
                }
                if error != nil { try? fm.removeItem(at: url) }
            }
            let stub = Self.placeholder(for: url)
            if fm.fileExists(atPath: stub.path) { try? fm.removeItem(at: stub) }
        }
        cloudItems[name] = nil
    }

    /// Files in the audio folder that no live recording points at — usually the
    /// leftovers of a recording discarded before it was saved.
    func orphanedFiles(keeping recordings: [Recording]) -> [URL] {
        let claimed = Set(recordings.compactMap(\.audioFilename))
        var orphans: [URL] = []
        for root in searchRoots {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where !claimed.contains(file.lastPathComponent) {
                guard !file.lastPathComponent.hasPrefix(".") else { continue }
                orphans.append(file)
            }
        }
        return orphans
    }

    // MARK: Usage

    func usage(for recordings: [Recording], brains: [Brain], target: AudioQuality) -> AudioUsage {
        var usage = AudioUsage()
        var perBrain: [UUID?: (bytes: Int64, count: Int)] = [:]

        for recording in recordings where recording.audioFilename != nil {
            let availability = availability(for: recording)
            if availability == .none { continue }

            let size = bytes(for: recording)
            let needsWork = recording.needsOptimizing(target: target) && availability.isPlayable

            let entry = AudioEntry(
                recordingID: recording.id,
                title: recording.displayTitle,
                brainID: recording.brainID,
                createdAt: recording.createdAt,
                lastPlayedAt: recording.lastPlayedAt,
                duration: recording.duration,
                bytes: size,
                availability: availability,
                isPinned: recording.keepAudioDownloaded,
                hasNotes: recording.isProcessed,
                canOptimize: needsWork,
                format: recording.audioFormatLabel
            )
            usage.entries.append(entry)

            if availability == .missing {
                usage.missingCount += 1
                continue
            }

            usage.fileCount += 1
            usage.totalBytes += size
            usage.deviceBytes += entry.deviceBytes
            if availability == .inCloud { usage.inCloudCount += 1 }

            if needsWork {
                usage.optimizableCount += 1
                usage.optimizableBytes += size
                usage.projectedBytes += Self.projectedBytes(for: recording, size: size, target: target)
            }
            if recording.isProcessed {
                usage.completedCount += 1
                usage.completedBytes += size
            }

            let bucket = perBrain[recording.brainID] ?? (0, 0)
            perBrain[recording.brainID] = (bucket.bytes + size, bucket.count + 1)
        }

        usage.byBrain = perBrain.map { brainID, bucket in
            let name = brainID.flatMap { id in brains.first { $0.id == id && !$0.deleted }?.name }
            return BrainUsage(brainID: brainID, name: name ?? "Not in a brain",
                              bytes: bucket.bytes, count: bucket.count)
        }
        .sorted { $0.bytes > $1.bytes }

        return usage
    }

    /// What a file would weigh at the target format. Duration is the honest
    /// basis; when we don't know it, assume a conservative 40% saving so the
    /// estimate never over-promises.
    private static func projectedBytes(for recording: Recording, size: Int64,
                                       target: AudioQuality) -> Int64 {
        guard recording.duration > 0 else { return Int64(Double(size) * 0.6) }
        let projected = Int64(recording.duration / 3600 * Double(target.bytesPerHour))
        return min(size, max(projected, 1))
    }

    // MARK: Live iCloud state

    private func startOrStopQuery() {
        queries.stop()
        guard isCloudBacked, let audioDir = cloudDirectory else { return }

        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUbiquitousDocumentsScope]
        q.predicate = NSPredicate(format: "%K BEGINSWITH %@", NSMetadataItemPathKey, audioDir.path)
        q.valueListAttributes = [
            NSMetadataUbiquitousItemDownloadingStatusKey,
            NSMetadataUbiquitousItemIsDownloadingKey,
            NSMetadataUbiquitousItemPercentDownloadedKey,
            NSMetadataItemFSSizeKey,
        ]
        for name: NSNotification.Name in [.NSMetadataQueryDidUpdate, .NSMetadataQueryDidFinishGathering] {
            let token = NotificationCenter.default.addObserver(
                forName: name, object: q, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.absorb(q) }
            }
            queries.tokens.append(token)
        }
        q.start()
        queries.query = q
    }

    private func absorb(_ query: NSMetadataQuery) {
        query.disableUpdates()
        defer { query.enableUpdates() }

        var found: [String: CloudItem] = [:]
        for row in 0..<query.resultCount {
            guard let item = query.result(at: row) as? NSMetadataItem,
                  let name = item.value(forAttribute: NSMetadataItemFSNameKey) as? String
            else { continue }

            let status = item.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
            let downloading = item.value(forAttribute: NSMetadataUbiquitousItemIsDownloadingKey) as? Bool ?? false
            let percent = item.value(forAttribute: NSMetadataUbiquitousItemPercentDownloadedKey) as? Double ?? 0
            let size = item.value(forAttribute: NSMetadataItemFSSizeKey) as? Int64 ?? 0

            let isDownloaded = status == NSMetadataUbiquitousItemDownloadingStatusCurrent
                || status == NSMetadataUbiquitousItemDownloadingStatusDownloaded
            found[name] = CloudItem(isDownloaded: isDownloaded,
                                    isDownloading: downloading && !isDownloaded,
                                    percent: min(1, max(0, percent / 100)),
                                    bytes: size)
        }
        if found != cloudItems { cloudItems = found }
    }
}

/// Owns the `NSMetadataQuery` and its observers so they can be released when
/// `AudioStorage` goes away.
private final class QueryBox: @unchecked Sendable {
    var query: NSMetadataQuery?
    var tokens: [NSObjectProtocol] = []

    func stop() {
        query?.stop()
        query = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
    }

    deinit { stop() }
}
