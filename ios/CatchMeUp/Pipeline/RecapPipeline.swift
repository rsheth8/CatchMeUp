import Foundation
import AVFoundation
import Observation

@MainActor
@Observable
final class RecapPipeline {
    enum Stage: Equatable {
        case idle
        case transcribing(Double)
        case writing
        case done
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "Ready"
            case .transcribing: return "Transcribing on device"
            case .writing: return "Writing your notes"
            case .done: return "Done"
            case .failed: return "Something went wrong"
            }
        }
    }

    var stage: Stage = .idle
    private let liveActivity = RecapLiveActivity()
    var isRunning: Bool {
        switch stage { case .idle, .done, .failed: return false; default: return true }
    }

    /// Full run for a freshly captured or imported recording.
    func process(recordingID: UUID, store: LibraryStore, settings: AppSettings) async {
        guard var rec = store.recording(recordingID) else { return }
        await liveActivity.start(for: rec)
        rec.processingError = nil
        store.upsert(rec)

        // 1. Transcribe
        stage = .transcribing(0)
        let transcriber: Transcriber = settings.engineKind == .demo ? MockTranscriber() : SpeechTranscriber()
        do {
            if let audio = store.audioURL(for: rec) {
                let segments = try await transcriber.transcribe(url: audio) { [weak self] p in
                    Task { @MainActor in
                        self?.stage = .transcribing(p)
                        await self?.liveActivity.transcription(progress: p)
                    }
                }
                rec.segments = segments
                rec.duration = try await AVURLAsset(url: audio).load(.duration).seconds
            } else if rec.segments.isEmpty {
                rec.segments = SampleData.meetingRecording.segments
            }
        } catch {
            fail(&rec, store, error.localizedDescription)
            return
        }
        store.upsert(rec)

        // 2. Recap
        stage = .writing
        await liveActivity.writing()
        let engine = RecapEngineFactory.make(settings)
        do {
            let recap = try await engine.makeRecap(transcript: rec.segments.timestampedText, mode: rec.mode)
            rec.recap = recap
            store.upsert(rec)
            stage = .done
            await liveActivity.finish(success: true)
        } catch {
            fail(&rec, store, error.localizedDescription)
        }
    }

    /// Re-run only the notes step (e.g. after switching engine).
    func rewrite(recordingID: UUID, store: LibraryStore, settings: AppSettings) async {
        guard var rec = store.recording(recordingID), !rec.segments.isEmpty else { return }
        await liveActivity.start(for: rec)
        stage = .writing
        await liveActivity.writing()
        let engine = RecapEngineFactory.make(settings)
        do {
            rec.recap = try await engine.makeRecap(transcript: rec.segments.timestampedText, mode: rec.mode)
            rec.processingError = nil
            store.upsert(rec)
            stage = .done
            await liveActivity.finish(success: true)
        } catch {
            fail(&rec, store, error.localizedDescription)
        }
    }

    private func fail(_ rec: inout Recording, _ store: LibraryStore, _ message: String) {
        rec.processingError = message
        store.upsert(rec)
        stage = .failed(message)
        Task { await liveActivity.finish(success: false) }
    }
}
