import AVFoundation
import Foundation
import Speech

protocol Transcriber {
    /// Returns timestamped segments. `progress` is 0...1 (best effort).
    func transcribe(url: URL, status: @escaping (SpeechPreparation) -> Void,
                    progress: @escaping (Double) -> Void) async throws -> [Segment]
}

enum SpeechPreparation: Equatable {
    case audio, permission, model, starting, recovering

    var label: String {
        switch self {
        case .audio: return "Getting your audio ready"
        case .permission: return "Checking speech permission"
        case .model: return "Downloading speech model"
        case .starting: return "Preparing on-device transcription"
        case .recovering: return "Restarting Apple Speech"
        }
    }

    var detail: String {
        switch self {
        case .audio: return "If your recording is in iCloud, it needs to download first."
        case .permission: return "Allow speech recognition when prompted."
        case .model: return "First use may take a few minutes. Stay online while Apple prepares the language model. Your audio stays on this device."
        case .starting: return "Apple Speech turns audio into text. Your recap engine, including Claude, writes the notes afterward."
        case .recovering: return "Apple Speech took longer than expected. Trying once more automatically — your audio is safe."
        }
    }
}

enum TranscriptionError: LocalizedError {
    case notAuthorized
    case recognizerUnavailable
    case stalled
    case modelNotReady
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Speech recognition permission was denied. Enable it in Settings ▸ CatchMeUp."
        case .recognizerUnavailable: return "On-device speech recognition isn't available for this language yet."
        case .stalled: return "Apple Speech stopped responding. Your recording is saved. Keep the app open and try again. If it happens again, restart your iPhone. Your Claude or other recap API key is not used for transcription."
        case .modelNotReady: return "The speech model isn't ready yet. Your recording is saved. Check your internet connection and available storage, then retry with the app open."
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
    static func engine(demo: Bool, mode: Mode = .meeting) -> Transcriber {
        if demo { return MockTranscriber(mode: mode) }
        if #available(iOS 26.0, *) {
            return AnalyzerTranscriber()
        }
        return RecognizerTranscriber()
    }

    /// Legacy recognizer permission. SpeechAnalyzer's on-device modules do not
    /// need the older server-capable API's speech authorization prompt.
    static func requestAuth() async throws {
        let status = SFSpeechRecognizer.authorizationStatus()
        if status == .authorized { return }
        let granted = try await SpeechOperation<SFSpeechRecognizerAuthorizationStatus>.run(
            timeout: .seconds(120), timeoutError: TranscriptionError.stalled
        ) { _ in
            await withCheckedContinuation { c in
                SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
            }
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
    func transcribe(url: URL, status: @escaping (SpeechPreparation) -> Void = { _ in },
                    progress: @escaping (Double) -> Void) async throws -> [Segment] {
        status(.permission)
        try await Self.requestAuth()

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw TranscriptionError.recognizerUnavailable
        }

        let totalDuration = await Self.duration(of: url)
        let handle = RecognitionHandle()
        status(.starting)

        return try await SpeechOperation<[Segment]>.run(
            timeout: .seconds(120), timeoutError: TranscriptionError.stalled
        ) { watchdog in

        // Cancellation has to reach `SFSpeechRecognitionTask` itself. Without
        // this the recogniser keeps chewing through the file after the queue
        // has been told to stop, which is both a waste of battery and a way to
        // end up writing notes for a job nobody is waiting on any more.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard handle.install(continuation) else { return }
                let request = SFSpeechURLRecognitionRequest(url: url)
                request.shouldReportPartialResults = true
                request.addsPunctuation = true
                request.requiresOnDeviceRecognition = true

                let task = recognizer.recognitionTask(with: request) { result, error in
                    if let error {
                        handle.finish(.failure(TranscriptionError.failed(error.localizedDescription)))
                        return
                    }
                    guard let result else { return }
                    watchdog.heartbeat()

                    if !result.isFinal {
                        if totalDuration > 0, let last = result.bestTranscription.segments.last {
                            progress(min(0.99, (last.timestamp + last.duration) / totalDuration))
                        }
                        return
                    }

                    progress(1)
                    handle.finish(.success(Self.segments(from: result.bestTranscription)))
                }

                // Losing the race against cancellation is possible, so the
                // handle tears the task down if the flag is already set.
                handle.attach(task)
            }
        } onCancel: {
            handle.cancel()
        }
        }
    }

    /// Shared mutable state between the continuation, the recogniser's callback
    /// queue, and the cancellation handler.
    private final class RecognitionHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var task: SFSpeechRecognitionTask?
        private var finished = false
        private var continuation: CheckedContinuation<[Segment], Error>?

        func install(_ continuation: CheckedContinuation<[Segment], Error>) -> Bool {
            lock.lock()
            guard !finished else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return false
            }
            self.continuation = continuation
            lock.unlock()
            return true
        }

        func attach(_ task: SFSpeechRecognitionTask) {
            lock.lock()
            let shouldStop = finished
            if !shouldStop { self.task = task }
            lock.unlock()
            if shouldStop { task.cancel() }
        }

        func cancel() {
            finish(.failure(CancellationError()))
        }

        /// Completion and cancellation both resume exactly once, even if the
        /// speech service never calls back after cancellation.
        func finish(_ result: Result<[Segment], Error>) {
            lock.lock()
            guard !finished else { lock.unlock(); return }
            finished = true
            let continuation = self.continuation
            self.continuation = nil
            let task = self.task
            self.task = nil
            lock.unlock()
            task?.cancel()
            continuation?.resume(with: result)
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
    var mode: Mode = .meeting
    func transcribe(url: URL, status: @escaping (SpeechPreparation) -> Void = { _ in },
                    progress: @escaping (Double) -> Void) async throws -> [Segment] {
        for i in 1...5 {
            try await Task.sleep(nanoseconds: 200_000_000)
            progress(Double(i) / 5)
        }
        if let entry = try? ShowcaseCatalog.entries().first(where: { $0.mode == mode }) { return entry.segments }
        return mode == .lecture ? SampleData.lectureSegments : SampleData.meetingSegments
    }
}
