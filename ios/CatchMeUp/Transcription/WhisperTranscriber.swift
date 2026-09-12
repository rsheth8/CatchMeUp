import Foundation
import SpeakerKit
import WhisperKit

// MARK: - WhisperTranscriber
//
// The accuracy option. Apple Speech is free, instant to set up and good enough
// for a clear recording; Whisper costs a download and real compute time and is
// markedly better on the recordings people actually have — an accent, a room,
// two people talking over each other, a word the dictation model has never met.
//
// It is also the only engine here that can say *who* said something. Apple's
// APIs return no speaker identity at all, so diarization arrives with Whisper
// or not at all: SpeakerKit segments the same audio by voice, and the two
// results are reconciled on word timings.
//
// Unlike the Apple engines, this one runs in the Simulator — the models are
// ordinary CoreML, not a system asset Apple withholds.

struct WhisperTranscriber: Transcriber {
    let variant: WhisperVariant
    /// Label speakers. Costs a second model and roughly a third more time, so
    /// it is a choice rather than always-on.
    let diarize: Bool

    func transcribe(url: URL, status: @escaping (SpeechPreparation) -> Void = { _ in },
                    progress: @escaping (Double) -> Void) async throws -> [Segment] {
        // 1. Model. Usually already on disk; the first run downloads it, and
        //    reports the fraction rather than an indefinite spinner.
        status(.whisperModel(variant, 0))
        let folder = try await WhisperModelStore.shared.ensure(variant) { fraction in
            status(.whisperModel(variant, fraction))
        }

        status(.starting)
        let kit = try await WhisperKit(WhisperKitConfig(
            modelFolder: folder.path,
            verbose: false,
            logLevel: .error,
            prewarm: false,
            load: true,
            download: false
        ))

        // 2. Audio. Whisper wants 16 kHz mono floats; WhisperKit's loader does
        //    the conversion and reads long files in windows so a two-hour
        //    lecture doesn't arrive in memory all at once.
        status(.audio)
        let path = url.path
        let samples = try await Task.detached(priority: .userInitiated) {
            try AudioProcessor.loadAudioAsFloatArray(fromPath: path)
        }.value
        try Task.checkCancellation()

        // 3. Transcribe. Word timestamps are not optional here: they are what
        //    the speaker alignment in step 4 matches against, and what lets a
        //    tapped transcript line seek to the right second.
        let duration = Double(samples.count) / 16_000
        // Diarization is the tail of the job, so transcription owns the first
        // ~70% of the bar when it will run and all of it when it won't.
        let transcriptionShare = diarize ? 0.7 : 1.0
        // Progress comes from discovered segments, not from the decoder's
        // token callback: how far into the audio we have got is a real
        // fraction, where "tokens emitted" is not — VAD chunking hands windows
        // out of order, so the furthest end reached is the honest high-water
        // mark rather than the latest one.
        let reached = Reached()
        let results = try await kit.transcribe(
            audioArray: samples,
            decodeOptions: DecodingOptions(
                verbose: false,
                task: .transcribe,
                wordTimestamps: true,
                chunkingStrategy: .vad
            ),
            callback: { _ in !Task.isCancelled },
            segmentCallback: { discovered in
                guard duration > 0, let furthest = discovered.map(\.end).max() else { return }
                let fraction = reached.advance(to: Double(furthest) / duration)
                progress(min(1, fraction) * transcriptionShare)
            }
        )
        try Task.checkCancellation()

        guard !results.isEmpty else { throw TranscriptionError.failed("Whisper returned no text.") }

        guard diarize else {
            progress(1)
            return Self.segments(from: results)
        }

        // 4. Speakers. A diarization failure must not lose a transcript that
        //    already succeeded — the labels are an enhancement, and an unlabelled
        //    transcript is the right outcome to fall back to.
        do {
            status(.speakers)
            let speakerKit = try await SpeakerKit(PyannoteConfig(
                downloadBase: WhisperModelStore.downloadBase.path,
                download: true,
                load: true,
                verbose: false,
                logLevel: .error
            ))
            let diarization = try await speakerKit.diarize(audioArray: samples) { p in
                progress(transcriptionShare + p.fractionCompleted * (1 - transcriptionShare))
            }
            await speakerKit.unloadModels()
            let labelled = diarization.addSpeakerInfo(to: results)
            progress(1)
            let merged = Self.segments(fromSpeakerSegments: labelled.flatMap { $0 })
            return merged.isEmpty ? Self.segments(from: results) : merged
        } catch {
            progress(1)
            return Self.segments(from: results)
        }
    }

    // MARK: - Mapping

    /// Whisper segments → the app's `Segment`. Whisper already emits roughly
    /// sentence-sized pieces, but they are sized for its 30-second window, not
    /// for a recap prompt, so they go through the same `assemble` rule every
    /// other engine uses.
    static func segments(from results: [TranscriptionResult]) -> [Segment] {
        let pieces = results.flatMap(\.segments).map {
            (start: Double($0.start), end: Double($0.end),
             text: $0.text.trimmingCharacters(in: .whitespaces))
        }
        return Transcription.assemble(pieces)
    }

    /// Speaker-labelled segments → `Segment`. These are not run through
    /// `assemble`: merging across a speaker change would attribute one person's
    /// words to another, which is a worse error than a short line. Consecutive
    /// runs by the *same* speaker are joined instead, so a paragraph reads as a
    /// paragraph.
    static func segments(fromSpeakerSegments speakerSegments: [SpeakerSegment]) -> [Segment] {
        var out: [Segment] = []
        for piece in speakerSegments.sorted(by: { $0.startTime < $1.startTime }) {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let name = label(for: piece.speaker)

            if var last = out.last, last.speaker == name,
               Double(piece.startTime) - last.start < 30 {
                last.text += " " + text
                out[out.count - 1] = last
            } else {
                out.append(Segment(start: Double(piece.startTime), text: text, speaker: name))
            }
        }
        return out
    }

    /// Diarization knows there were distinct voices, not whose they were. The
    /// label says exactly that much; renaming is the user's to do.
    static func label(for speaker: SpeakerInfo) -> String? {
        guard let id = speaker.speakerId else { return nil }
        return "Speaker \(id + 1)"
    }
}

/// A monotonic high-water mark, safe to touch from WhisperKit's concurrent
/// decoding workers. Without it a bar built from out-of-order VAD windows walks
/// backwards, which reads as the job having gone wrong.
private final class Reached: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double = 0

    func advance(to candidate: Double) -> Double {
        lock.lock()
        defer { lock.unlock() }
        value = max(value, candidate)
        return value
    }
}
