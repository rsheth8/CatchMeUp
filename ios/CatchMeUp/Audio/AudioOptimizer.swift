import Foundation
import Observation

/// Re-encodes existing audio down to the target format, one recording at a time.
///
/// The rules that matter: the original is never touched until a verified
/// replacement exists, a conversion that fails or doesn't save anything leaves
/// the file exactly as it was, and the whole run can be stopped and picked up
/// again later.
@MainActor
@Observable
final class AudioOptimizer {
    struct Progress: Equatable, Sendable {
        var completed = 0
        var total = 0
        var title = ""
        /// How far through the current file, 0…1.
        var fileFraction: Double = 0
        var bytesSaved: Int64 = 0

        var fraction: Double {
            guard total > 0 else { return 0 }
            return min(1, (Double(completed) + fileFraction) / Double(total))
        }
    }

    struct Report: Equatable, Sendable {
        var converted = 0
        var skipped = 0
        var failed = 0
        var bytesSaved: Int64 = 0

        var isEmpty: Bool { converted == 0 && skipped == 0 && failed == 0 }
    }

    enum State: Equatable {
        case idle
        /// Reading the library to find out what's there — Phase 6, step 1.
        case scanning(Double)
        case running(Progress)
        case paused(Progress)
        case finished(Report)

        var isBusy: Bool {
            switch self {
            case .scanning, .running: return true
            default: return false
            }
        }

        var isPaused: Bool { if case .paused = self { return true } else { return false } }

        var progress: Progress? {
            switch self {
            case .running(let p), .paused(let p): return p
            default: return nil
            }
        }
    }

    private(set) var state: State = .idle

    private var task: Task<Void, Never>?
    /// What's left to do. Kept outside the task so pausing can throw the
    /// in-flight conversion away and still resume from the right place.
    private var queue: [UUID] = []
    private var tally = Report()

    var canResume: Bool { state.isPaused && !queue.isEmpty }

    // MARK: - Scanning

    /// Measures every audio file and writes the results back onto the
    /// recordings, so eligibility and savings estimates rest on facts rather
    /// than on what the file extension claims.
    func scanLibrary(store: LibraryStore) async {
        let candidates = store.sortedRecordings.filter { $0.hasAudio && $0.audioFacts == nil }
        guard !candidates.isEmpty else { return }

        state = .scanning(0)
        for (index, recording) in candidates.enumerated() {
            if Task.isCancelled { break }
            if let facts = await store.audio.facts(for: recording),
               var fresh = store.recording(recording.id) {
                fresh.apply(facts)
                store.upsert(fresh)
            }
            state = .scanning(Double(index + 1) / Double(candidates.count))
        }
        if case .scanning = state { state = .idle }
    }

    // MARK: - Running

    func start(store: LibraryStore, target: AudioQuality) {
        guard !state.isBusy else { return }
        tally = Report()
        queue = []
        run(store: store, target: target, rescan: true)
    }

    /// Converts a single recording — a fresh import, or one row of the storage
    /// screen. Joins the back of a run that's already going rather than
    /// competing with it for the encoder.
    func optimize(_ recordingID: UUID, store: LibraryStore, target: AudioQuality) {
        guard !queue.contains(recordingID) else { return }
        guard !state.isBusy, !state.isPaused else {
            queue.append(recordingID)
            return
        }
        tally = Report()
        queue = [recordingID]
        run(store: store, target: target, rescan: false)
    }

    func pause() {
        let snapshot = state.progress ?? Progress()
        task?.cancel()
        task = nil
        state = .paused(snapshot)
    }

    func resume(store: LibraryStore, target: AudioQuality) {
        guard canResume else { return }
        run(store: store, target: target, rescan: false)
    }

    func cancel() {
        task?.cancel()
        task = nil
        queue = []
        state = .idle
    }

    func dismissReport() {
        if case .finished = state { state = .idle }
    }

    private func run(store: LibraryStore, target: AudioQuality, rescan: Bool) {
        task = Task { [weak self] in
            guard let self else { return }
            if rescan { await self.scanLibrary(store: store) }
            if Task.isCancelled { return }

            if self.queue.isEmpty {
                // Biggest first, so the number on screen moves early.
                self.queue = store.sortedRecordings
                    .filter { $0.needsOptimizing(target: target) }
                    .sorted { store.audio.bytes(for: $0) > store.audio.bytes(for: $1) }
                    .map(\.id)
            }
            guard !self.queue.isEmpty else {
                self.state = .finished(self.tally)
                self.task = nil
                return
            }

            while let next = self.queue.first {
                if Task.isCancelled { return }
                // Recomputed each pass: an import can join the queue mid-run.
                let done = self.tally.converted + self.tally.skipped + self.tally.failed
                self.state = .running(Progress(completed: done,
                                               total: done + self.queue.count,
                                               title: store.recording(next)?.displayTitle ?? "",
                                               bytesSaved: self.tally.bytesSaved))

                let outcome = await self.convert(next, store: store, target: target)
                if case .cancelled = outcome { return }

                // Only drop it from the queue once it's genuinely dealt with,
                // so a pause mid-file resumes on the same recording.
                self.queue.removeFirst()
                switch outcome {
                case .converted(let saved):
                    self.tally.converted += 1
                    self.tally.bytesSaved += saved
                case .skipped: self.tally.skipped += 1
                case .failed: self.tally.failed += 1
                case .cancelled: break
                }
            }

            self.state = .finished(self.tally)
            self.task = nil
        }
    }

    // MARK: - One conversion

    private enum Outcome {
        case converted(saved: Int64)
        case skipped
        case failed
        case cancelled
    }

    /// Updates only the "how far through this file" part of a live run.
    private func noteFileProgress(_ fraction: Double) {
        guard case .running(var progress) = state else { return }
        progress.fileFraction = fraction
        state = .running(progress)
    }

    private func convert(_ recordingID: UUID, store: LibraryStore, target: AudioQuality) async -> Outcome {
        guard let recording = store.recording(recordingID), recording.hasAudio else { return .skipped }

        // Cloud-only audio has to come down before it can be re-encoded. If it
        // won't, leave it be — it isn't costing device space anyway.
        let source: URL
        do { source = try await store.audio.ensureLocal(for: recording) }
        catch is CancellationError { return .cancelled }
        catch { return .skipped }

        let before = AudioFile.byteSize(at: source) ?? 0
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("optimize-\(recordingID.uuidString).\(AudioQuality.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let gate = ProgressGate()
        do {
            let facts = try await AudioTranscoder.encode(source, to: temporary, quality: target) { fraction in
                guard gate.shouldReport(fraction) else { return }
                Task { @MainActor [weak self] in self?.noteFileProgress(fraction) }
            }

            if Task.isCancelled { return .cancelled }

            // A conversion that doesn't win isn't worth making — re-encoding
            // lossy audio always costs a little fidelity. Flag it so the run
            // doesn't come back to the same file every time.
            guard before > 0, facts.byteSize < before else {
                if var fresh = store.recording(recordingID) {
                    fresh.optimizeFailed = true
                    store.upsert(fresh)
                }
                return .skipped
            }

            let filename = try store.audio.replaceAudio(for: recording, with: temporary)
            guard var fresh = store.recording(recordingID) else { return .skipped }
            fresh.audioFilename = filename
            fresh.apply(facts)
            fresh.optimizeFailed = false
            store.upsert(fresh)
            return .converted(saved: before - facts.byteSize)
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard var fresh = store.recording(recordingID) else { return .failed }
            fresh.optimizeFailed = true
            store.upsert(fresh)
            return .failed
        }
    }
}
