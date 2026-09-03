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

    func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
    }

    /// Activating the audio session and starting the hardware can take a long
    /// time — and blocks outright when there's no input device — so it happens
    /// off the main thread and the UI flips to "recording" as soon as it's live.
    func start(to url: URL) async throws {
        isRecording = true
        isStarting = true
        isPaused = false
        elapsed = 0
        level = 0
        levels = Array(repeating: 0, count: Self.barCount)
        fileURL = url

        let live: AVAudioRecorder
        do {
            live = try await Self.begin(at: url)
        } catch {
            isRecording = false
            isStarting = false
            fileURL = nil
            throw error
        }

        // The user may have cancelled while the hardware was spinning up.
        guard isRecording else { live.stop(); return }
        recorder = live
        isStarting = false

        let t = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private nonisolated static func begin(at url: URL) async throws -> AVAudioRecorder {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playAndRecord, mode: .default,
                                            options: [.defaultToSpeaker, .allowBluetooth])
                    try session.setActive(true)

                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 44_100,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ]
                    let rec = try AVAudioRecorder(url: url, settings: settings)
                    rec.isMeteringEnabled = true
                    rec.record()
                    continuation.resume(returning: rec)
                } catch {
                    continuation.resume(throwing: error)
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
