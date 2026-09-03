import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class AudioRecorder: NSObject {
    var isRecording = false
    /// True between the tap and the mic actually going live.
    var isStarting = false
    var isPaused = false
    var elapsed: TimeInterval = 0
    var level: Double = 0          // 0...1, for the meter
    /// Rolling window of recent levels, oldest first — drives the live waveform.
    private(set) var levels: [Double] = Array(repeating: 0, count: barCount)

    static let barCount = 44

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    enum RecorderError: LocalizedError {
        /// The hardware never came live inside `startTimeout`.
        case micDidNotStart

        var errorDescription: String? {
            switch self {
            case .micDidNotStart:
                "The microphone didn't start. Another app may be using it."
            }
        }
    }

    /// How long the hardware gets before the app gives up on it. Starting a
    /// recording is normally instant; the cases that aren't — another app
    /// holding the input, a route that never answers — do not resolve by
    /// waiting longer, and the old code waited for them forever behind a
    /// spinner. Long enough that a Bluetooth mic can still negotiate.
    nonisolated static let startTimeout: Duration = .seconds(8)

    func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
    }

    /// Activating the audio session and starting the hardware can take a long
    /// time — and blocks outright when there's no input device — so it happens
    /// off the main thread and the UI flips to "recording" as soon as it's live.
    func start(to url: URL, quality: AudioQuality = .fallback) async throws {
        isRecording = true
        isStarting = true
        isPaused = false
        elapsed = 0
        level = 0
        levels = Array(repeating: 0, count: Self.barCount)
        fileURL = url

        let live: AVAudioRecorder
        do {
            live = try await Self.begin(at: url, quality: quality)
        } catch {
            isRecording = false
            isStarting = false
            fileURL = nil
            throw error
        }

        // The user may have cancelled while the hardware was spinning up. The
        // timer never ran, so there is nothing in the file worth keeping.
        guard isRecording else {
            live.stop()
            try? FileManager.default.removeItem(at: url)
            return
        }
        recorder = live
        isStarting = false

        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Races the hardware against `startTimeout`. Every call in here can block
    /// indefinitely — `setActive` and `record()` both go through the audio HAL —
    /// and none of them is cancellable, so losing the race means abandoning the
    /// work rather than stopping it: the caller gets its error immediately and
    /// `StartRace` cleans up behind whatever arrives afterwards.
    private nonisolated static func begin(at url: URL,
                                          quality: AudioQuality) async throws -> AVAudioRecorder {
        try await withCheckedThrowingContinuation { continuation in
            let race = StartRace(continuation) { orphan in
                orphan.stop()
                try? FileManager.default.removeItem(at: orphan.url)
            }

            // `try`, not `try?`: cancellation has to skip the settle, or
            // stopping the clock would itself report a timeout.
            let deadline = Task {
                try await Task.sleep(for: startTimeout)
                race.settle(.failure(RecorderError.micDidNotStart))
            }

            DispatchQueue.global(qos: .userInitiated).async {
                defer { deadline.cancel() }
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.defaultToSpeaker, .allowBluetooth])
                    try session.setActive(true)

                    // Some routes refuse the reduced sample rate. Falling back
                    // to 44.1 kHz costs space but never costs the recording.
                    let rec: AVAudioRecorder
                    do {
                        rec = try AVAudioRecorder(url: url, settings: quality.recorderSettings)
                    } catch {
                        var relaxed = quality.recorderSettings
                        relaxed[AVSampleRateKey] = 44_100
                        rec = try AVAudioRecorder(url: url, settings: relaxed)
                    }
                    rec.isMeteringEnabled = true
                    rec.record()
                    race.settle(.success(rec))
                } catch {
                    race.settle(.failure(error))
                }
            }
        }
    }

    private func tick() {
        guard let rec = recorder, rec.isRecording else { return }
        rec.updateMeters()
        elapsed = rec.currentTime
        let db = Double(rec.averagePower(forChannel: 0))          // -160...0
        level = max(0, min(1, (db + 55) / 55))
        levels.removeFirst()
        levels.append(level)
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        recorder?.pause()
        isPaused = true
        level = 0
    }

    func resume() {
        guard isRecording, isPaused else { return }
        recorder?.record()
        isPaused = false
    }

    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        timer?.invalidate(); timer = nil
        isRecording = false
        isStarting = false
        isPaused = false
        level = 0
        // Deactivating can block too; nothing downstream waits on it.
        DispatchQueue.global(qos: .utility).async {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
        return fileURL
    }
}

/// Hands the first of two racers to the caller and disposes of the loser.
///
/// Both halves matter. Resuming a `CheckedContinuation` twice is a crash, so the
/// win has to be decided under a lock; and a recorder that arrives after the
/// timeout is nobody's — nothing will ever stop it, so it would sit holding the
/// input and writing a file the library never learns about. Handing it to
/// `discard` is what makes abandoning a start safe.
final class StartRace<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private let discard: @Sendable (Value) -> Void

    init(_ continuation: CheckedContinuation<Value, Error>,
         discard: @escaping @Sendable (Value) -> Void) {
        self.continuation = continuation
        self.discard = discard
    }

    func settle(_ result: Result<Value, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()

        if let waiting {
            waiting.resume(with: result)
        } else if case .success(let orphan) = result {
            discard(orphan)
        }
    }
}

@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    /// True once a file is loaded, so views can show a player before playback starts.
    var isLoaded: Bool { player != nil }

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.prepareToPlay()
        duration = player?.duration ?? 0
    }

    func play(from seconds: TimeInterval? = nil) {
        guard let player else { return }
        if let seconds { player.currentTime = min(seconds, max(0, player.duration - 0.2)) }
        player.play()
        isPlaying = true
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player else { return }
                self.currentTime = p.currentTime
                self.isPlaying = p.isPlaying
                if !p.isPlaying { self.timer?.invalidate() }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pause() { player?.pause(); isPlaying = false; timer?.invalidate() }

    func toggle() { isPlaying ? pause() : play() }

    /// Scrub without changing play/pause state.
    func seek(to seconds: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, seconds), max(0, player.duration - 0.05))
        currentTime = player.currentTime
    }

    func skip(_ delta: TimeInterval) { seek(to: currentTime + delta) }

    func stop() {
        player?.stop(); player = nil
        timer?.invalidate(); timer = nil
        isPlaying = false; currentTime = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}
