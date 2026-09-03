import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class AudioRecorder: NSObject {
    var isRecording = false
    var elapsed: TimeInterval = 0
    var level: Double = 0          // 0...1, for the meter

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private(set) var fileURL: URL?

    func requestPermission() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
        }
    }

    func start(to url: URL) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
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

        recorder = rec
        fileURL = url
        isRecording = true
        elapsed = 0

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard let rec = recorder, rec.isRecording else { return }
        rec.updateMeters()
        elapsed = rec.currentTime
        let db = Double(rec.averagePower(forChannel: 0))          // -160...0
        level = max(0, min(1, (db + 55) / 55))
    }

    @discardableResult
    func stop() -> URL? {
        recorder?.stop()
        timer?.invalidate(); timer = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        return fileURL
    }
}

@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

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

    func stop() {
        player?.stop(); player = nil
        timer?.invalidate(); timer = nil
        isPlaying = false; currentTime = 0
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false }
    }
}
