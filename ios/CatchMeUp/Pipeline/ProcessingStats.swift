import Foundation

/// Learned timings for the two slow steps, so "about 2 min left" comes from
/// what this phone has actually done rather than a hard-coded guess.
///
/// Transcription is measured per second of audio. Writing is measured per
/// thousand transcript characters and kept per engine, because a cloud model
/// and Apple's on-device model are an order of magnitude apart.
struct ProcessingRates: Equatable {
    /// Wall-clock seconds spent transcribing one second of audio.
    var transcribe: Double
    /// Wall-clock seconds spent writing notes per 1,000 transcript characters.
    var write: Double
    /// How many runs went into these numbers. Zero means they're still defaults.
    var samples: Int

    /// Seconds we expect the whole pipeline to take.
    func estimate(audioSeconds: Double, transcriptCharacters: Int) -> Double {
        transcribeSeconds(audioSeconds: audioSeconds)
            + writeSeconds(characters: transcriptCharacters)
    }

    func transcribeSeconds(audioSeconds: Double) -> Double {
        max(0, audioSeconds) * transcribe
    }

    func writeSeconds(characters: Int) -> Double {
        max(0, Double(characters)) / 1000 * write
    }

    /// Before a transcript exists, guess its length from the audio. Speech runs
    /// about 150 words a minute and English averages ~6 characters a word once
    /// you count the space, which lands near 15 characters a second.
    static func expectedCharacters(forAudioSeconds seconds: Double) -> Int {
        Int(max(0, seconds) * 15)
    }
}

@MainActor
enum ProcessingStatsStore {
    /// Sane starting points, replaced by real measurements after one run each.
    /// Apple's file-based recogniser is faster than realtime; the on-device
    /// writer is slow enough that pretending otherwise would be a lie.
    private static let defaults: [EngineKind: ProcessingRates] = [
        .demo: ProcessingRates(transcribe: 0.02, write: 0.05, samples: 0),
        .onDevice: ProcessingRates(transcribe: 0.25, write: 7.5, samples: 0),
        .apiKey: ProcessingRates(transcribe: 0.25, write: 1.6, samples: 0),
    ]

    /// EMA weight. High enough to adapt to a model or network change within a
    /// few runs, low enough that one stalled request doesn't poison the number.
    private static let weight = 0.3

    static func rates(for engine: EngineKind) -> ProcessingRates {
        let fallback = defaults[engine] ?? ProcessingRates(transcribe: 0.25, write: 1.6, samples: 0)
        let d = UserDefaults.standard
        let transcribe = d.object(forKey: transcribeKey) as? Double
        let write = d.object(forKey: writeKey(engine)) as? Double
        let samples = d.integer(forKey: samplesKey(engine))
        return ProcessingRates(
            transcribe: transcribe ?? fallback.transcribe,
            write: write ?? fallback.write,
            samples: samples
        )
    }

    /// Transcription speed is a property of the device, not the engine, so all
    /// engines share one measurement. Demo mode is excluded because its mock
    /// transcriber would teach us nothing about the real one.
    static func recordTranscription(audioSeconds: Double, elapsed: Double, engine: EngineKind) {
        guard engine != .demo, audioSeconds > 5, elapsed > 0.5 else { return }
        let observed = clamp(elapsed / audioSeconds, 0.01, 4)
        let current = rates(for: engine).transcribe
        UserDefaults.standard.set(blend(current, observed), forKey: transcribeKey)
    }

    static func recordWrite(characters: Int, elapsed: Double, engine: EngineKind) {
        guard characters > 200, elapsed > 0.2 else { return }
        let observed = clamp(elapsed / (Double(characters) / 1000), 0.005, 120)
        let current = rates(for: engine)
        UserDefaults.standard.set(blend(current.write, observed), forKey: writeKey(engine))
        UserDefaults.standard.set(min(current.samples + 1, 999), forKey: samplesKey(engine))
    }

    private static func blend(_ current: Double, _ observed: Double) -> Double {
        current * (1 - weight) + observed * weight
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        min(max(v, lo), hi)
    }

    private static let transcribeKey = "rates.transcribePerAudioSecond"
    private static func writeKey(_ e: EngineKind) -> String { "rates.write.\(e.rawValue)" }
    private static func samplesKey(_ e: EngineKind) -> String { "rates.samples.\(e.rawValue)" }
}

// MARK: - Phrasing

/// "about 2 min", "about 40 sec", "under 10 sec". Deliberately vague, because a
/// countdown that claims to know the second is a countdown that looks broken
/// the moment it stalls.
func etaText(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "almost done" }
    if seconds < 10 { return "under 10 sec" }
    if seconds < 90 { return "about \(Int((seconds / 10).rounded()) * 10) sec" }
    let minutes = Int((seconds / 60).rounded())
    return "about \(minutes) min"
}
