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

/// On-device transcription with Apple's Speech framework. No network, no dependency.
struct SpeechTranscriber: Transcriber {
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
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        let granted: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        guard granted == .authorized else { throw TranscriptionError.notAuthorized }
    }

    private static func duration(of url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            return CMTimeGetSeconds(duration)
        }
        return 0
    }

    /// Group word-level segments into ~sentence chunks so notes get usable timestamps.
    private static func segments(from t: SFTranscription) -> [Segment] {
        var out: [Segment] = []
        var buffer = ""
        var chunkStart: Double?
        var lastEnd: Double = 0

        for seg in t.segments {
            if chunkStart == nil { chunkStart = seg.timestamp }
            buffer += (buffer.isEmpty ? "" : " ") + seg.substring
            lastEnd = seg.timestamp + seg.duration

            let endsSentence = seg.substring.range(of: #"[.!?]$"#, options: .regularExpression) != nil
            let longEnough = (lastEnd - (chunkStart ?? 0)) > 18
            if endsSentence || longEnough {
                out.append(Segment(start: chunkStart ?? 0, text: buffer.trimmingCharacters(in: .whitespaces)))
                buffer = ""
                chunkStart = nil
            }
        }
        if !buffer.isEmpty {
            out.append(Segment(start: chunkStart ?? 0, text: buffer.trimmingCharacters(in: .whitespaces)))
        }
        if out.isEmpty, !t.formattedString.isEmpty {
            out.append(Segment(start: 0, text: t.formattedString))
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
