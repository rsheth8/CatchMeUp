import Foundation
import Observation
import UIKit

/// The one place recordings get turned into recaps.
///
/// This used to live in `@State` on the recap screen, which meant navigating
/// back cancelled the work half-done and left an error on a recording the user
/// hadn't touched. It's app-scoped now: jobs outlive whatever view started
/// them, run one at a time, hold a background assertion so a swipe away doesn't
/// suspend them mid-sentence, and park themselves for a `BGProcessingTask`
/// rather than dying when iOS finally runs out of patience.
@MainActor
@Observable
final class ProcessingQueue {
    static let shared = ProcessingQueue()

    // MARK: Types

    enum Phase: Equatable {
        case queued
        case transcribing(Double)
        case writing(Double)
        /// Background time ran out. Not an error — it will resume.
        case paused
        case done
        case failed(String)

        var isActive: Bool {
            switch self {
            case .transcribing, .writing: return true
            default: return false
            }
        }

        var isFinished: Bool {
            switch self {
            case .done, .failed: return true
            default: return false
            }
        }

        /// Index into the three steps the UI draws.
        var step: Int {
            switch self {
            case .queued: return 0
            case .transcribing: return 0
            case .writing: return 1
            case .paused: return 1
            case .done: return 2
            case .failed: return 1
            }
        }

        var label: String {
            switch self {
            case .queued: return "Waiting its turn"
            case .transcribing: return "Transcribing on device"
            case .writing: return "Writing your notes"
            case .paused: return "Paused — will finish shortly"
            case .done: return "Your recap is ready"
            case .failed: return "Something went wrong"
            }
        }

        var symbol: String {
            switch self {
            case .queued: return "clock"
            case .transcribing: return "waveform"
            case .writing: return "sparkles"
            case .paused: return "pause.circle"
            case .done: return "checkmark.circle.fill"
            case .failed: return "exclamationmark.triangle.fill"
            }
        }
    }

    struct Job: Identifiable, Equatable {
        let id: UUID
        var title: String
        var mode: Mode
        var phase: Phase = .queued
        /// Length of the audio, which is what the transcription estimate keys off.
        var audioSeconds: Double = 0
        /// Known once there's a transcript; estimated from the audio before that.
        var transcriptCharacters: Int = 0
        var startedAt: Date?
        var phaseStartedAt: Date?
        /// Re-running only the notes step, e.g. after switching engine.
        var rewriteOnly = false

        /// User-facing phase, including which notes we're writing so the card
        /// isn't a mystery when restyling a lecture as a meeting.
        var displayLabel: String {
            if case .writing = phase {
                return mode == .lecture ? "Writing lecture notes" : "Writing meeting notes"
            }
            return phase.label
        }
        /// Seconds left, or nil when we genuinely don't know yet.
        var etaSeconds: Double?

        /// Fraction of the whole job, weighted by how long each step really takes.
        /// A flat "step 1 of 2" bar jumps to 50% in the first second and then
        /// sits there, which reads as a hang.
        func overallProgress(_ rates: ProcessingRates) -> Double {
            let transcribeCost = rewriteOnly ? 0 : rates.transcribeSeconds(audioSeconds: audioSeconds)
            let writeCost = rates.writeSeconds(characters: transcriptCharacters)
            let total = transcribeCost + writeCost
            guard total > 0 else { return phase == .done ? 1 : 0 }

            switch phase {
            case .queued: return 0
            case .transcribing(let p): return (transcribeCost * p) / total
            case .writing(let p): return (transcribeCost + writeCost * p) / total
            case .paused: return transcribeCost / total
            case .done: return 1
            case .failed: return transcribeCost / total
            }
        }
    }

    // MARK: State

    private(set) var jobs: [Job] = []

    private var worker: Task<Void, Never>?
    /// Bumped every time a worker starts. A cancelled worker's cleanup must not
    /// tear down the assertion — or forget the handle — of the one that
    /// replaced it, which would let two run at once.
    private var workerGeneration = 0
    private let activity = BackgroundActivity()
    private let liveActivity = RecapLiveActivity()
    /// Set when iOS took our background time away, so the drain loop stops
    /// asking for more work instead of failing every remaining job.
    private var parked = false

    private var store: LibraryStore { LibraryStore.shared }
    private var settings: AppSettings { AppSettings.shared }
    private var study: StudyStore { StudyStore.shared }

    private init() {}

    // MARK: Reading state

    func job(for recordingID: UUID) -> Job? {
        jobs.first { $0.id == recordingID }
    }

    func isWorking(on recordingID: UUID) -> Bool {
        guard let job = job(for: recordingID) else { return false }
        return !job.phase.isFinished
    }

    var activeJobs: [Job] { jobs.filter { !$0.phase.isFinished } }

    /// One line for the library header: how much is left across everything.
    var summary: String? {
        let pending = activeJobs
        guard !pending.isEmpty else { return nil }
        let count = "\(pending.count) recap\(pending.count == 1 ? "" : "s")"
        let remaining = pending.compactMap(\.etaSeconds).reduce(0, +)
        if pending.contains(where: { $0.phase == .paused }) {
            return "\(count) paused — reopen to finish"
        }
        guard remaining > 0 else { return "\(count) in progress" }
        return "\(count) in progress · \(etaText(remaining)) left"
    }

    // MARK: Enqueueing

    /// Queues a recording for the full run. Safe to call repeatedly — the
    /// recap screen calls it on every appearance.
    func enqueue(_ recordingID: UUID) {
        add(recordingID, rewriteOnly: false)
    }

    /// Re-runs only the notes step, keeping the transcript we already have.
    func rewrite(_ recordingID: UUID) {
        if let index = jobs.firstIndex(where: { $0.id == recordingID }) {
            guard jobs[index].phase.isFinished else { return }
            jobs.remove(at: index)
        }
        add(recordingID, rewriteOnly: true)
    }

    /// Changes the dominant job and rewrites from the existing transcript.
    func restyle(_ recordingID: UUID, as mode: Mode) {
        store.setMode(recordingID, mode)
        if let index = jobs.firstIndex(where: { $0.id == recordingID }) {
            if jobs[index].phase.isFinished {
                jobs.remove(at: index)
            } else if case .transcribing = jobs[index].phase {
                jobs[index].mode = mode
                return
            } else {
                cancel(recordingID)
            }
        }
        guard let recording = store.recording(recordingID), !recording.segments.isEmpty else { return }
        add(recordingID, rewriteOnly: true)
    }

    /// Picks up work that was already running when the app went away. Called at
    /// launch and from the background task, which is why it reads from disk
    /// rather than trusting in-memory state a relaunch would have lost.
    ///
    /// Deliberately keyed off what was actually queued rather than "anything
    /// without a recap": a library imported from the CLI arrives with
    /// transcripts and no recaps, and firing off a job for every one of those
    /// on first launch would spend the user's API budget without being asked.
    func enqueuePendingFromStore() {
        let pending = PendingJobs.ids
        guard !pending.isEmpty else { return }
        for recording in store.sortedRecordings
        where pending.contains(recording.id) && Self.needsProcessing(recording) {
            add(recording.id, rewriteOnly: !recording.segments.isEmpty)
        }
        // Anything still listed that no longer needs work (deleted, or finished
        // on another device) shouldn't be reconsidered next launch.
        PendingJobs.keep(Set(store.sortedRecordings.filter(Self.needsProcessing).map(\.id)))
    }

    static func needsProcessing(_ recording: Recording) -> Bool {
        guard recording.recap == nil, recording.processingError == nil else { return false }
        return recording.hasAudio || !recording.segments.isEmpty
    }

    private func add(_ recordingID: UUID, rewriteOnly: Bool) {
        guard let recording = store.recording(recordingID) else { return }
        if let existing = jobs.firstIndex(where: { $0.id == recordingID }) {
            // Already finished and being asked for again means a retry.
            guard jobs[existing].phase.isFinished else { return }
            jobs.remove(at: existing)
        }

        let hasTranscript = !recording.segments.isEmpty
        var job = Job(
            id: recordingID,
            title: recording.displayTitle,
            mode: recording.mode,
            audioSeconds: recording.duration,
            rewriteOnly: rewriteOnly || (hasTranscript && recording.recap == nil)
        )
        job.transcriptCharacters = hasTranscript
            ? recording.segments.timestampedText.count
            : ProcessingRates.expectedCharacters(forAudioSeconds: recording.duration)
        job.etaSeconds = rates.estimate(
            audioSeconds: job.rewriteOnly ? 0 : job.audioSeconds,
            transcriptCharacters: job.transcriptCharacters
        )
        jobs.append(job)
        PendingJobs.insert(recordingID)
        startWorkerIfNeeded()
    }

    /// Drops a job the user no longer wants. The recording keeps whatever it
    /// already had.
    func cancel(_ recordingID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == recordingID }) else { return }
        let wasRunning = jobs[index].phase.isActive
        jobs.remove(at: index)
        PendingJobs.remove(recordingID)
        if wasRunning {
            worker?.cancel()
            worker = nil
            startWorkerIfNeeded()
        }
    }

    // MARK: The worker

    private func startWorkerIfNeeded() {
        guard worker == nil, !parked else { return }
        guard jobs.contains(where: { $0.phase == .queued }) else { return }

        RecapNotifier.prepare()
        activity.begin(name: "Writing recap notes") { [weak self] in
            self?.parkForLaterResumption()
        }

        workerGeneration += 1
        let generation = workerGeneration
        worker = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    private func drain(generation: Int) async {
        defer {
            if generation == workerGeneration {
                activity.end()
                worker = nil
            }
        }

        while !parked, !Task.isCancelled,
              let next = jobs.first(where: { $0.phase == .queued })?.id {
            await run(next)
            // Give the run loop a turn so SwiftUI can draw the finished state
            // before the next job repaints the same rows.
            await Task.yield()
        }
    }

    /// Called from the expiration handler, and from the background task when it
    /// runs out too. Leaves the job queued rather than failed: nothing went
    /// wrong, we just ran out of time to do it now.
    func parkForLaterResumption() {
        parked = true
        worker?.cancel()
        worker = nil
        activity.end()

        for index in jobs.indices where jobs[index].phase.isActive || jobs[index].phase == .queued {
            jobs[index].phase = .paused
            jobs[index].etaSeconds = nil
        }
        Task { await liveActivity.paused() }
        BackgroundRefresh.schedule(needsNetwork: settings.engineKind == .apiKey)
    }

    /// The other side of parking: run by the `BGProcessingTask`, and by the app
    /// coming back to the foreground.
    func resumeUnfinishedWork() async {
        parked = false
        for index in jobs.indices where jobs[index].phase == .paused {
            jobs[index].phase = .queued
        }
        enqueuePendingFromStore()
        startWorkerIfNeeded()
        await worker?.value
    }

    // MARK: One job

    private func run(_ recordingID: UUID) async {
        guard var recording = store.recording(recordingID) else {
            jobs.removeAll { $0.id == recordingID }
            return
        }

        let rewriteOnly = job(for: recordingID)?.rewriteOnly ?? false
        update(recordingID) { job in
            job.startedAt = Date()
            job.phase = rewriteOnly ? .writing(0) : .transcribing(0)
            job.phaseStartedAt = Date()
        }
        recording.processingError = nil

        store.upsert(withCurrentAudio(recording))
        await liveActivity.start(for: recording, phase: rewriteOnly ? .writing(0) : .transcribing(0))

        if !rewriteOnly {
            do {
                recording = try await transcribe(recording)
                recording.meeting = store.recording(recordingID)?.meeting
                store.upsert(withCurrentAudio(recording))
            } catch is CancellationError {
                markParked(recordingID)
                return
            } catch {
                fail(recordingID, recording, error.localizedDescription)
                return
            }
        }

        guard !recording.segments.isEmpty else {
            fail(recordingID, recording, "There was no speech in this recording to write notes from.")
            return
        }

        if let latest = store.recording(recordingID) {
            recording.mode = latest.mode
            recording.meeting = latest.meeting
        }

        do {
            recording = try await writeNotes(recording)
            recording.meeting?.preserveUserChanges(from: store.recording(recordingID)?.meeting)
            store.upsert(withCurrentAudio(recording))
            finish(recordingID, recording)
        } catch is CancellationError {
            markParked(recordingID)
        } catch {
            fail(recordingID, recording, error.localizedDescription)
        }
    }

    private func transcribe(_ recording: Recording) async throws -> Recording {
        var recording = recording
        let engine = settings.engineKind
        let transcriber = Transcription.engine(demo: engine == .demo)
        let started = Date()

        // Pulls the file down from iCloud first when it isn't on the device.
        guard let audio = try? await store.audio.ensureLocal(for: recording) else {
            // No audio and no transcript is the demo-seed case, not a failure.
            if recording.segments.isEmpty, engine == .demo {
                recording.segments = SampleData.meetingRecording.segments
            }
            return recording
        }

        let segments = try await transcriber.transcribe(url: audio) { [weak self] progress in
            Task { @MainActor in
                self?.noteTranscriptionProgress(recording.id, progress: progress)
            }
        }
        recording.segments = segments

        // One read covers duration, size and format, which is what the storage
        // screen and the optimizer both need.
        if let facts = await AudioFile.facts(at: audio) { recording.apply(facts) }

        ProcessingStatsStore.recordTranscription(
            audioSeconds: recording.duration,
            elapsed: Date().timeIntervalSince(started),
            engine: engine
        )
        update(recording.id) { job in
            job.audioSeconds = recording.duration
            job.transcriptCharacters = segments.timestampedText.count
        }
        return recording
    }

    private func writeNotes(_ recording: Recording) async throws -> Recording {
        var recording = recording
        let engine = settings.engineKind
        let transcript = recording.segments.timestampedText

        update(recording.id) { job in
            job.phase = .writing(0)
            job.phaseStartedAt = Date()
            job.transcriptCharacters = transcript.count
            job.etaSeconds = self.rates.writeSeconds(characters: transcript.count)
        }
        await liveActivity.update(phase: .writing(0), eta: job(for: recording.id)?.etaSeconds)

        let started = Date()
        let recapEngine = RecapEngineFactory.make(settings)
        recording.recap = try await recapEngine.makeRecap(
            transcript: transcript,
            mode: recording.mode
        ) { [weak self] progress in
            Task { @MainActor in
                self?.noteWritingProgress(recording.id, progress: recording.mode == .meeting && engine != .demo ? progress * 0.8 : progress)
            }
        }
        recording.processingError = nil

        if recording.mode == .meeting, engine != .demo {
            do {
                let attached = MaterialStore.shared.materials(forRecording: recording.id)
                recording.meeting = try await recapEngine.meetingWorkspace(for: recording, materials: attached) { [weak self] progress in
                    Task { @MainActor in self?.noteWritingProgress(recording.id, progress: 0.8 + 0.2 * progress) }
                }
                if attached.contains(where: { !$0.state.isReady }) {
                    recording.meeting?.analysisNotice = "Some attachments were still being read. Refresh meeting insights when they are ready."
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                var workspace = MeetingWorkspace.existing(for: recording)
                workspace.analysisNotice = "Your recap is saved. Meeting insights need another try: \(error.localizedDescription)"
                recording.meeting = workspace
            }
        }

        ProcessingStatsStore.recordWrite(
            characters: transcript.count,
            elapsed: Date().timeIntervalSince(started),
            engine: engine
        )
        return recording
    }

    // MARK: Progress and estimates

    private var rates: ProcessingRates { ProcessingStatsStore.rates(for: settings.engineKind) }

    private func noteTranscriptionProgress(_ recordingID: UUID, progress: Double) {
        let clamped = min(max(progress, 0), 1)
        update(recordingID) { job in
            job.phase = .transcribing(clamped)
            job.etaSeconds = self.estimate(for: job, observing: clamped)
        }
        let eta = job(for: recordingID)?.etaSeconds
        Task { await liveActivity.update(phase: .transcribing(clamped), eta: eta) }
    }

    private func noteWritingProgress(_ recordingID: UUID, progress: Double) {
        let clamped = min(max(progress, 0), 1)
        update(recordingID) { job in
            job.phase = .writing(clamped)
            job.etaSeconds = self.estimate(for: job, observing: clamped)
        }
        let eta = job(for: recordingID)?.etaSeconds
        Task { await liveActivity.update(phase: .writing(clamped), eta: eta) }
    }

    /// Blends the stored rate with what this run is actually doing, so a slow
    /// network or a cold model corrects the estimate within a few seconds
    /// instead of lying for the whole job.
    private func estimate(for job: Job, observing progress: Double) -> Double? {
        let rates = self.rates
        let elapsed = job.phaseStartedAt.map { Date().timeIntervalSince($0) } ?? 0

        switch job.phase {
        case .transcribing:
            let remainingAudio = job.audioSeconds * (1 - progress)
            var transcribeLeft = rates.transcribeSeconds(audioSeconds: remainingAudio)
            if progress > 0.08, elapsed > 2, job.audioSeconds > 0 {
                let observed = elapsed / (progress * job.audioSeconds)
                transcribeLeft = (transcribeLeft + observed * remainingAudio) / 2
            }
            return transcribeLeft + rates.writeSeconds(characters: job.transcriptCharacters)

        case .writing:
            let total = rates.writeSeconds(characters: job.transcriptCharacters)
            // Chunked runs report real progress; a single request can't, so fall
            // back to counting down the estimate and never claim zero.
            if progress > 0.02 {
                let observed = elapsed / progress
                return max(1, (total * (1 - progress) + observed * (1 - progress)) / 2)
            }
            return max(1, total - elapsed)

        default:
            return nil
        }
    }

    // MARK: Outcomes

    private func finish(_ recordingID: UUID, _ recording: Recording) {
        PendingJobs.remove(recordingID)
        update(recordingID) { job in
            job.phase = .done
            job.etaSeconds = 0
            job.title = recording.displayTitle
        }
        // Questions get written in the same breath as the notes. Minting only at
        // launch meant a recap you recorded and read this afternoon had nothing
        // to study until you next cold-started the app — long enough that the
        // material was no longer fresh, which is the whole point.
        study.refreshItems(for: recording, in: store.sortedRecordings)
        StudyNotifier.reschedule(study: study, settings: settings)
        Task { await liveActivity.finish(success: true) }

        if UIApplication.shared.applicationState != .active {
            RecapNotifier.recapReady(recording)
        }
        forget(recordingID, after: 2.5)
    }

    /// Re-reads the fields that describe *where the audio is* from the store.
    ///
    /// A job carries a `Recording` value from the moment it started, but the
    /// audio optimizer can re-encode and rename that file while the job runs —
    /// `<id>.mp4` becomes `<id>.m4a`, and the old file is deleted. That rename
    /// lands in the store, not in this snapshot, and `upsert` replaces the
    /// whole record. Writing the snapshot back therefore resurrects a filename
    /// that no longer exists on disk, which strands the real audio: playback
    /// and re-runs fail with "no audio", and deleting the recap leaves the file
    /// behind because it looks for the wrong name.
    ///
    /// Everything else on the record still belongs to the job — only the file's
    /// identity belongs to the optimizer.
    private func withCurrentAudio(_ recording: Recording) -> Recording {
        guard let latest = store.recording(recording.id) else { return recording }
        var r = recording
        r.audioFilename = latest.audioFilename
        r.audioBytes = latest.audioBytes
        r.audioCodec = latest.audioCodec
        r.audioBitRate = latest.audioBitRate
        r.audioSampleRate = latest.audioSampleRate
        r.audioChannels = latest.audioChannels
        r.audioRemoved = latest.audioRemoved
        r.keepAudioDownloaded = latest.keepAudioDownloaded
        r.optimizeFailed = latest.optimizeFailed
        return r
    }

    private func fail(_ recordingID: UUID, _ recording: Recording, _ message: String) {
        PendingJobs.remove(recordingID)
        var recording = recording
        recording.processingError = message
        store.upsert(withCurrentAudio(recording))

        update(recordingID) { job in
            job.phase = .failed(message)
            job.etaSeconds = nil
        }
        Task { await liveActivity.finish(success: false) }

        if UIApplication.shared.applicationState != .active {
            RecapNotifier.recapFailed(recording, message: message)
        }
        forget(recordingID, after: 4)
    }

    /// Parking is not failing: no error is written to the recording, so the
    /// next resume picks it straight back up.
    private func markParked(_ recordingID: UUID) {
        update(recordingID) { job in
            job.phase = .paused
            job.etaSeconds = nil
        }
    }

    /// Rows read their state from the recording once a job is gone, so the job
    /// only needs to live long enough for the finished state to be seen.
    private func forget(_ recordingID: UUID, after delay: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self?.jobs.removeAll { $0.id == recordingID && $0.phase.isFinished }
        }
    }

    private func update(_ recordingID: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == recordingID }) else { return }
        change(&jobs[index])
    }
}

// MARK: - What was queued, across launches

/// The set of recordings the user has asked us to process, on disk. Survives
/// being force-quit mid-transcription, which is the case the whole background
/// path exists for.
private enum PendingJobs {
    private static let key = "queue.pendingRecordings"

    static var ids: Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: key) ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    static func insert(_ id: UUID) {
        var current = ids
        guard current.insert(id).inserted else { return }
        write(current)
    }

    static func remove(_ id: UUID) {
        var current = ids
        guard current.remove(id) != nil else { return }
        write(current)
    }

    /// Drops anything not in `alive` — recordings deleted, or finished
    /// elsewhere and synced in.
    static func keep(_ alive: Set<UUID>) {
        let current = ids
        let trimmed = current.intersection(alive)
        guard trimmed != current else { return }
        write(trimmed)
    }

    private static func write(_ ids: Set<UUID>) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }
}
