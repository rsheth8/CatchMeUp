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

        let totalDuration = Self.duration(of: url)

        return try await withCheckedThrowingContinuation { continuation in
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                if let error, !finished {
                    finished = true
                    continuation.resume(throwing: TranscriptionError.failed(error.localizedDescription))
                    return
                }
                guard let result else { return }

                if !result.isFinal {
                    if totalDuration > 0, let last = result.bestTranscription.segments.last {
                        progress(min(0.99, (last.timestamp + last.duration) / totalDuration))
                    }
                    return
                }

                if !finished {
                    finished = true
                    progress(1)
                    continuation.resume(returning: Self.segments(from: result.bestTranscription))
                }
            }
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

    private static func duration(of url: URL) -> Double {
        let asset = AVURLAsset(url: url)
        return CMTimeGetSeconds(asset.duration)
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
        if out.isEmpty {
            out.append(Segment(start: 0, text: t.formattedString))
        }
        return out
    }
}

import AVFoundation

struct MockTranscriber: Transcriber {
    func transcribe(url: URL, progress: @escaping (Double) -> Void) async throws -> [Segment] {
        for i in 1...5 {
            try? await Task.sleep(nanoseconds: 200_000_000)
            progress(Double(i) / 5)
        }
        return SampleData.meetingRecording.segments
    }
}
