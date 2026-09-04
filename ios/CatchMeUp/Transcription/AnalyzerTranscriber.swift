import AVFoundation
import Foundation
import Speech

// MARK: - SpeechAnalyzer
//
// iOS 26's transcription engine, and the one this app actually wants. The old
// `SFSpeechRecognizer` path was designed around dictation — a person speaking a
// sentence into a text field — and it shows: it is tuned for short utterances
// and it hands back word-level fragments that have to be stitched into
// something readable.
//
// `SpeechAnalyzer` was built for the opposite case: a whole file, read start to
// finish, returning finalized phrases that each carry their own time range. A
// fifty-minute lecture is that case. It also runs entirely on the device, which
// is the promise the rest of the app is built on — nothing here reaches the
// network, and the analyzer's model is downloaded once by the system rather
// than bundled or fetched by us.
//
// The engine keeps its own file because it is a genuine alternative and not a
// tweak: on iOS 17–25 `RecognizerTranscriber` is still the only option, and
// both have to keep working.

@available(iOS 26.0, *)
struct AnalyzerTranscriber: Transcriber {

    /// Cheap enough to ask on every job — it reflects hardware support, not
    /// whether a particular language has been downloaded yet.
    static var isAvailable: Bool { SpeechTranscriber.isAvailable }

    func transcribe(url: URL, progress: @escaping (Double) -> Void) async throws -> [Segment] {
        try await Transcription.requestAuth()

        let locale = await Self.bestLocale()
        // No volatile results: a half-finished phrase that will be revised is
        // noise here, because nothing is being displayed as it arrives. Time
        // ranges, on the other hand, are the whole point — they are what lets a
        // note link back to the moment in the audio that produced it.
        let module = SpeechTranscriber(locale: locale,
                                       transcriptionOptions: [],
                                       reportingOptions: [],
                                       attributeOptions: [.audioTimeRange])

        try await Self.installModel(for: module, locale: locale)

        let file = try AVAudioFile(forReading: url)
        let total = Double(file.length) / max(1, file.processingFormat.sampleRate)
        let analyzer = SpeechAnalyzer(modules: [module])

        // The results arrive on their own sequence while the file is being fed
        // in, so the collector has to be running before analysis starts or the
        // first phrases are dropped.
        let collector = Task { () -> [Segment] in
            var pieces: [(start: Double, end: Double, text: String)] = []
            for try await result in module.results {
                let start = result.range.start.seconds
                let end = result.range.end.seconds
                pieces.append((start: start.isFinite ? start : 0,
                               end: end.isFinite ? end : 0,
                               text: String(result.text.characters)))
                if total > 0, end.isFinite {
                    progress(min(0.99, end / total))
                }
            }
            return Transcription.assemble(pieces)
        }

        do {
            try await withTaskCancellationHandler {
                // `finishAfterFile` is what ends `module.results`; without it
                // the collector waits for input that is never coming.
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                _ = try await collector.value
            } onCancel: {
                collector.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            collector.cancel()
            throw TranscriptionError.failed(error.localizedDescription)
        }

        let segments = try await collector.value
        progress(1)
        // An empty result is a failure worth naming. Silently saving a recap
        // with no transcript sends the user to a recap about nothing.
        guard !segments.isEmpty else {
            throw TranscriptionError.failed("No speech was found in this recording.")
        }
        return segments
    }

    // MARK: Locale and model

    /// The user's own language when the engine supports it, English otherwise —
    /// picked through `supportedLocale(equivalentTo:)` so that a device set to
    /// `en_GB` or `en_IN` lands on the closest supported variant instead of
    /// failing outright.
    private static func bestLocale() async -> Locale {
        let current = Locale.current
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: current) {
            return match
        }
        let english = Locale(identifier: "en-US")
        return await SpeechTranscriber.supportedLocale(equivalentTo: english) ?? english
    }

    /// The language model is downloaded by the system on first use, so the
    /// first recap on a new phone can wait on a download. That is preferable to
    /// shipping the model, which would be measured in gigabytes.
    private static func installModel(for module: SpeechTranscriber, locale: Locale) async throws {
        switch await AssetInventory.status(forModules: [module]) {
        case .installed:
            break
        case .unsupported:
            throw TranscriptionError.recognizerUnavailable
        case .supported, .downloading:
            // A nil request means the system is already installing this model
            // for someone else. The download is real either way, so the answer
            // is to wait for it below rather than to carry on without it.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                try await request.downloadAndInstall()
            }
        @unknown default:
            break
        }

        try await waitForModel(module)

        // Reserving keeps the system from reclaiming the model between recaps.
        // There is a cap on reservations, and being over it is not an error
        // worth failing a transcription for.
        _ = try? await AssetInventory.reserve(locale: locale)
    }

    /// Confirms the model is genuinely installed before any audio is fed in.
    ///
    /// This matters more than it looks. `SpeechAnalyzer` does not fail when its
    /// model is missing — it simply produces no results, which reaches the user
    /// as "No speech was found in this recording" on a recording that is full
    /// of speech. The first recap on a new phone is exactly when the model is
    /// least likely to be ready, so the wait is worth making explicit and the
    /// giving-up point is worth naming.
    private static func waitForModel(_ module: SpeechTranscriber) async throws {
        let deadline = ContinuousClock.now + .seconds(180)
        while true {
            switch await AssetInventory.status(forModules: [module]) {
            case .installed:
                return
            case .unsupported:
                throw TranscriptionError.recognizerUnavailable
            case .downloading:
                guard ContinuousClock.now < deadline else { throw modelNotReady }
                try await Task.sleep(for: .seconds(2))
            case .supported:
                // Installation ran and left nothing behind; waiting won't help.
                throw modelNotReady
            @unknown default:
                return
            }
        }
    }

    private static var modelNotReady: TranscriptionError {
        .failed("the on-device speech model hasn't finished downloading. "
                + "It keeps going in the background — try again in a minute.")
    }
}
