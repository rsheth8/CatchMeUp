import AVFoundation
import Foundation
import Speech

protocol Transcriber {
    /// Returns timestamped segments. `progress` is 0...1 (best effort).
    func transcribe(url: URL, progress: @escaping (Double) -> Void) async throws -> [Segment]
}

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition permission was denied. Enable it in Settings ▸ CatchMeUp."
        case .recognizerUnavailable: return "On-device speech recognition isn't available for this language yet."
        case .failed(let s): return "Transcription failed: \(s)"
        }
    }
}

/// Picks the transcriber. There are two on-device engines rather than one
/// because they were written for different jobs: `SFSpeechRecognizer` was built
/// for dictation and is capped around a minute of live speech, while iOS 26's
/// `SpeechAnalyzer` was built for exactly this — a long file, read end to end,
/// with a time range on every phrase. A lecture is the second job, so the newer
/// engine leads and the older one stays as the floor for iOS 17–25.
enum Transcription {
    static func engine(demo: Bool) -> Transcriber {
        if demo { return MockTranscriber() }
        if #available(iOS 26.0, *), AnalyzerTranscriber.isAvailable {
            return AnalyzerTranscriber()
        }
        return RecognizerTranscriber()
    }

    /// Both engines gate on the same permission, so the prompt and the wording
    /// the user sees don't depend on which one happened to be picked.
    static func requestAuth() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        let granted: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard granted == .authorized else { throw TranscriptionError.notAuthorized }
    }

    /// Groups phrase- or word-sized pieces into ~sentence chunks. Segments are
    /// what the recap prompt, the transcript view and clip search all read, so
    /// their size is a shared contract rather than an engine's detail.
    static func assemble(_ pieces: [(start: Double, end: Double, text: String)]) -> [Segment] {
        var out: [Segment] = []
        var buffer = ""
        var chunkStart: Double?
        var lastEnd: Double = 0

        for piece in pieces {
            let text = piece.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if chunkStart == nil { chunkStart = piece.start }
            buffer += (buffer.isEmpty ? "" : " ") + text
            lastEnd = piece.end

            let endsSentence = text.range(of: #"[.!?]["')\]]?$"#, options: .regularExpression) != nil
            let longEnough = (lastEnd - (chunkStart ?? 0)) > 18
            if endsSentence || longEnough {
                out.append(Segment(start: chunkStart ?? 0, text: buffer))
                buffer = ""
                chunkStart = nil
            }
        }
        if !buffer.isEmpty {
            out.append(Segment(start: chunkStart ?? 0, text: buffer))
        }
        return out
    }
}

/// Dictation-era transcription with `SFSpeechRecognizer`. Still the engine on
/// anything before iOS 26.
struct RecognizerTranscriber: Transcriber {
    func transcribe(url: URL, progress: @escaping (Double) -> Void) async throws -> [Segment] {
        try await Self.requestAuth()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscriptionError.recognizerUnavailable
        }

        let totalDuration = await Self.duration(of: url)
        let handle = RecognitionHandle()

        // Cancellation has to reach `SFSpeechRecognitionTask` itself. Without
        // this the recogniser keeps chewing through the file after the queue
        // has been told to stop, which is both a waste of battery and a way to
        // end up writing notes for a job nobody is waiting on any more.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.shouldReportPartialResults = true
                request.addsPunctuation = true
                if recognizer.supportsOnDeviceRecognition {
                    request.requiresOnDeviceRecognition = true
                }

                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        guard handle.finish() else { return }
                        continuation.resume(
                            throwing: handle.wasCancelled
                                ? CancellationError()
                                : TranscriptionError.failed(error.localizedDescription)
                        )
                        return
                    }
                    guard let result else { return }

                    if !result.isFinal {
                        if totalDuration > 0, let last = result.bestTranscription.segments.last {
                            progress(min(0.99, (last.timestamp + last.duration) / totalDuration))
                        }
                        return
                    }

                    guard handle.finish() else { return }
                    progress(1)
                    continuation.resume(returning: Self.segments(from: result.bestTranscription))
                }

                // Losing the race against cancellation is possible, so the
                // handle tears the task down if the flag is already set.
                handle.attach(task)
            }
        } onCancel: {
            handle.cancel()
        }
    }

    /// Shared mutable state between the continuation, the recogniser's callback
    /// queue, and the cancellation handler.
    private final class RecognitionHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: SFSpeechRecognitionTask?
        private var finished = false
        private var cancelled = false

        var wasCancelled: Bool {
            lock.lock(); defer { lock.unlock() }
            return cancelled
        }

        func attach(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            self.task = task
            let shouldStop = cancelled
            lock.unlock()
            if shouldStop { task.cancel() }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let task = self.task
            lock.unlock()
            task?.cancel()
        }

        /// True for the one caller that gets to resume the continuation.
        func finish() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !finished else { return false }
            finished = true
            return true
        }
    }

    // MARK: helpers

    private static func requestAuth() async throws {
        try await Transcription.requestAuth()
    }

    private static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            return CMTimeGetSeconds(duration)
        }
        return 0
    }

    /// Group word-level segments into ~sentence chunks so notes get usable
    /// timestamps. The grouping itself is shared with the newer engine, so both
    /// produce segments of the same size for everything downstream.
    private static func segments(from t: SFTranscription) -> [Segment] {
        let out = Transcription.assemble(t.segments.map {
            (start: $0.timestamp, end: $0.timestamp + $0.duration, text: $0.substring)
        })
        if out.isEmpty, !t.formattedString.isEmpty {
            return [Segment(start: 0, text: t.formattedString)]
        }
        return out
    }
}

struct MockTranscriber: Transcriber {
    func transcribe(url: URL, progress: @escaping (Double) -> Void) async throws -> [Segment] {
        for i in 1...5 {
            try await Task.sleep(nanoseconds: 200_000_000)
            progress(Double(i) / 5)
        }
        return SampleData.meetingRecording.segments
    }
}
