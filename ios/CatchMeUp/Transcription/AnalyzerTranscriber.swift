import AVFoundation
import Foundation
import Speech

/// Both speech models work independently of Apple Intelligence for recaps.
@available(iOS 26.0, *)
struct AnalyzerTranscriber: Transcriber {
    func transcribe(url: URL, status: @escaping (SpeechPreparation) -> Void = { _ in },
                    progress: @escaping (Double) -> Void) async throws -> [Segment] {
        try await SpeechRecovery.run(recovering: { status(.recovering) }) { attempt in
            let callbacks = SpeechCallbacks()
            defer { callbacks.close() }
            return try await transcribeAttempt(url: url, attempt: attempt,
                status: { stage in callbacks.send { status(stage) } },
                progress: { value in callbacks.send { progress(value) } })
        }
    }

    private func transcribeAttempt(url: URL, attempt: Int,
                                   status: @escaping (SpeechPreparation) -> Void,
                                   progress: @escaping (Double) -> Void) async throws -> [Segment] {
        status(.starting)
        let module: any SpeechModule
        let locale: Locale
        let collect: (Double, SpeechOperation<[Segment]>) async throws -> [Segment]

        let selection: Locale? = try await Self.step(.language, attempt: attempt,
            timeout: .seconds(30)
        ) { _ in
            guard SpeechTranscriber.isAvailable else { return nil }
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: .current) {
                return match
            }
            return await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        if let selection {
            locale = selection
            let speech = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                           reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
            module = speech
            collect = { total, watchdog in
                var buffer = SpeechResultBuffer()
                for try await result in speech.results {
                    try Task.checkCancellation()
                    watchdog.heartbeat()
                    if let value = buffer.receive(text: String(result.text.characters), start: result.range.start.seconds,
                                                  end: result.range.end.seconds, isFinal: result.isFinal, total: total) {
                        progress(value)
                    }
                }
                return buffer.segments
            }
        } else {
            locale = try await Self.step(.language, attempt: attempt,
                timeout: .seconds(30)
            ) { _ in
                if let match = await DictationTranscriber.supportedLocale(equivalentTo: .current) {
                    return match
                }
                guard let english = await DictationTranscriber.supportedLocale(
                    equivalentTo: Locale(identifier: "en-US")
                ) else { throw TranscriptionError.recognizerUnavailable }
                return english
            }
            var preset = DictationTranscriber.Preset.timeIndexedLongDictation
            preset.reportingOptions.insert(.volatileResults)
            let dictation = DictationTranscriber(locale: locale, preset: preset)
            module = dictation
            collect = { total, watchdog in
                var buffer = SpeechResultBuffer()
                for try await result in dictation.results {
                    try Task.checkCancellation()
                    watchdog.heartbeat()
                    if let value = buffer.receive(text: String(result.text.characters), start: result.range.start.seconds,
                                                  end: result.range.end.seconds, isFinal: result.isFinal, total: total) {
                        progress(value)
                    }
                }
                return buffer.segments
            }
        }

        try await Self.step(.model, attempt: attempt, timeout: .seconds(300)) { _ in
            try await Self.installModel(for: module, locale: locale, status: status)
        }
        try Task.checkCancellation()
        status(.starting)
        let file = try AVAudioFile(forReading: url)
        let total = Double(file.length) / max(1, file.processingFormat.sampleRate)
        let analyzer = SpeechAnalyzer(modules: [module])

        // Apple's explicit preflight separates cold model loading from a lack
        // of transcription results. Keep both bounded, with distinct errors.
        do {
            try await Self.step(.startup, attempt: attempt, timeout: .seconds(180)) { _ in
                try await withTaskCancellationHandler {
                    try await analyzer.prepareToAnalyze(in: file.processingFormat)
                } onCancel: {
                    Task { await analyzer.cancelAndFinishNow() }
                }
            }
        } catch {
            Task { await analyzer.cancelAndFinishNow() }
            throw error
        }
        try Task.checkCancellation()
        progress(0)

        // A first-run stall now recovers inside the app instead of making the
        // person discover that tapping Retry is the workaround. The second
        // attempt gets the longer window because Apple's process is warm by
        // then and remains bounded if the system service is genuinely stuck.
        let inactivityLimit: Duration = attempt == 1 ? .seconds(60) : .seconds(120)
        let segments: [Segment] = try await Self.step(.transcription, attempt: attempt,
            timeout: inactivityLimit
        ) { watchdog in
            let collector = Task {
                do { return try await collect(total, watchdog) }
                catch {
                    // An output-stream error must not sit behind start() until
                    // it is incorrectly reported as an inactivity timeout.
                    watchdog.finish(.failure(error))
                    throw error
                }
            }
            return try await withTaskCancellationHandler {
                do {
                    try Task.checkCancellation()
                    try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                    return try await collector.value
                } catch {
                    collector.cancel()
                    Task { await analyzer.cancelAndFinishNow() }
                    throw error
                }
            } onCancel: {
                collector.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        }
        try Task.checkCancellation()
        guard !segments.isEmpty else {
            throw TranscriptionError.failed("No speech was found in this recording.")
        }
        progress(1)
        return segments
    }

    private static func step<Value>(_ stage: SpeechDeadline, attempt: Int, timeout: Duration,
                                    operation: @escaping (SpeechOperation<Value>) async throws -> Value) async throws -> Value {
        let started = Date()
        do {
            let value = try await SpeechOperation<Value>.run(timeout: timeout, timeoutError: stage, operation: operation)
            SpeechDiagnostics.record(stage: stage, attempt: attempt, started: started, outcome: "completed")
            return value
        } catch {
            let outcome = error is CancellationError ? "cancelled" : (error is SpeechDeadline ? "deadline" : "system-error")
            SpeechDiagnostics.record(stage: stage, attempt: attempt, started: started, outcome: outcome)
            throw error
        }
    }

    private static func installModel(
        for module: any SpeechModule, locale: Locale,
        status: @escaping (SpeechPreparation) -> Void
    ) async throws {
        // Reserve before installing so the analyzer has a language allocation.
        _ = try await AssetInventory.reserve(locale: locale)
        try Task.checkCancellation()
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return
        case .unsupported: throw TranscriptionError.recognizerUnavailable
        case .supported, .downloading: status(.model)
        @unknown default: throw TranscriptionError.modelNotReady
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
        }
        while true {
            try Task.checkCancellation()
            switch await AssetInventory.status(forModules: [module]) {
            case .installed: return
            case .unsupported: throw TranscriptionError.recognizerUnavailable
            case .supported, .downloading: try await Task.sleep(for: .seconds(1))
            @unknown default: throw TranscriptionError.modelNotReady
            }
        }
    }
}
